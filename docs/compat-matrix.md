# 版本兼容性验证矩阵

> 目标：把「只在本机 MySQL 8.4 上跑过」这件事，扩展成 **5.7 / 8.0 / 8.4 三个大版本**
> 都有实测依据。
> 本文只记录**跑出来的事实**与**因此改掉的东西**，不写推测。

## 一、结论速览

| 版本 | 环境 | 状态 | 结果 |
|---|---|---|---|
| **5.7.44-48** | `<实例 A>`（Percona Server），账号 `<redacted-user>@%` | ✅ 已验证 | 42 条 · 命中 6 · 干净 32 · 跳过 4 · **失败 0** |
| **8.0.43-34** | `<实例 B>`（Percona Server），业务账号 `biz_user` | ✅ 已验证 | 42 条 · 命中 9 · 干净 22 · 跳过 11 · **失败 0** |
| **8.0.25** | `<实例 C>`，账号 `biz_user` | ⚠️ 针对性复验 | 修掉 1 个 8.0 早期版本特有的跳过 |
| **8.4.11** | 本机一次性实例（`tests/local_instance.sh`），只读账号 `mbot_reader` | ✅ 已验证 | 42 条 · 命中 19 · 干净 21 · 跳过 2 · **失败 0**；17 条植入违规全部命中 |

**一句话**：三个大版本上**没有任何一条规则执行失败**。所有未覆盖项都被**显式列出原因**，
且可以逐条归因到"版本不适用"或"账号缺权限"这两类，没有一项是含糊的。

三个版本的跳过数差别很大（4 / 11 / 2），原因不在规则质量，而在**账号权限**：
5.7 用的是 `root`、8.4 用的是自建的 A 档+B 档只读账号，都能读到 `performance_schema`
与 `sys`；8.0.43 是一个**生产业务账号**，只有 `PROCESS` 和 11 个库的 ALL，读不到 P_S。
换句话说：**5.7 那一轮验证的是"SQL 与版本是否兼容"，8.0.43 那一轮验证的是"最小权限下能跑几条"。**
两件事都需要，但不能互相替代。

---

## 二、版本敏感信号对照表（本文最有用的部分）

规则挂掉的原因几乎从来不是"语法不兼容"，而是**某个列/变量在目标版本不存在**。
下表全部是**在三个实例上 `SELECT @@var` / `SHOW COLUMNS` 实测出来的**，不是查文档得来的：

| 信号 | 5.7.44 | 8.0.43 | 8.4.11 | 谁在用 |
|---|---|---|---|---|
| `@@expire_logs_days` | ✅ `7` | ✅ `0`（已废弃） | ❌ **已移除** | `binlog_retention_unbounded_57`（`@removed_in: 8.0`） |
| `@@binlog_expire_logs_seconds` | ❌ | ✅ `2592000` | ✅ `2592000` | `binlog_retention_unbounded`（`@since: 8.0`） |
| `@@binlog_expire_logs_auto_purge` | ❌ | ✅ `ON` | ✅ `ON` | `binlog_retention_unbounded`（缺失按 `ON` 处理） |
| `@@innodb_redo_log_capacity` | ❌ | ✅ `100 MB` | ✅ `100 MB` | `innodb_redo_undersized` / `innodb_log_waits` |
| `@@innodb_log_file_size` | ✅ `2 GB` | ✅ `48 MB` | ✅ `48 MB` | 同上（作为上者的回退） |
| `@@innodb_log_files_in_group` | ✅ `2` | ✅ `2` | ✅ `2` | 同上 |
| `@@information_schema_stats_expiry` | ❌ | ✅ `86400` | ✅ `86400` | `stats_expiry_too_long`（`@since: 8.0`） |
| `@@sql_require_primary_key` | ❌ | ✅ `OFF` | ✅ `OFF` | `sql_require_primary_key_off`（`@since: 8.0.13`） |
| `performance_schema.data_locks` / `data_lock_waits` | ❌ 表不存在 | ✅ | ✅ | `blocking_chains`（`@since: 8.0`） |
| `information_schema.INNODB_LOCKS` / `INNODB_LOCK_WAITS` | ✅ 存在（已 deprecated） | ❌ **已移除** | ❌ **已移除** | `blocking_chains_57`（`@removed_in: 8.0`） |
| `performance_schema.metadata_locks` | ✅ 自 5.7.3 起 | ✅ | ✅ | `metadata_lock_wait`（`@since: 5.7`） |
| `events_statements_summary_by_digest.DIGEST_TEXT` | ✅ | ✅ | ✅ | `full_table_scan_heavy`、`statement_high_total_latency` |
| `...QUERY_SAMPLE_TEXT` | ❌ | ✅（8.0.22+） | ✅ | 已不再引用（坑 16） |
| `replication_applier_status_by_worker.LAST_SEEN_TRANSACTION` | ✅ | ❌ **已移除** | ❌ **已移除** | 已不再引用（坑 17） |
| `...APPLYING_TRANSACTION` / `..._RETRIES_COUNT` | ❌ | ✅（8.0.23+） | ✅ | 已不再引用（坑 17） |
| `information_schema.GLOBAL_VARIABLES` | ✅ | ✅（已废弃） | ❌ **已移除** | 全部规则（改用 `performance_schema.global_variables` 与 `@@var`） |

