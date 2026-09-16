# mysqlbot

**只读、确定性、无 agent 的 MySQL 体检探头。** 跑一次给结论，不部署、不常驻、不往被探测的
库里写任何东西。

设计思路参考 [pgbot](https://github.com/pgrundev/pgbot)（PostgreSQL 侧的同类工具），
把它的五条设计公理搬到 MySQL：**结论由确定性规则算出，LLM 只负责解释**。

```
🟡 WARN      命中 19   干净 21   跳过  2   失败  0   （共 42 条规则）
```

**已实测通过 MySQL 5.7 / 8.0 / 8.4 三个大版本**，逐版本结果与版本敏感信号对照表见
`docs/compat-matrix.md`。

## 五条设计公理

1. **只读是角色，不是开关。** 权限由 `GRANT` 决定，工具链里根本没有写路径。
2. **发现全部确定性算出来。** 42 条规则就是 42 段纯 SQL，没有任何模型参与判断。
3. **降级而不报错。** 能力位缺失、版本不符、运行时间不足 → **显式跳过并说明原因**，
   绝不静默返回"干净"。**但"SQL 与目标版本不匹配"不在此列**——那是工具缺陷，
   必须报 `失败`，否则规则坏掉时会伪装成"环境限制"混过去。
4. **每条结论都带精确度标签。** `exact` / `catalog` / `cumulative` / `sampled` / `scraped`。
5. **输出是契约，不是日志。** JSON / Markdown / SARIF / 人读表格，同一份数据。

## 安装

零依赖：只要本机有 `mysql` 客户端和 Python 3.9+。可选的 `PyMySQL` 用于 `--driver pymysql`。

```bash
git clone <this-repo> mysqlbot && cd mysqlbot
./bin/mbot doctor --host 127.0.0.1 -u root -p     # 自检
```

## 用法

```bash
./bin/mbot check   --host H -u mbot_reader -p          # 体检（人读表格）
./bin/mbot check   --host H -u mbot_reader -p -o json  # 完整契约
./bin/mbot probe   --host H -u mbot_reader -p          # 只探能力位
./bin/mbot list                                        # 列出规则
./bin/mbot lint                                        # 校验规则契约
./bin/mbot docs    --out-file docs/findings.md         # 生成规则目录
```

常用过滤：`--only` / `--skip` / `--dimension` / `--scope` / `--tag` / `--min-severity`。
退出码 `0/1/2/3`，默认 `--fail-on warn`，可直接做 CI 门禁（`-o sarif` 接 GitHub Code Scanning）。

## 规则契约

一条规则 = 一个 `.sql` 文件，头部是 `-- @key: value` 元数据，之后是 SQL。

```
-- @id: blocking_chains
-- @title: 存在行锁等待链
-- @severity: warn
-- @dimension: risk
-- @requires: p_s_locks,process
-- @exactness: catalog
-- @since: 8.0
-- @min_uptime: 0
-- @remediation: ...
-- @caveats: ...
-- @safety: KILL <blocking_pid>
-- @safety_note: ...
SELECT ...   -- 返回 0 行 = 未命中；返回行 = 命中；每行必须含 severity 列
```

**关键性质**：每条规则都能脱离本工具、直接在 mysql 客户端或 DBeaver 里单独执行验证。
这是刻意的——用户不该被迫相信一个黑盒。`./bin/mbot lint` 会强制检查元数据完整性
（含受控词表、`@safety` 必须配 `@safety_note`、SQL 必须出现 `severity`）。

`severity` 列让规则能**动态升级**自身严重度，例如行锁等待跨过 300 秒就从 `warn` 变 `critical`。

## 规则库

42 条，四个维度：

| 维度 | 条数 | 代表规则 |
|---|---|---|
| `risk` | 16 | `blocking_chains`、`blocking_chains_57`、`metadata_lock_wait`、`idle_in_transaction`、`long_running_transaction`、`table_without_primary_key`、`trx_commit_not_durable` |
| `latency` | 12 | `buffer_pool_hit_low`、`tmp_table_disk_spill`、`statement_high_total_latency`、`innodb_log_waits` |
| `hygiene` | 7 | `redundant_index`、`unused_index`、`stats_expiry_too_long`、`stale_index_statistics` |
| `capacity` | 7 | `oversized_table`、`connection_headroom_low`、`binlog_retention_unbounded` |

严重度分布：`critical` 2 / `warn` 24 / `info` 16；其中 4 条规则的证据列含**可执行语句**
（`DROP INDEX` / `KILL`），会在报告里单独标注。

完整目录含每条规则的处置建议、误报条件与 SQL 源码：`docs/findings.md`。

### 同一条发现的两个版本变体

`binlog_retention_unbounded` 与 `binlog_retention_unbounded_57`、
`blocking_chains` 与 `blocking_chains_57` 是**成对存在**的：这些信号在 5.7 与 8.0+
用了两套完全不同的表达（`expire_logs_days` vs `binlog_expire_logs_seconds`；
`INNODB_LOCK_WAITS` vs `data_lock_waits`），单条 SQL 无法通吃。
两条规则用 `@since` / `@removed_in` 互斥，同一实例上只会启用其中一条，不会重复报。

## 只读账号

`sql/readonly_account.sql` 提供两档授权：

- **A 档（零数据访问）**：`PROCESS` + `REPLICATION CLIENT` +
  `SELECT ON performance_schema.*` + `SELECT ON sys.*` —— 覆盖 42 条里的 36 条，
  一行业务数据都读不到。**注意 `PROCESS` 换不来 performance_schema 的读权限**
  （实测：`threads` / `data_locks` / `metadata_locks` / `events_statements_summary_by_digest`
  全部返回 1142），必须显式授 `performance_schema` 的 SELECT。
- **B 档**：A 档 + 业务 schema 的 `SELECT` —— 结构类规则（无主键表、冗余索引、
  超大表等 6 条）才能工作。

MySQL **没有** `pg_monitor` 那样的"能看全库元信息但碰不到数据"的角色
（`information_schema` 是按权限过滤的），这是授权上必须做的取舍，脚本里写清了。
权限到规则的完整对应关系见 `docs/compat-matrix.md` 第四节。

## 架构

```
mbot/
├── rule.py     规则头部解析、版本与受控词表
├── conn.py     连接层（mysql 客户端 / PyMySQL 双后端）+ 错误分类
├── probe.py    能力位探测（逐行解析 GRANT + 向 information_schema 要权威可见库清单）+ 实例事实
├── runner.py   门禁编排（版本 → 运行时长 → 能力位）+ 契约校验
├── report.py   table / json / markdown / sarif 四种渲染
└── cli.py      check / probe / list / lint / doctor / docs
```

`probe.py` 有几处值得一提：

- **授权逐行解析**。绝不能对整段 `SHOW GRANTS` 文本做 `"ALL PRIVILEGES" in text`
  这类子串判断——只对某一个库授了 ALL PRIVILEGES 的业务账号会被误判成拥有全局
  权限，能力门禁随之失效。回归测试见 `tests/test_grants.py`。
- **可见 schema 问服务器要**。`SELECT DISTINCT TABLE_SCHEMA FROM information_schema.TABLES`
  返回的就是结构类规则实际覆盖的范围（I_S 本来就按权限过滤），比解析授权文本权威，
  也顺带支持"按 schema 逐个授权"。

两处值得一提的设计：

- **错误分类看"该由谁去修"，不看严重程度。** `conn.py` 把 MySQL 错误码分成两类：
  `1142` 权限不足、`1146` 表不存在这类指向**整个对象**的问题 → `跳过`（换个账号或装上
  `sys` 就能解决，是环境的事）；`1054` 列不存在、`1193` 变量不存在这类指向
  **某个列/变量**的问题 → `失败`（是规则的 SQL 写法与目标版本对不上，是工具的事）。
  这个区分很要紧：如果把后者也降级成"跳过"，规则坏掉时会伪装成"环境限制"，
  而自测里"0 条报错"这条硬断言就变成了空话。回归测试见 `tests/test_classify.py`。
- **会话前导**。MySQL 8.0 起 `information_schema` 的表统计默认缓存 24 小时
  （`information_schema_stats_expiry=86400`）。工具会在**每条规则的同一个连接里**
  先执行 `SET SESSION information_schema_stats_expiry = 0`，否则所有基于表大小/行数的
  发现读到的都是过期值。

## 自测

```bash
# ① 端到端回归（8.4）：种违规 → 只读账号巡检 → 硬断言
tests/local_instance.sh start   # /tmp 下起一个一次性 MySQL 实例（32M 缓冲池等特殊配置）
tests/run_tests.sh
tests/local_instance.sh stop

# ② 跨版本兼容性：对任意真实实例断言"42 条规则全部执行成功、0 条报错"
tests/live_compat.sh --defaults-file ~/.my.cnf --label '8.0.43'

# ③ 单测（不连库）
python3 tests/test_grants.py      # 授权解析 / 能力位判定
python3 tests/test_classify.py    # 错误分类 / LIMIT 截断判定
```

①断言三件事：**0 条规则执行报错**、17 条植入违规全部命中、跳过项摊开列出。
`tests/expected_hits_soft.txt` 里备案了哪些规则在一次性实例上无法确定性复现及原因。

②是①的补充。①跑在本机 8.4 上，所以只能抓到"8.4 的 SQL 不兼容"；5.7/8.0 侧的问题
只有连到那两个版本的真实实例才会现形。它只读，可以直接对生产实例跑。

③里的两个单测守的是端到端抓不到的 bug：能力位算错但不报错（门禁失效）、
错误分类把工具缺陷降级成环境限制。

> ①会 `DROP DATABASE` 并修改 GLOBAL 配置，所以内置安全闸：只允许指向 `/tmp`
> 下的一次性实例。②只发 SELECT，无此限制。

## 已知边界

- **MySQL 5.7.44 / Percona 8.0.43 / MySQL 8.4.11 三个版本上都跑过完整巡检，
  均为 0 条规则执行失败。** 逐条结果、版本敏感信号对照表与权限依赖见
  `docs/compat-matrix.md`。
- **版本维度仍有空白**：8.4 只测过 8.4.11、5.7 只测过 5.7.44 一个点。
  `@since: 5.7` 表示"已在 5.7.44 上实测执行通过"，不代表 5.7.0~5.7.43 都测过
  （5.7.3 之前的 `performance_schema.metadata_locks` 缺失尚未处理）。
- **5.7 那一轮用的是 `root` 账号**，验证的是"SQL 与版本是否兼容"，
  不是"最小权限账号下能跑几条"；权限维度的实测来自 8.0.43 的业务账号。
- **两条锁等待规则未在真实争用下比对过**（`blocking_chains` 用 8.0 的
  `data_lock_waits`、`blocking_chains_57` 用 5.7 的 `INNODB_LOCK_WAITS`），
  只验证了"无争用返回 0 行"。
- **复制类规则未在真实从库上测**（三个实例都不是从库）。
- 不做索引建议验证（MySQL 没有 hypopg，无法确认规划器会不会真的采用）。
- 不依赖 `sys` 的格式化视图（实测 `sys` 视图是 `SQL SECURITY INVOKER`、
  `sys` 函数 DEFINER 只有 `USAGE`，最小权限账号查 `sys.statement_analysis` 会报 1356）。
- 结构类规则只覆盖账号**有 SELECT 权限**的 schema。报告里会列出 `visible_schemas`
  并附一条覆盖范围说明——汇报时不能只说"没发现无主键表"，还要说"只扫了这几个库"。
- 规则带 `LIMIT` 防刷屏。命中数达到上限时报告会标成 `≥N` 并在 JSON 里出
  `truncated: true`——**不要把"N 行"当全量读**。

详见 `docs/design.md`（设计决策与踩过的坑）、`docs/compat-matrix.md`（版本验证矩阵）。

## 路线

- [x] MySQL 8.0 实测回归（Percona 8.0.43 全量 + 8.0.25 针对性复验）
- [x] MySQL 5.7 实测回归（Percona 5.7.44 全量）
- [x] 5.7 的锁等待路径（`blocking_chains_57`，走 `INNODB_LOCK_WAITS`）
- [ ] 在真实争用下比对两条锁等待规则的结果是否等价
- [ ] 复制延迟（需要为 `SHOW REPLICA STATUS` 引入一套受控的非 SELECT 规则模式）
- [ ] MariaDB 实测
- [ ] 基线对比：保存上次 JSON，diff 出"新增 / 已闭环 / 仍存在"
- [ ] 阈值可通过 `mbot.toml` 覆盖，而不必改 SQL
- [ ] 自研 `redundant_index` / `unused_index` 判定，去掉对 `sys` 视图的依赖
