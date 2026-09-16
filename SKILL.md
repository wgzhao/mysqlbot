---
name: mysqlbot
description: 对 MySQL/MariaDB 实例做**只读、确定性、无 agent** 的健康体检，输出结构化隐患清单（风险/延迟/容量/卫生四个维度 42 条规则，已实测兼容 MySQL 5.7 / 8.0 / 8.4）。适用于"给 MySQL 做体检""查 MySQL 有什么隐患""库慢在哪""有没有长事务/锁等待/元数据锁""表结构有什么问题""没主键的表""冗余索引""binlog 会不会撑盘""准备上线前扫一遍库"。当用户要求巡检 MySQL、排查数据库风险、或需要把数据库体检做成 CI 门禁/SARIF 报告时使用。不写库、不改配置、不 kill 会话——只出结论与建议命令，变更由用户自己执行。
agent_created: true
---

# mysqlbot —— MySQL 只读体检探头

参考 pgbot（PostgreSQL 侧同类工具）的设计思路实现，代码在 `~/code/personal/mysqlbot`。

## 铁律

1. **只读**。不改配置、不 kill 会话、不写任何表。rule 只有查询，工具链里没有写路径。
   报告里给出的 `DROP INDEX` / `KILL` / `SET GLOBAL` 都只是**建议**，由用户本人执行。
2. **"跳过"不等于"没问题"**。能力位缺失、版本不符、实例运行时间不足时，规则会被
   **显式跳过**并在报告里列出原因。汇报时必须把"未覆盖"那一栏一起讲出来，绝不能把
   报告读成"全绿"。这是本工具最重要的输出纪律。
3. **每条结论都要能落到证据**。规则返回的每一行都是证据（对象名、数值、SQL 样本）。
   不要用"看起来""可能是"来描述，直接给行。
4. **不碰生产写操作**。用户的线上变更自己执行；我们负责准备命令与定位问题。

## 快速上手

```bash
cd ~/code/personal/mysqlbot

# 0. 自检：确认客户端、规则目录、连通性与能力位
./bin/mbot doctor --host <host> --port 3306 -u mbot_reader -p

# 1. 体检（默认输出人读表格）
./bin/mbot check --host <host> -u mbot_reader -p

# 2. 机器可消费的完整契约（含能力位、跳过原因、每条命中的原始行）
./bin/mbot check --host <host> -u mbot_reader -p -o json --out-file report.json

# 3. 生成可贴进工单/文档的 markdown，或给 CI 用的 SARIF
./bin/mbot check ... -o markdown --out-file report.md
./bin/mbot check ... -o sarif   --out-file report.sarif

# 4. 只关心某一类
./bin/mbot check ... --dimension risk          # 只看风险
./bin/mbot check ... --only 'blocking_chains,metadata_lock_wait,idle_in_transaction'
./bin/mbot check ... --skip 'unused_index,redundant_index'
./bin/mbot check ... --min-severity warn       # 只报 warn 以上

# 5. 只看能力位（判断账号给够了没有）
./bin/mbot probe --host <host> -u mbot_reader -p

# 6. 列出/校验/生成规则文档
./bin/mbot list
./bin/mbot lint
./bin/mbot docs --out-file docs/findings.md
```

**连接方式**：`--dsn mysql://user:pass@host:port/`、或 `--host/--port/-u/-p`、或
`--socket`、或 `--defaults-file ~/.my.cnf`（复用 login-path）。密码也可走
`MYSQLBOT_PASSWORD` / `MYSQL_PWD` 环境变量，避免进 shell 历史。

**退出码**：`0` 无命中（达到 `--fail-on` 阈值以上）/ `1` 有命中 / `2` 连接或用法失败 /
`3` 规则契约问题。默认 `--fail-on warn`，CI 里可直接当门禁用。

## 怎么读输出

```
🟡 WARN      命中  2   干净 26   跳过 12   失败  0   （共 42 条规则）
```

四个数要分别汇报，其中 **跳过**最容易被忽略：

- **命中**：规则返回了行，每行都是证据。
- **干净**：规则跑通了且返回 0 行 —— 这才叫"检查过、没问题"。
- **跳过**：**没检查**。原因会逐条列出，典型是：
  - `缺少能力位 process`（账号权限不够）
  - `实例运行时间不足：累计计数器需要 1.0 小时，当前仅 11 分钟`
  - `MySQL >= 8.0 已移除该信号源`（版本门禁，设计如此）
  - `需要 MySQL >= 8.0.13`