**读法**：一条规则如果引用了"❌"那一格的信号，就必然在该版本上报 1054/1193。
所有这类引用都必须在规则头部用 `@since` / `@removed_in` 声明确实适用范围，
或者改用三版都有交集的列。

三条值得单独记住的：

1. **`expire_logs_days` 在 8.4 被移除了**，而 `binlog_expire_logs_seconds` 在 8.0 才有。
   也就是说"binlog 保留时长"这个信号**在三个版本里用了三套不同的表达**，
   任何单条 SQL 都不可能通吃。这正是 `binlog_retention_unbounded` 与
   `binlog_retention_unbounded_57` 必须成对存在的原因。
2. **8.0.43 上 `expire_logs_days = 0` 而 `binlog_expire_logs_seconds = 2592000`**。
   如果 `_57` 那条规则没被 `@removed_in: 8.0` 挡掉，它会在 8.0 上**误报**
   "binlog 永不清理"。门禁是对的。
3. **`replication_applier_status_by_worker` 的列名被改过两次**：`LAST_SEEN_TRANSACTION`
   是 5.7 独有（8.0 起换成 `LAST_APPLIED_TRANSACTION`），
   `APPLYING_TRANSACTION_RETRIES_COUNT` 是 8.0.23+ 才有。
   三版真正的交集只有 7 个列——`CHANNEL_NAME` / `WORKER_ID` / `THREAD_ID` /
   `SERVICE_STATE` / `LAST_ERROR_NUMBER` / `LAST_ERROR_MESSAGE` / `LAST_ERROR_TIMESTAMP`。

---

## 三、5.7.44 全量结果

```
🟡 WARN      命中  6   干净 32   跳过  4   失败  0   （共 42 条规则）
```

目标：Percona Server 5.7.44-48 · 账号 `<redacted-user>@%` · `log_bin=ON`、`server_id=<已设置>`、
`performance_schema=ON` · 实例运行 15 天 · **不是从库**（复制表全空）。
结构类规则覆盖 **1 个 schema**：`app_db`（这台机器上唯一的业务库，64 张表）。

### 3.1 命中（6 条，均已独立复核）

| 规则 | 严重度 | 行数 | 关键证据 |
|---|---|---|---|
| `sync_binlog_not_1` | warn | 1 | `sync_binlog = 10`（开了 binlog 却不每次提交刷盘） |
| `trx_commit_not_durable` | warn | 1 | `innodb_flush_log_at_trx_commit = 2` |
| `non_innodb_table` | warn | 7 | `app_db` 里 7 张 MyISAM 表，`t_member_copy` 8.9 万行 / 225 MB |
| `unused_index` | warn | **≥50**（截断） | `t_video_rec`（152 万行 / 1.2 GB）上 `src_hash_index`、`dst_hash_index` 等零使用 |
| `stale_index_statistics` | info | 15 | `t_record`（24.6 万行）的 `branch`、`system` 索引基数都是 **1** |
| `long_query_time_high` | info | 1 | `long_query_time = 2s` |

