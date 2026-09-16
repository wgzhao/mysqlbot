---
name: mysqlbot
description: 对 MySQL/MariaDB 实例做**只读、确定性、无 agent** 的健康体检，输出结构化隐患清单（工作负载/风险/schema/容量/持久性五类 41 条规则）。适用于"给 MySQL 做体检""查 MySQL 有什么隐患""库慢在哪""有没有长事务/锁等待/元数据锁""表结构有什么问题""没主键的表""冗余索引""binlog 会不会撑盘""准备上线前扫一遍库"。当用户要求巡检 MySQL、排查数据库风险、或需要把数据库体检做成 CI 门禁/SARIF 报告时使用。不写库、不改配置、不 kill 会话——只出结论与建议命令，变更由用户自己执行。
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
🟡 WARN      命中  2   干净 26   跳过 12   失败  0   （共 40 条规则）
```

四个数要分别汇报，其中 **跳过**最容易被忽略：

- **命中**：规则返回了行，每行都是证据。
- **干净**：规则跑通了且返回 0 行 —— 这才叫"检查过、没问题"。
- **跳过**：**没检查**。原因会逐条列出，典型是：
  - `缺少能力位 process`（账号权限不够）
  - `实例运行时间不足：累计计数器需要 1.0 小时，当前仅 11 分钟`
  - `MySQL >= 8.0 已移除该信号源`
  - `需要 MySQL >= 8.0.13`
- **失败**：规则执行报错（SQL 与目标版本不匹配）。**这属于工具缺陷，要报上来**。

## 规则库概览

41 条，按五个维度划分，完整目录见 `docs/findings.md`（由 `mbot docs` 从规则头部生成）。

| 维度 | 覆盖内容 |
|---|---|
| `risk` | 长事务、空闲事务、行锁等待链、元数据锁等待、undo 堆积、复制中断、从库可写、无主键表、非 InnoDB 表、binlog 关闭、提交不落盘 |
| `latency` | 缓冲池命中率、redo 容量与等待、临时表落盘、排序归并、表缓存/线程缓存未命中、全表扫描语句、累计最耗时语句 |
| `capacity` | 超大表、连接数余量、表缓存水位、redo 容量、binlog 保留策略 |
| `hygiene` | 冗余索引、未使用索引、索引统计失真、慢日志、统计信息缓存、强制主键 |
| `schema`/`workload`/`instance`/`cluster` | 作用域，与维度正交 |

每条规则头部都带 `@remediation`（怎么修）、`@caveats`（什么情况下会误报）。
**汇报前先读 `@caveats`**，它写明了每条结论的可靠边界。

规则即纯 SQL，可以脱离工具单独跑：**返回 0 行 = 未命中，返回行 = 命中，每行必须含
`severity` 列**。所以用户完全可以在 DBeaver 里挑一条规则手工验证工具的结论。

## 账号授权

见 `sql/readonly_account.sql`，两档：

- **A 档（零数据访问）**：`PROCESS` + `REPLICATION CLIENT` + `SELECT ON sys.*`。
  能看性能计数器、锁、事务、语句摘要、复制状态；看不到业务表结构与容量，
  因此结构类规则会被**显式跳过**。
- **B 档（完整覆盖）**：A 档 + 对业务 schema 的 `SELECT`。这样才能看到表结构/索引/容量。
  代价是"读数据"的权限也一并给出——这是 MySQL 的固有限制（没有 `pg_monitor` 那种
  "能看元信息但碰不到数据"的角色）。

授权脚本里写了两者的取舍与验证查询，用之前先读一遍。

## 已知边界（汇报时要如实说明）

- **实测环境只有 MySQL 8.4**。规则声明的 `@since: 5.7` 表示信号源在 5.7 存在，
  但**未在真实 5.7/8.0 上验证过**。用户有 5.7.44 实例，第一次跑之前先 `doctor` + `probe`
  确认能力位，遇到 `失败` 状态的规则直接反馈。
- **`blocking_chains` 只覆盖 8.0+**（5.7 用 `information_schema.INNODB_LOCK_WAITS`，
  字段结构不同，尚未覆盖该版本路径）。
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
tests/local_instance.sh start     # /tmp 下起一个一次性 MySQL 实例
tests/run_tests.sh                # 种违规 → 只读账号巡检 → 断言
tests/local_instance.sh stop
```

自测做三件事：①断言**没有任何规则执行报错**（专抓 SQL 与版本不匹配）；
②断言 17 条植入的违规**必须被抓到**；③把跳过项摊开列出。
`tests/expected_hits_soft.txt` 里还备案了哪些规则在一次性实例上**无法确定性复现**及原因。

规则库的改动流程：改 `rules/*.sql` → `./bin/mbot lint` → `tests/run_tests.sh` →
`./bin/mbot docs --out-file docs/findings.md`。

## 目录结构

```
mysqlbot/
├── SKILL.md                本文件
├── README.md               仓库说明
├── bin/mbot                启动器
├── mbot/                   实现（rule 解析 / conn / probe / runner / report / cli）
├── rules/*.sql             41 条规则（核心资产）
├── sql/readonly_account.sql  只读账号授权脚本
├── docs/findings.md        规则目录（自动生成）
├── docs/design.md          设计决策与踩过的坑
└── tests/                  自测装置
```