- **失败**：规则执行报错。**这属于工具缺陷，要报上来**——它专指"SQL 与目标版本不匹配"
  （引用了目标版本不存在的列/变量），也就是规则的 `@since`/`@removed_in` 门禁漏了。
  工具**不会**把它降级成"跳过"，因为那样规则坏掉时会伪装成"环境限制"混过去。
  所以：**看到 `跳过` 想的是"该给权限"或"版本不适用"，看到 `失败` 想的是"工具要修"。**

另外两点读报告时必须注意：

- **行数可能是下限**。规则带 `LIMIT` 防刷屏，命中数达到上限时报告会把它标成 `≥N`
  （JSON 里是 `truncated: true`）。**不要把"N 行"当全量读。**
- 结构类规则（无主键表、冗余索引、超大表…）**只覆盖账号有 SELECT 权限的库**。
  报告里的 `capabilities.visible_schemas` 就是实际覆盖范围，没有全局 SELECT 时还会附一条
  note。**汇报时必须把它一起讲出来**——否则用户会把"没报无主键表"读成"整个实例都没有"。

## 规则库概览

42 条，分四个维度，完整目录见 `docs/findings.md`（由 `mbot docs` 从规则头部生成）。

| 维度 | 条数 | 覆盖内容 |
|---|---|---|
| `risk` | 16 | 长事务、空闲事务、行锁等待链（8.0+ 与 5.7 各一条）、元数据锁等待、undo 堆积、复制中断、从库可写、无主键表、非 InnoDB 表、binlog 关闭、提交不落盘 |
| `latency` | 12 | 缓冲池命中率、redo 容量与等待、临时表落盘、排序归并、表缓存/线程缓存未命中、全表扫描语句、累计最耗时语句 |
| `capacity` | 7 | 超大表、连接数余量、表缓存水位、redo 容量、binlog 保留策略（8.0+ 与 5.7 各一条） |
| `hygiene` | 7 | 冗余索引、未使用索引、索引统计失真、慢日志、统计信息缓存、强制主键 |

作用域（`schema` / `workload` / `instance` / `cluster` / `history`）与维度正交。

**有三对规则是"同一条发现的两个版本变体"**：`blocking_chains` / `blocking_chains_57`、
`binlog_retention_unbounded` / `binlog_retention_unbounded_57`。这些信号在 5.7 与 8.0+
用了两套完全不同的表达，单条 SQL 无法通吃；两条用 `@since`/`@removed_in` 互斥，
同一实例上只会启用其中一条。所以**规则总数是 42，但单次巡检最多启用 40 条**。

每条规则头部都带 `@remediation`（怎么修）、`@caveats`（什么情况下会误报）。
**汇报前先读 `@caveats`**，它写明了每条结论的可靠边界。

规则即纯 SQL，可以脱离工具单独跑：**返回 0 行 = 未命中，返回行 = 命中，每行必须含
`severity` 列**。所以用户完全可以在 DBeaver 里挑一条规则手工验证工具的结论。

## 账号授权

见 `sql/readonly_account.sql`，两档（权限到规则的完整对照见 `docs/compat-matrix.md`）：

- **A 档（零数据访问）**：`PROCESS` + `REPLICATION CLIENT` +
  `SELECT ON performance_schema.*` + `SELECT ON sys.*`。覆盖 42 条里的 **36 条**，
  一行业务数据都读不到。看不到业务表结构与容量，因此结构类规则会被**显式跳过**。
- **B 档（完整覆盖）**：A 档 + 对业务 schema 的 `SELECT`。这样才能看到表结构/索引/容量。
  代价是"读数据"的权限也一并给出——这是 MySQL 的固有限制（没有 `pg_monitor` 那种
  "能看元信息但碰不到数据"的角色）。

⚠️ **最容易配错的一点**：以为"给了 `PROCESS` 就能读 performance_schema"。实测不行——
`performance_schema.threads` / `data_locks` / `metadata_locks` /
`events_statements_summary_by_digest` / `table_io_waits_summary_by_index_usage` /
`replication_*` 在只有 `PROCESS` 的账号下**全部返回 1142**（只有 `global_status`
与 `global_variables` 是默认开放的）。少了 `SELECT ON performance_schema.*`，
`blocking_chains` / `metadata_lock_wait` / `full_table_scan_heavy` /
`statement_high_total_latency` / `unused_index` 这 5 条会整条被跳过。

授权脚本里写了两者的取舍与验证查询，用之前先读一遍。

## 已知边界（汇报时要如实说明）

- **已在 Percona Server 5.7.44、Percona Server 8.0.43、MySQL 8.4.11 上跑过完整巡检，
  均为 0 条规则执行失败。** 逐条结果、版本敏感信号对照表与权限依赖见
  `docs/compat-matrix.md`——**换新实例前先看一眼那张信号表**，能省掉一轮排查。