### 3.2 干净（32 条）

| 规则 |
|---|
| `auto_increment_exhaustion`、`binlog_cache_disk_spill`、`binlog_retention_unbounded_57`、`blocking_chains_57`、`buffer_pool_hit_low`、`buffer_pool_undersized`、`connection_headroom_low`、`connection_saturation`、`full_table_scan_heavy`、`idle_in_transaction`、`innodb_file_per_table_off`、`innodb_log_waits`、`innodb_redo_undersized`、`innodb_row_lock_contention`、`log_bin_off`、`long_running_transaction`、`metadata_lock_wait`、`open_tables_pressure`、`oversized_table`、`performance_schema_off`、`redundant_index`、`replica_writable`、`replication_io_error`、`replication_stopped`、`slow_query_log_off`、`sort_merge_passes`、`statement_high_total_latency`、`table_open_cache_miss`、`table_without_primary_key`、`thread_cache_miss`、`tmp_table_disk_spill`、`undo_history_list_long` |

抽查独立核验（避免"规则返回 0 行"被误信为"检查过"）：

| 规则 | 独立查询验证的底线事实 | 与规则结论 |
|---|---|---|
| `non_innodb_table` | 全实例非 InnoDB 基表 **107** 张，其中业务库（`app_db`）**7** 张 | 一致（`mysql` / `performance_schema` 等系统库被规则正确排除） |
| `full_table_scan_heavy` | `events_statements_summary_by_digest` 有 93 行，业务库 5 行；但满足 `COUNT_STAR≥10 且 SUM_NO_INDEX_USED>0 且 SUM_ROWS_EXAMINED≥10 万` 的 **0 行** | 一致（不是空跑，是阈值没过） |
| `statement_high_total_latency` | 满足 `COUNT_STAR≥100 且 SUM_TIMER_WAIT≥10s` 的 **0 行** | 一致 |
| `DIGEST_TEXT` 可用性 | `app_db` 下读出 `USE \`app_db\``（3092 次）等 5 条摘要 | 一致（改成 `DIGEST_TEXT` 后 5.7 真能取到内容） |
| `log_bin_off` | `log_bin = ON` | 一致 |
| `innodb_redo_undersized` | redo = `innodb_log_file_size`(2 GB) × `innodb_log_files_in_group`(2) = 4 GB，缓冲池 16 GB，**比值 0.25** | 一致（阈值是 `< 0.25`，0.25 不触发；踩在边界上） |
| `unused_index` 截断 | `sys.schema_unused_indexes` 155 条，按"非唯一 + 表 ≥10 MB"过滤后 **66** 条 | 规则报 50（`LIMIT 50`），**真实 ≥ 66** |

### 3.3 跳过（4 条）—— **这不等于"没问题"**

| 规则 | 跳过原因 |
|---|---|
| `binlog_retention_unbounded` | `需要 MySQL >= 8.0`（本版本走 `_57`） |
| `blocking_chains` | `需要 MySQL >= 8.0`（本版本走 `blocking_chains_57`） |
| `stats_expiry_too_long` | `需要 MySQL >= 8.0`（5.7 没有 `information_schema_stats_expiry`，表统计本来就是实时算的，不存在过期问题） |
| `sql_require_primary_key_off` | `需要 MySQL >= 8.0.13` |

这 4 条**全部是版本门禁**，没有一条是因为账号权限——`root` 的能力位是 15 开 / 1 关
（唯一关的是 `p_s_locks`，因为 5.7 根本没有 `data_locks`）。

---

## 四、8.0.43 全量结果

```
🟡 WARN      命中  9   干净 22   跳过 11   失败  0   （共 42 条规则）
```

目标：Percona Server 8.0.43-34 · 账号 `biz_user@%` · 结构类规则覆盖 **10 个 schema**
（账号只对这 10 个库有 SELECT，其余库在 `information_schema` 里不可见）。

