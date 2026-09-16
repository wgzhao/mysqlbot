# mysqlbot

**只读、确定性、无 agent 的 MySQL 体检探头。** 跑一次给结论，不部署、不常驻、不往被探测的
库里写任何东西。

设计思路参考 [pgbot](https://github.com/pgrundev/pgbot)（PostgreSQL 侧的同类工具），
把它的五条设计公理搬到 MySQL：**结论由确定性规则算出，LLM 只负责解释**。

```
🟡 WARN      命中  2   干净 26   跳过 12   失败  0   （共 41 条规则）
```

## 五条设计公理

1. **只读是角色，不是开关。** 权限由 `GRANT` 决定，工具链里根本没有写路径。
2. **发现全部确定性算出来。** 41 条规则就是 41 段纯 SQL，没有任何模型参与判断。
3. **降级而不报错。** 能力位缺失、版本不符、运行时间不足 → **显式跳过并说明原因**，
   绝不静默返回"干净"。
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

41 条，五个维度：

| 维度 | 条数 | 代表规则 |
|---|---|---|
| `risk` | 15 | `blocking_chains`、`metadata_lock_wait`、`idle_in_transaction`、`long_running_transaction`、`table_without_primary_key`、`trx_commit_not_durable` |
| `latency` | 11 | `buffer_pool_hit_low`、`tmp_table_disk_spill`、`statement_high_total_latency`、`innodb_log_waits` |
| `hygiene` | 6 | `redundant_index`、`unused_index`、`stats_expiry_too_long` |
| `capacity` | 5 | `oversized_table`、`connection_headroom_low`、`binlog_retention_unbounded` |
| `throughput` | — | （预留） |

完整目录含每条规则的处置建议、误报条件与 SQL 源码：`docs/findings.md`。

## 只读账号

`sql/readonly_account.sql` 提供两档授权：

- **A 档**：`PROCESS` + `REPLICATION CLIENT` + `SELECT ON sys.*` —— 零数据访问，
  结构类规则会被显式跳过。
- **B 档**：A 档 + 业务 schema 的 `SELECT` —— 结构类规则才能工作。

MySQL **没有** `pg_monitor` 那样的"能看全库元信息但碰不到数据"的角色
（`information_schema` 是按权限过滤的），这是授权上必须做的取舍，脚本里写清了。

## 架构

```
mbot/
├── rule.py     规则头部解析、版本与受控词表
├── conn.py     连接层（mysql 客户端 / PyMySQL 双后端）+ 错误分类
├── probe.py    能力位探测（P_S / sys / PROCESS / 复制的可用性）+ 实例事实
├── runner.py   门禁编排（版本 → 运行时长 → 能力位）+ 契约校验
├── report.py   table / json / markdown / sarif 四种渲染
└── cli.py      check / probe / list / lint / doctor / docs
```

两处值得一提的设计：

- **错误分类**。`conn.py` 把 MySQL 错误码分成"权限不足"与"对象不存在"两类可降级错误，
  于是"账号权限不够"和"SQL 与版本不匹配"会分别表现为 `跳过` 和 `失败`，而不是一锅端。
- **会话前导**。MySQL 8.0 起 `information_schema` 的表统计默认缓存 24 小时
  （`information_schema_stats_expiry=86400`）。工具会在**每条规则的同一个连接里**
  先执行 `SET SESSION information_schema_stats_expiry = 0`，否则所有基于表大小/行数的
  发现读到的都是过期值。

## 自测

```bash
tests/local_instance.sh start   # /tmp 下起一个一次性 MySQL 实例（32M 缓冲池等特殊配置）
tests/run_tests.sh              # 种违规 → 只读账号巡检 → 断言
tests/local_instance.sh stop
```

断言三件事：**0 条规则执行报错**、17 条植入违规全部命中、跳过项摊开列出。
`tests/expected_hits_soft.txt` 里备案了哪些规则在一次性实例上无法确定性复现及原因。

> 自测脚本会 `DROP DATABASE` 并修改 GLOBAL 配置，所以内置安全闸：只允许指向 `/tmp`
> 下的一次性实例。

## 已知边界

- 实测环境为 **MySQL 8.4**。声明 `@since: 5.7` 表示信号源在 5.7 存在，但**未在
  真实 5.7/8.0 上验证**。
- `blocking_chains` 仅覆盖 8.0+。
- 不做索引建议验证（MySQL 没有 hypopg，无法确认规划器会不会真的采用）。
- 不依赖 `sys` 的格式化视图（实测 `sys` 视图是 `SQL SECURITY INVOKER`、
  `sys` 函数 DEFINER 只有 `USAGE`，最小权限账号查 `sys.statement_analysis` 会报 1356）。

详见 `docs/design.md`（设计决策与踩过的坑）。

## 路线

- [ ] 基线对比：保存上次 JSON，diff 出"新增 / 已闭环 / 仍存在"
- [ ] 5.7 的锁等待路径（`information_schema.INNODB_LOCK_WAITS`）
- [ ] 复制延迟（需要为 `SHOW REPLICA STATUS` 引入一套受控的非 SELECT 规则模式）
- [ ] MySQL 8.0 / 5.7 上的实测回归
- [ ] 阈值可通过 `mbot.toml` 覆盖，而不必改 SQL
