# mysqlbot

**只读、确定性、无 agent 的 MySQL 体检探头。** 跑一次给结论，不部署、不常驻、不往被探测的
库里写任何东西。

设计思路参考 [pgbot](https://github.com/pgrundev/pgbot)（PostgreSQL 侧的同类工具），
把它的五条设计公理搬到 MySQL：**结论由确定性规则算出，LLM 只负责解释**。

```
🟡 WARN      命中 19   干净 21   跳过  2   失败  0   （共 42 条规则）
```

**已实测通过 MySQL 5.7 / 8.0 / 8.4 / 9.7 四个大版本**，逐版本结果与版本敏感信号对照表见
`docs/compat-matrix.md`。8.4.11 与 9.7.2 的端到端结果**逐项相同**，而规则一行没改——
架构上的理由见 `docs/versioning.md`。

## 五条设计公理

1. **只读是角色，不是开关。** 权限由 `GRANT` 决定，工具链里根本没有写路径。
2. **发现全部确定性算出来。** 42 条规则就是 42 段纯 SQL，没有任何模型参与判断。
3. **降级而不报错。** 能力位缺失、版本不符、运行时间不足 → **显式跳过并说明原因**，
   绝不静默返回"干净"。**但"SQL 与目标版本不匹配"不在此列**——那是工具缺陷，
   必须报 `失败`，否则规则坏掉时会伪装成"环境限制"混过去。
4. **每条结论都带精确度标签。** `exact` / `catalog` / `cumulative` / `sampled` / `scraped`。
5. **输出是契约，不是日志。** JSON / Markdown / SARIF / 人读表格，同一份数据；
   连"为什么跳过"也有机器可读的 `skip_kind`，不靠匹配中文。

## 安装

零依赖：只要本机有 `mysql` 客户端和 Python 3.9+。可选的 `PyMySQL` 用于 `--driver pymysql`。

```bash
git clone <this-repo> mysqlbot && cd mysqlbot
./bin/mbot doctor --host 127.0.0.1 -u root -p     # 自检（含信号登记表与实例的核对）
```

## 用法

```bash
./bin/mbot check    --host H -u mbot_reader -p         # 体检（人读表格）
./bin/mbot check    --host H -u mbot_reader -p -o json # 完整契约
./bin/mbot probe    --host H -u mbot_reader -p         # 只探能力位
./bin/mbot list                                        # 列出规则
./bin/mbot lint                                        # 校验规则契约 + 版本一致性
./bin/mbot docs     --out-file docs/findings.md        # 生成规则目录

./bin/mbot coverage --at 9.7                           # 离线推演：这版上哪些规则会跑（不连库）
./bin/mbot coverage --matrix                           # 5.7/8.0/8.4/9.0/9.7 全版本网格
```

常用过滤：`--only` / `--skip` / `--dimension` / `--scope` / `--tag` / `--min-severity`。
退出码 `0/1/2/3`，默认 `--fail-on warn`，可直接做 CI 门禁（`-o sarif` 接 GitHub Code Scanning）。

## 规则契约

一条规则 = 一个 `.sql` 文件，头部是 `-- @key: value` 元数据，之后是 SQL。

```
-- @id: blocking_chains_57
-- @title: 存在行锁等待链（5.7 路径）
-- @severity: warn
-- @dimension: risk
-- @requires: process
-- @exactness: catalog
-- @since: 5.7
-- @removed_in: 8.0
-- @variant_of: blocking_chains      # 与基础规则成对，lint 断言两者无缝覆盖 [5.7, +∞)
-- @min_uptime: 0
-- @remediation: ...
-- @caveats: ...
-- @safety: KILL <blocking_pid>
-- @safety_note: ...
SELECT ...   -- 返回 0 行 = 未命中；返回行 = 命中；每行必须含 severity 列
```

**关键性质**：每条规则都能脱离本工具、直接在 mysql 客户端或 DBeaver 里单独执行验证。
这是刻意的——用户不该被迫相信一个黑盒。`./bin/mbot lint` 会强制检查：

- 元数据完整性（受控词表、`@safety` 必须配 `@safety_note`、SQL 必须出现 `severity`）
- **声明与正文的版本一致性**——`@since` 是否比正文实际引用的信号所需的版本更宽
  （跨次版本 = 错误、同线补丁级 = 提示）、硬引用了有上界的信号是否声明了 `@removed_in`
- **变体覆盖无空洞**——每个逻辑规则的变体集合必须无缝覆盖 `[5.7, +∞)`

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

## 版本兼容

规则文件用 `@since` / `@removed_in` 声明可用区间；**正文引用了哪些版本敏感信号**
由 `mbot/signals.py` 里的一张登记表负责校验。要点：

- **42 条里 38 条天然跨版本通用，真正需要变体的只有 2 条。** 所以没有按大版本切目录——
  版本维度和能力位维度是正交的，目录分不出来。
- **软查表 vs 硬引用**：`@@binlog_expire_logs_auto_purge` 在缺少它的版本上会让整条规则
  报 1193；改成 `MAX(CASE WHEN VARIABLE_NAME='...') FROM performance_schema.global_variables`
  则只是那次查询返回 NULL，规则自动退化。**三个在 8.4 被移除的变量全靠这个写法兜住**，
  所以 8.4/9.x 不需要改一行 SQL。
- **变体只在结构性差异时才存在**（表换了一整套、列名改了）。目前两对：
  `binlog_retention_unbounded` / `..._57`、`blocking_chains` / `blocking_chains_57`，
  用 `@variant_of` 显式声明，`@since` / `@removed_in` 互斥，同一实例上只启用一条。
- **登记表会被现实自动纠正。** 两个方向都堵住了：
  - **硬引用**缺变量会报 1193 → 规则变成 `error` → `live_compat.sh` 的推演对账看得见
    （`missing_object` / `实际失败但未预测到` 都会直接报出来）。
  - **软查表**缺变量是**哑的**（返回 NULL，规则既不报错也不跳过）→ 由 `mbot doctor`
    在连库时把登记表的 21 个变量信号逐条与实例核对存在性，不一致即自检失败。

为什么不按 `rules/common/` + `rules/5.7/` 切目录、以及加新版本时该怎么做（五步流程），
见 **[`docs/versioning.md`](docs/versioning.md)**。

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
权限到规则的完整对应关系见 `docs/compat-matrix.md` 第七节。

## 架构

```
mbot/
├── rule.py     规则头部解析、版本与受控词表
├── signals.py  版本敏感信号登记表 + 离线版本推演 + 变体覆盖检查
├── conn.py     连接层（mysql 客户端 / PyMySQL 双后端）+ 错误分类
├── probe.py    能力位探测（逐行解析 GRANT + 向 information_schema 要权威可见库清单）
│               + 实例事实 + 变量信号登记表 attestation
├── runner.py   门禁编排（版本 → 运行时长 → 能力位）+ 结构化 skip_kind
├── report.py   table / json / markdown / sarif 四种渲染
└── cli.py      check / probe / list / lint / doctor / docs / coverage
```

`probe.py` 有几处值得一提：

- **授权逐行解析**。绝不能对整段 `SHOW GRANTS` 文本做 `"ALL PRIVILEGES" in text`
  这类子串判断——只对某一个库授了 ALL PRIVILEGES 的业务账号会被误判成拥有全局
  权限，能力门禁随之失效。回归测试见 `tests/test_grants.py`。
- **可见 schema 问服务器要**。`SELECT DISTINCT TABLE_SCHEMA FROM information_schema.TABLES`
  返回的就是结构类规则实际覆盖的范围（I_S 本来就按权限过滤），比解析授权文本权威，
  也顺带支持"按 schema 逐个授权"。
- **变量信号与实例对账**（`attest_variable_signals`）。只核对**变量**，因为表名与列名
  一律是硬引用（缺了报 1146/1054，`error` 计数兜得住），只有变量存在"软查表"这种
  **哑失败**。MariaDB 与低于 5.7 的版本会显式跳过并写明原因。

`signals.py` 的核心是**硬引用 vs 软查表**的区分（同一个信号，两种用法，后果完全不同），
以及由它支撑的三态推演：`可运行` / `门禁跳过` / `版本风险`。详见 `docs/versioning.md`。

三处值得一提的设计：

- **错误分类看"该由谁去修"，不看严重程度。** `conn.py` 把 MySQL 错误码分成两类：
  `1142` 权限不足、`1146` 表不存在这类指向**整个对象**的问题 → `跳过`（换个账号或装上
  `sys` 就能解决，是环境的事）；`1054` 列不存在、`1193` 变量不存在这类指向
  **某个列/变量**的问题 → `失败`（是规则的 SQL 写法与目标版本对不上，是工具的事）。
  这个区分很要紧：如果把后者也降级成"跳过"，规则坏掉时会伪装成"环境限制"，
  而自测里"0 条报错"这条硬断言就变成了空话。回归测试见 `tests/test_classify.py`。
- **`skip_kind` 结构化**。跳过原因除了一句人读的 `reason`，还有机器可读的
  `version` / `uptime` / `capability` / `permission` / `missing_object`。
  有了它，`live_compat.sh` 才能**断言**"跳过是版本原因还是权限原因"——
  靠匹配中文会因为 `执行被拒（Table 'x' doesn't exist）` 归错桶，
  给出一个假的「✓ 一致」。
- **会话前导**。MySQL 8.0 起 `information_schema` 的表统计默认缓存 24 小时
  （`information_schema_stats_expiry=86400`）。工具会在**每条规则的同一个连接里**
  先执行 `SET SESSION information_schema_stats_expiry = 0`，否则所有基于表大小/行数的
  发现读到的都是过期值。

## 自测

```bash
# ① 单测（不连库，秒级）
tests/unit.sh          # = test_grants + test_classify + test_signals

# ② 端到端回归：种违规 → 只读账号巡检 → 硬断言
tests/local_instance.sh start   # /tmp 下起一个一次性 MySQL 实例（32M 缓冲池等特殊配置）
tests/run_tests.sh
tests/local_instance.sh stop

#    本机装了多个版本时，用环境变量指定要测哪一个（数据目录与端口也要隔离，避免撞车）
MYSQLD_BIN=/opt/homebrew/Cellar/mysql@9.7/9.7.2_1/bin/mysqld \
MYSQLBOT_TEST_HOME=/tmp/mysqlbot-test97 MYSQLBOT_TEST_PORT=13307 \
  tests/local_instance.sh start
MYSQLBOT_TEST_HOME=/tmp/mysqlbot-test97 tests/run_tests.sh
MYSQLBOT_TEST_HOME=/tmp/mysqlbot-test97 tests/local_instance.sh stop

# ③ 跨版本兼容性：对任意真实实例断言"42 条规则全部执行成功、0 条报错"
#    并做「离线推演 ↔ 实测」对账，登记表过期会直接报出来
tests/live_compat.sh --defaults-file ~/.my.cnf --label '8.0.43'
```

②断言三件事：**0 条规则执行报错**、17 条植入违规全部命中、跳过项摊开列出。
`tests/expected_hits_soft.txt` 里备案了哪些规则在一次性实例上无法确定性复现及原因。

③是②的补充。②跑在**本机默认那个 mysqld** 上，所以只能抓到那一个版本的 SQL 不兼容；
其余版本的问题只有连到对应版本的真实实例（或用 `MYSQLD_BIN` 另起一个）才会现形。
它只读，可以直接对生产实例跑。

①里三个单测守的都是**"不报错但结论错"**的类别，端到端抓不到：
授权解析错只会让工具"声称"自己有能力、错误分类错会让真缺陷伪装成"跳过"、
登记表错会让推演给出合理但错误的答案。

> ②会 `DROP DATABASE` 并修改 GLOBAL 配置，所以内置安全闸：只允许指向 `/tmp`
> 下的一次性实例。③只发 SELECT，无此限制。

## 已知边界

- **MySQL 5.7.44 / Percona 8.0.43 / MySQL 8.4.11 / MySQL 9.7.2 四个版本上都跑过完整巡检，
  均为 0 条规则执行失败**，且离线推演与实测**完全吻合**。逐条结果、版本敏感信号
  对照表与权限依赖见 `docs/compat-matrix.md`。
- **`9.0` 那一列仍是推演值**（没有 9.0 实例，且 9.0 不是 LTS）。`9.7.2` 已实测通过；
  特别验证了 9.1 重新设计过的 `performance_schema.data_locks` / `data_lock_waits`——
  实测**列集未变**，`blocking_chains` 照常命中。
- **登记表只覆盖它登记过的东西**。新出现的信号会被 `lint` 提示，但同名而语义变了
  的信号不能。兜底有两道：`live_compat.sh` 的 `missing_object` 检查（硬引用），
  以及 `doctor` 的变量信号 attestation（软引用）。
- **5.7 只测过 5.7.44 一个点**。`@since: 5.7` 表示"已在 5.7.44 上实测执行通过"；
  `@since: 5.7.3` / `5.7.8` 这类补丁级下界来自官方文档与单测，没有那些版本的实例。
- **5.7 那一轮用的是 `root` 账号**，验证的是"SQL 与版本是否兼容"，
  不是"最小权限账号下能跑几条"；权限维度的实测来自 8.0.43 的业务账号。
- **两条锁等待规则未在真实争用下比对过**（`blocking_chains` 用 8.0 的
  `data_lock_waits`、`blocking_chains_57` 用 5.7 的 `INNODB_LOCK_WAITS`），
  只验证了"无争用返回 0 行"以及在一次性实例的**植入**争用场景下各自命中。
- **复制类规则未在真实从库上测**（四个实例都不是从库）。
- 不做索引建议验证（MySQL 没有 hypopg，无法确认规划器会不会真的采用）。
- 不依赖 `sys` 的格式化视图（实测 `sys` 视图是 `SQL SECURITY INVOKER`、
  `sys` 函数 DEFINER 只有 `USAGE`，最小权限账号查 `sys.statement_analysis` 会报 1356）。
- 结构类规则只覆盖账号**有 SELECT 权限**的 schema。报告里会列出 `visible_schemas`
  并附一条覆盖范围说明——汇报时不能只说"没发现无主键表"，还要说"只扫了这几个库"。
- 规则带 `LIMIT` 防刷屏。命中数达到上限时报告会标成 `≥N` 并在 JSON 里出
  `truncated: true`——**不要把"N 行"当全量读**。

详见 `docs/design.md`（设计决策与踩过的坑）、`docs/versioning.md`（版本兼容架构）、
`docs/compat-matrix.md`（版本验证矩阵）。

## 路线

- [x] MySQL 8.0 实测回归（Percona 8.0.43 全量 + 8.0.25 针对性复验）
- [x] MySQL 5.7 实测回归（Percona 5.7.44 全量）
- [x] 5.7 的锁等待路径（`blocking_chains_57`，走 `INNODB_LOCK_WAITS`）
- [x] 版本契约机检（信号登记表 + 离线推演 + 变体覆盖空洞检测 + 推演↔实测对账）
- [x] MySQL 9.7 实测回归（本机 9.7.2 一次性实例：端到端 17 条硬断言全中、42 条 0 报错、
      推演对账吻合；规则一行未改）
- [ ] MySQL 9.0 实测回归（非 LTS，优先级低；`coverage --at 9.0` 已给出 ✗0）
- [ ] 在真实争用下比对两条锁等待规则的结果是否等价
- [ ] 复制延迟（需要为 `SHOW REPLICA STATUS` 引入一套受控的非 SELECT 规则模式）
- [ ] MariaDB 实测
- [ ] 基线对比：保存上次 JSON，diff 出"新增 / 已闭环 / 仍存在"
- [ ] 阈值可通过 `mbot.toml` 覆盖，而不必改 SQL
- [ ] 自研 `redundant_index` / `unused_index` 判定，去掉对 `sys` 视图的依赖