### 4.1 命中（9 条，均为可信结论）

| 规则 | 严重度 | 行数 | 关键证据 |
|---|---|---|---|
| `buffer_pool_undersized` | warn | 1 | 缓冲池 3.00 GB vs InnoDB 数据 4.35 GB（比值 0.69） |
| `innodb_redo_undersized` | warn | 1 | redo 100 MB = 缓冲池的 3.3%（8.0.30+ 走 `innodb_redo_log_capacity`） |
| `open_tables_pressure` | info | 1 | open_tables 3983 / table_open_cache 3995 = **99.7%**，缓存溢出 47027 次 |
| `stale_index_statistics` | info | 8 | `biz_db.t_call_records` 等，基数=1 但表有 88 万行 |
| `table_without_primary_key` | warn | 5 | `biz_db.t_order_sign_log`（4.3 万行）、`risk_db.t_assessment_pdf`（10.3 万行）等 |
| `long_query_time_high` | warn | 1 | `long_query_time = 10s` |
| `slow_query_log_off` | warn | 1 | `slow_query_log = OFF` |
| `stats_expiry_too_long` | warn | 1 | `information_schema_stats_expiry = 86400` |
| `sql_require_primary_key_off` | info | 1 | `sql_require_primary_key = OFF` |

### 4.2 干净（22 条）—— 这部分是可用的

| 规则 |
|---|
| `auto_increment_exhaustion`、`binlog_cache_disk_spill`、`binlog_retention_unbounded`、`buffer_pool_hit_low`、`connection_headroom_low`、`connection_saturation`、`idle_in_transaction`、`innodb_file_per_table_off`、`innodb_log_waits`、`innodb_row_lock_contention`、`log_bin_off`、`long_running_transaction`、`non_innodb_table`、`oversized_table`、`performance_schema_off`、`sort_merge_passes`、`sync_binlog_not_1`、`table_open_cache_miss`、`thread_cache_miss`、`tmp_table_disk_spill`、`trx_commit_not_durable`、`undo_history_list_long` |

抽查独立核验：

| 规则 | 独立查询验证的底线事实 | 与规则结论 |
|---|---|---|
| `non_innodb_table` | 非 InnoDB 表计数 = **0** | 一致 |
| `log_bin_off` | `log_bin = ON` | 一致 |
| `sync_binlog_not_1` | `sync_binlog = 1` | 一致 |
| `innodb_file_per_table_off` | `innodb_file_per_table = ON` | 一致 |
| `performance_schema_off` | `performance_schema = ON` | 一致 |
| `trx_commit_not_durable` | `innodb_flush_log_at_trx_commit = 1` | 一致 |
| `binlog_retention_unbounded` | `auto_purge=ON`、`binlog_expire_logs_seconds=2592000` | 一致 |
| `undo_history_list_long` | `trx_rseg_history_len = 668` | 一致 |
| `tmp_table_disk_spill` | 915 / 119387973 = 0.0008% | 一致 |
| `thread_cache_miss` | Threads_created 6176 / Connections 293403 = 2.1% | 一致 |
| `table_open_cache_miss` | 312813 / 1.39e9 = 0.02% | 一致 |
| `oversized_table` | 最大单表 907 MB | 一致 |

### 4.3 跳过（11 条）—— 全部是账号权限

| 规则 | 跳过原因 | 补什么权限能救回来 |
|---|---|---|
| `binlog_retention_unbounded_57` | `MySQL >= 8.0 已移除该信号源`（设计如此） | — |
| `blocking_chains_57` | 同上（设计如此） | — |
| `blocking_chains` | 缺少能力位 `p_s_locks` | `GRANT SELECT ON performance_schema.*` |
| `metadata_lock_wait` | 缺少能力位 `p_s_mdl` | 同上 |
| `full_table_scan_heavy` | 缺少能力位 `p_s_statements` | 同上 |
| `statement_high_total_latency` | 缺少能力位 `p_s_statements` | 同上 |
| `unused_index` | 缺少 `p_s_waits` + `sys_indexes` | `SELECT ON performance_schema.*` + `SELECT ON sys.*` |
| `redundant_index` | 缺少能力位 `sys` | `GRANT SELECT ON sys.*` |
| `replication_stopped` | 缺少能力位 `replication` | `GRANT REPLICATION CLIENT ON *.*` |
| `replication_io_error` | 同上 | 同上 |
| `replica_writable` | 同上 | 同上 |