- **版本维度仍有空白**：8.4 只测过 8.4.11、5.7 只测过 5.7.44 一个点。
  `@since: 5.7` 表示"已在 5.7.44 上实测执行通过"，不代表 5.7.0~5.7.43 都测过。
- **5.7 那一轮是用 `root` 跑的**，验证的是"SQL 与版本是否兼容"，
  不是"最小权限账号下能跑几条"；权限维度的实测结论来自 8.0.43 的业务账号。
- **两条锁等待规则未在真实争用下比对过**（`blocking_chains` 走 8.0 的 `data_lock_waits`、
  `blocking_chains_57` 走 5.7 的 `INNODB_LOCK_WAITS`），只验证了"无争用返回 0 行"。
- **复制类规则未在真实从库上测**（三个实例都不是从库）。
- **不依赖 `sys` 的格式化视图**。实测结论：`sys` 视图是 `SQL SECURITY INVOKER`，
  且其函数（`format_time` 等）`DEFINER=mysql.sys` 只有 `USAGE` —— 所以最小权限账号
  查 `sys.statement_analysis` 会拿到 `ERROR 1356`，`GRANT SELECT ON sys.*` 并不够用。
  本工具的做法是核心发现一律直读 `performance_schema`，只保留两个经实测可读的
  `sys` 视图依赖（`schema_redundant_indexes` / `schema_unused_indexes`）。
- **没有 `advise` 类能力**。pgbot 能用 hypopg 造假设索引、让规划器确认成本下降才敢建议；
  MySQL/MariaDB 都没有假设索引，所以本工具**不给"加了这个索引会快多少"的承诺**，
  只指出"这条语句没走索引、扫了 N 行"。
- **采样类结论天生不可靠**。`unused_index` 需要实例运行满 3 天才可信，`sampled` 精确度
  的规则要配合业务周期（月末、季末）复核。

## 自测（改了规则一定要跑）

```bash
# ① 端到端回归（8.4）：种违规 → 只读账号巡检 → 硬断言
tests/local_instance.sh start     # /tmp 下起一个一次性 MySQL 实例
tests/run_tests.sh
tests/local_instance.sh stop

# ② 跨版本兼容性：对任意真实实例断言"42 条规则全部执行成功、0 条报错"
tests/live_compat.sh --defaults-file ~/.my.cnf --label '5.7.44'

# ③ 单测（不连库）
python3 tests/test_grants.py      # 授权解析 / 能力位判定
python3 tests/test_classify.py    # 错误分类 / LIMIT 截断判定
```

①做三件事：断言**没有任何规则执行报错**、断言 17 条植入的违规**必须被抓到**、
把跳过项摊开列出。`tests/expected_hits_soft.txt` 里还备案了哪些规则在一次性实例上
**无法确定性复现**及原因。

①有个盲区：它跑在本机 8.4 上，所以只能抓到"8.4 的 SQL 不兼容"。5.7/8.0 侧的问题
（比如某个列是 8.0.22+ 才有的）只有连到那两个版本的真实实例才会现形——补这块的是②。
②只发 SELECT，可以直接对生产实例跑；**改完规则后至少要在目标版本上跑一次②**。

③里的两个单测抓的是端到端抓不到的两类 bug：`test_grants.py` 管"能力位算错但不报错"
（规则照样命中、报告照样出，只是门禁失效了）；`test_classify.py` 管"把工具缺陷
降级成环境限制"（规则坏掉时会伪装成"跳过"）。

规则库的改动流程：改 `rules/*.sql` → `./bin/mbot lint` → `tests/run_tests.sh` →
`tests/live_compat.sh`（在有 5.7/8.0 实例时）→ `./bin/mbot docs --out-file docs/findings.md`。

> 注意：`tests/local_instance.sh` 起的实例是**后台进程**，随父 shell 退出会被回收。
> 要 `start && run_tests` 写在同一条命令里。

## 目录结构

```
mysqlbot/
├── SKILL.md                本文件
├── README.md               仓库说明
├── bin/mbot                启动器
├── mbot/                   实现（rule 解析 / conn / probe / runner / report / cli）
├── rules/*.sql             42 条规则（核心资产）
├── sql/readonly_account.sql  只读账号授权脚本（按实测权限模型写）
├── docs/findings.md        规则目录（自动生成）
├── docs/design.md          设计决策与踩过的坑（19 条）
├── docs/compat-matrix.md   版本验证矩阵（5.7/8.0/8.4 结果、版本敏感信号对照表、权限-规则对照）
└── tests/                  自测装置（端到端 + 跨版本 + 两个单测）
```