> ⚠️ 关键事实：`PROCESS` **不够**。`biz_user` 账号有 `PROCESS ON *.*`，
> 但 `performance_schema.threads` / `data_locks` / `metadata_locks` /
> `events_statements_summary_by_digest` / `table_io_waits_summary_by_index_usage`
> / `replication_*` **全部返回 1142**。只有 `global_status` 与 `global_variables`
> 是不需要任何授权就能读的。要补齐上面 11 条里的 **9 条**，必须显式授
> `SELECT ON performance_schema.*` 与 `SELECT ON sys.*`（外加 `REPLICATION CLIENT`），
> 具体见 `sql/readonly_account.sql`（已按实测结论重写）。

---

## 五、8.4.11 全量结果（端到端回归）

```
🟡 WARN      命中 19   干净 21   跳过  2   失败  0   （共 42 条规则）
```

这是**唯一一个带硬断言的**环境：`tests/run_tests.sh` 先向一次性实例种下 17 处
**确定会违规**的结构与配置，再用只读账号 `mbot_reader` 巡检，断言
① 0 条规则执行报错、② 17 条植入违规全部命中。二者都通过。

跳过的 2 条是 `binlog_retention_unbounded_57` 与 `blocking_chains_57`——
都是 `MySQL >= 8.0 已移除该信号源`，即设计如此。

---

## 六、这一轮（5.7）暴露并修掉的 5 个缺陷

全部是**静默型**：不报错、不中断，只是结论错、门禁失效，或者把"没检查"说成"没问题"。
逐条详情见 `docs/design.md`（坑 15~19）。

| # | 缺陷 | 症状 | 影响版本 |
|---|---|---|---|
| 15 | **错误分类把「版本不匹配」降级成「跳过」** | 3 条规则带着真实的版本不兼容缺陷伪装成"环境限制"；自测"0 条报错"的硬断言变成空话 | 所有（判定逻辑本身错） |
| 16 | `QUERY_SAMPLE_TEXT` 是 8.0.22+ 才有的列 | `full_table_scan_heavy` / `statement_high_total_latency` 在 5.7 上整条报 1054 | 5.7（及一切 < 8.0.22） |
| 17 | `LAST_SEEN_TRANSACTION` 是 5.7 独有列 | `replication_stopped` 在 **8.0/8.4** 上报 1054 | 8.0+ |
| 18 | `metadata_lock_wait` 的 `@caveats` 谎称"5.7 没有 metadata_locks" | 规则被无谓地 `@since: 8.0` 挡掉，5.7 上白白少一条高价值风险规则 | 5.7 |
| 19 | `LIMIT` 截断在报告里不可见 | `unused_index` 报 50 行被读成"一共 50 条"，实际 ≥66 | 所有 |

> 坑 17 是**工具自己抓出来的**——它是在坑 15 修好之后立刻现形的。
> 修好之前，它会带着 5.7 的"干净"结果一路蒙混到 8.0/8.4 上静默失效。
> 这条比任何单个 bug 都更能说明坑 15 的价值。

改动清单：

```
mbot/conn.py    错误分类拆成三类：permission / missing_object（可降级）
                → skipped；version_mismatch / syntax（不可降级）→ error
mbot/runner.py  版本不匹配时给出可执行的错误信息（提示补 @since/@removed_in）；
                新增 _outer_limit()，解析规则最外层 LIMIT
mbot/report.py  Outcome 增加 row_limit / truncated；json 出这两个字段；
                markdown 与 table 把行数显示成"≥N"并加截断提示
rules/full_table_scan_heavy.sql         QUERY_SAMPLE_TEXT → DIGEST_TEXT
rules/statement_high_total_latency.sql  同上
rules/replication_stopped.sql           只保留三版列集交集（7 列）
rules/metadata_lock_wait.sql            @since 8.0 → 5.7；修正错误的 @caveats
rules/blocking_chains_57.sql            新增：5.7 的锁等待路径
                                        （INNODB_LOCK_WAITS + INNODB_LOCKS + INNODB_TRX）
tests/test_classify.py                  新增：错误分类 + LIMIT 截断判定单测（24 用例）
tests/live_compat.sh                    新增：对任意真实实例断言"0 条规则报错"
```

规则总数从 41 条变为 **42 条**（新增 `blocking_chains_57`）。

---

## 七、权限 → 规则 依赖矩阵

这张表回答"要给什么权限，才能让哪些规则跑起来"。授权语句见 `sql/readonly_account.sql`。

| 需要的权限 | 解锁的规则 | 是否读到业务数据 |
|---|---|---|
| 无（`global_status`/`global_variables` 默认可读） | `buffer_pool_hit_low`、`buffer_pool_undersized`、`connection_*`（2）、`innodb_*`（4）、`open_tables_pressure`、`sort_merge_passes`、`table_open_cache_miss`、`thread_cache_miss`、`tmp_table_disk_spill`、`binlog_cache_disk_spill`、`log_bin_off`、`sync_binlog_not_1`、`trx_commit_not_durable`、`innodb_file_per_table_off`、`performance_schema_off`、`slow_query_log_off`、`long_query_time_high`、`sql_require_primary_key_off`、`stats_expiry_too_long`、`binlog_retention_unbounded`、`binlog_retention_unbounded_57` | 否 |
| `PROCESS` | `long_running_transaction`、`idle_in_transaction`、`undo_history_list_long`、`blocking_chains_57`（5.7） | 否 |
| `SELECT ON performance_schema.*` | `blocking_chains`（8.0+）、`metadata_lock_wait`、`full_table_scan_heavy`、`statement_high_total_latency`、`unused_index`（半）、`replication_*`（3，另需 REPLICATION CLIENT） | 否（只有 SQL 摘要与锁信息） |
| `SELECT ON sys.*` | `redundant_index`、`unused_index`（另一半） | 否 |
| `REPLICATION CLIENT` | `replication_stopped`、`replication_io_error`、`replica_writable` | 否 |
| 对业务 schema 的 `SELECT` | `table_without_primary_key`、`non_innodb_table`、`oversized_table`、`stale_index_statistics`、`auto_increment_exhaustion`、`buffer_pool_undersized`（半） | **是**（MySQL 固有限制） |

前五行合起来就是 A 档（零数据访问），覆盖 42 条里的 **36 条**；
剩下 6 条需要业务库的 SELECT —— 也就是 MySQL 那个无法回避的取舍。

---

## 八、复现命令

```bash
# 8.4：本机一次性实例 + 端到端回归（17 条植入违规的硬断言）
tests/local_instance.sh start
tests/run_tests.sh
tests/local_instance.sh stop

# 5.7 / 8.0 / 8.4：对真实实例断言"42 条规则全部执行成功、0 条报错"
#   证书文件就是一份 mysql 客户端配置文件： [client] user/password/host/port
tests/live_compat.sh --defaults-file /tmp/mbot57.cnf   --label '5.7.44'
tests/live_compat.sh --defaults-file /tmp/mbot8040.cnf --label '8.0.43'

# 单测（不连库）
python3 tests/test_grants.py      # 授权解析 / 能力位判定
python3 tests/test_classify.py    # 错误分类 / LIMIT 截断判定

# 手工看某条规则的结果
./bin/mbot check --defaults-file x.cnf -o json --out-file r.json
jq -r '.rules[] | select(.status!="clean") | "\(.status)\t\(.rule)\t\(.reason // "")"' r.json
```

排查"某条规则为什么没跑"：

```bash
./bin/mbot check --defaults-file x.cnf -o json --out-file r.json
# error   → 工具缺陷（SQL 与版本不匹配），必须修规则
# skipped → 环境限制（版本门禁 或 缺权限），报告里逐条写明
```
