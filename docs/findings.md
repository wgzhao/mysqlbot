# mysqlbot 规则目录

共 **42** 条规则。本文件由 `mbot docs` 从每条规则头部的元数据生成，请勿手工编辑——改规则后重新生成即可。

## 阅读约定

- **严重度**：`critical` 需要立即处置；`warn` 需要评估；`info` 是事实陈述与优化建议。规则 SQL 可以用 `severity` 列升级自身严重度（例如等待时间跨过阈值）。
- **exactness（结论精确度）**：
  - `exact` 直接读出的事实（变量、版本）
  - `catalog` 来自数据字典的确定结构（表定义、锁、事务）
  - `cumulative` 自实例启动累计的计数器，重启清零
  - `sampled` 依赖统计采样，需运行足够久才可信
  - `scraped` 抓取的瞬时值
- **能力位（@requires）**：缺失时该规则会被**显式跳过**并在报告里列明原因，不会静默给出「干净」结论。
- **运行时长（@min_uptime）**：累计型指标在实例重启后无意义，不满足时同样显式跳过。
- 每条规则都是独立 SQL，可以在 mysql 客户端 / DBeaver 里直接单独执行：返回 0 行 = 未命中，返回行 = 命中，每行带 `severity` 列。

## 总览

| 严重度 | 规则 | 维度 | 作用域 | 对象 | 精确度 | 起始版本 | 依赖能力位 |
|---|---|---|---|---|---|---|---|
| critical | [`replication_io_error`](#replication_io_error) | risk | cluster | `replication` | catalog | 5.7 | p_s, replication |
| critical | [`replication_stopped`](#replication_stopped) | risk | cluster | `replication` | catalog | 5.7 | p_s, replication |
| warn | [`binlog_retention_unbounded`](#binlog_retention_unbounded) | capacity | instance | `setting:binlog_expire_logs_seconds` | exact | 8.0 | p_s |
| warn | [`binlog_retention_unbounded_57`](#binlog_retention_unbounded_57) | capacity | instance | `setting:expire_logs_days` | exact | 5.7 | - |
| warn | [`buffer_pool_undersized`](#buffer_pool_undersized) | capacity | schema | `setting:innodb_buffer_pool_size` | catalog | 5.7 | p_s, schema_select |
| warn | [`connection_headroom_low`](#connection_headroom_low) | capacity | instance | `setting:max_connections` | cumulative | 5.7 | p_s |
| warn | [`innodb_file_per_table_off`](#innodb_file_per_table_off) | capacity | instance | `setting:innodb_file_per_table` | exact | 5.7 | - |
| warn | [`performance_schema_off`](#performance_schema_off) | hygiene | instance | `setting:performance_schema` | exact | 5.7 | - |
| warn | [`slow_query_log_off`](#slow_query_log_off) | hygiene | instance | `setting:slow_query_log` | exact | 5.7 | - |
| warn | [`stats_expiry_too_long`](#stats_expiry_too_long) | hygiene | instance | `setting:information_schema_stats_expiry` | exact | 8.0 | - |
| warn | [`buffer_pool_hit_low`](#buffer_pool_hit_low) | latency | workload | `setting:innodb_buffer_pool_size` | cumulative | 5.7 | p_s |
| warn | [`innodb_log_waits`](#innodb_log_waits) | latency | instance | `setting:innodb_redo_log_capacity` | cumulative | 5.7 | p_s |
| warn | [`tmp_table_disk_spill`](#tmp_table_disk_spill) | latency | workload | `setting:tmp_table_size` | cumulative | 5.7 | p_s |
| warn | [`blocking_chains`](#blocking_chains) | risk | workload | `trx` | catalog | 8.0 | p_s_locks, process |
| warn | [`blocking_chains_57`](#blocking_chains_57) | risk | workload | `trx` | catalog | 5.7 | process |
| warn | [`connection_saturation`](#connection_saturation) | risk | workload | `setting:max_connections` | cumulative | 5.7 | p_s |
| warn | [`idle_in_transaction`](#idle_in_transaction) | risk | workload | `trx` | catalog | 5.7 | process |
| warn | [`log_bin_off`](#log_bin_off) | risk | instance | `setting:log_bin` | exact | 5.7 | - |
| warn | [`long_running_transaction`](#long_running_transaction) | risk | workload | `trx` | catalog | 5.7 | process |
| warn | [`metadata_lock_wait`](#metadata_lock_wait) | risk | workload | `table` | catalog | 5.7 | p_s_mdl, process |
| warn | [`non_innodb_table`](#non_innodb_table) | risk | schema | `table` | catalog | 5.7 | schema_select |
| warn | [`replica_writable`](#replica_writable) | risk | cluster | `replication` | catalog | 5.7 | p_s, replication |
| warn | [`sync_binlog_not_1`](#sync_binlog_not_1) | risk | instance | `setting:sync_binlog` | exact | 5.7 | - |
| warn | [`table_without_primary_key`](#table_without_primary_key) | risk | schema | `table` | catalog | 5.7 | schema_select |
| warn | [`trx_commit_not_durable`](#trx_commit_not_durable) | risk | instance | `setting:innodb_flush_log_at_trx_commit` | exact | 5.7 | - |
| warn | [`undo_history_list_long`](#undo_history_list_long) | risk | workload | `none` | sampled | 5.7 | process |
| info | [`open_tables_pressure`](#open_tables_pressure) | capacity | instance | `setting:table_open_cache` | scraped | 5.7 | p_s |
| info | [`oversized_table`](#oversized_table) | capacity | schema | `table` | catalog | 5.7 | schema_select |
| info | [`long_query_time_high`](#long_query_time_high) | hygiene | instance | `setting:long_query_time` | exact | 5.7 | - |
| info | [`redundant_index`](#redundant_index) | hygiene | schema | `index` | catalog | 5.7 | schema_select, sys |
| info | [`sql_require_primary_key_off`](#sql_require_primary_key_off) | hygiene | instance | `setting:sql_require_primary_key` | exact | 8.0.13 | - |
| info | [`unused_index`](#unused_index) | hygiene | schema | `index` | sampled | 5.7 | p_s_waits, schema_select, sys_indexes |
| info | [`binlog_cache_disk_spill`](#binlog_cache_disk_spill) | latency | workload | `setting:binlog_cache_size` | cumulative | 5.7 | p_s |
| info | [`full_table_scan_heavy`](#full_table_scan_heavy) | latency | workload | `statement` | cumulative | 5.7 | p_s_statements |
| info | [`innodb_redo_undersized`](#innodb_redo_undersized) | latency | instance | `setting:innodb_redo_log_capacity` | catalog | 5.7 | p_s |
| info | [`innodb_row_lock_contention`](#innodb_row_lock_contention) | latency | history | `none` | cumulative | 5.7 | p_s |
| info | [`sort_merge_passes`](#sort_merge_passes) | latency | workload | `setting:sort_buffer_size` | cumulative | 5.7 | p_s |
| info | [`stale_index_statistics`](#stale_index_statistics) | latency | schema | `index` | catalog | 5.7 | schema_select |
| info | [`statement_high_total_latency`](#statement_high_total_latency) | latency | workload | `statement` | cumulative | 5.7 | p_s_statements |
| info | [`table_open_cache_miss`](#table_open_cache_miss) | latency | instance | `setting:table_open_cache` | cumulative | 5.7 | p_s |
| info | [`thread_cache_miss`](#thread_cache_miss) | latency | instance | `setting:thread_cache_size` | cumulative | 5.7 | p_s |
| info | [`auto_increment_exhaustion`](#auto_increment_exhaustion) | risk | schema | `column` | catalog | 5.7 | schema_select |

## replication_io_error

**复制 IO 线程连接源端失败**

- 严重度 `critical` · 维度 `risk` · 作用域 `cluster` · 对象 `replication`
- 精确度 `catalog` · 起始版本 `5.7`
- 依赖能力位：`p_s`, `replication`
- 参考：-
- 标签：replication

**处置**：LAST_ERROR_NUMBER 非零几乎总是网络/认证/源端 binlog 已被清理三类原因之一。LAST_HEARTBEAT_TIMESTAMP 长期不更新（超过 heartbeat_interval 的若干倍）说明心跳也断了。先确认源端端口可达、复制账号未过期、以及 sync_binlog/binlog_expire_logs_seconds 是否把需要的 binlog 删掉了。

**注意（误报条件与局限）**：心跳时间戳受源端 slave_net_timeout 与 MASTER_HEARTBEAT_PERIOD 影响，源端空闲时也可能看起来"很久没心跳"——必须结合 LAST_ERROR_NUMBER 一起判断，本规则只输出有错误或服务未运行的通道。非复制实例上该表为空，返回 0 行。

<details><summary>SQL</summary>

```sql
SELECT
  'critical'                                  AS severity,
  c.CHANNEL_NAME                              AS channel_name,
  c.SERVICE_STATE                             AS service_state,
  c.LAST_ERROR_NUMBER                         AS last_error_number,
  LEFT(c.LAST_ERROR_MESSAGE, 240)             AS last_error_message,
  c.LAST_ERROR_TIMESTAMP                      AS last_error_at,
  c.LAST_HEARTBEAT_TIMESTAMP                  AS last_heartbeat_at,
  TIMESTAMPDIFF(SECOND, c.LAST_HEARTBEAT_TIMESTAMP, NOW()) AS heartbeat_age_seconds,
  c.COUNT_RECEIVED_HEARTBEATS                 AS heartbeats_received
FROM performance_schema.replication_connection_status c
WHERE c.LAST_ERROR_NUMBER <> 0
   OR c.SERVICE_STATE <> 'ON'
ORDER BY c.CHANNEL_NAME
```

</details>

## replication_stopped

**复制通道的 applier 未在运行或有错误**

- 严重度 `critical` · 维度 `risk` · 作用域 `cluster` · 对象 `replication`
- 精确度 `catalog` · 起始版本 `5.7`
- 依赖能力位：`p_s`, `replication`
- 参考：-
- 标签：replication

**处置**：LAST_ERROR_NUMBER 非零说明 SQL 线程因冲突/约束失败而停：先看 LAST_ERROR_MESSAGE，判断是数据不一致还是 DDL 顺序问题，修好后再 START REPLICA。SERVICE_STATE='OFF' 且无错误，通常是有人手动 STOP REPLICA 或 gtid 断档，先确认为什么停的，别直接拉起来。

**注意（误报条件与局限）**：本规则只覆盖 applier（SQL）线程。IO 线程的故障见 replication_io_error。在非复制实例上，performance_schema.replication_applier_status_by_worker 是空表，本规则返回 0 行——空不等于健康，只表示"这台不是从库"。读取 P_S 复制表需要 REPLICATION CLIENT 权限，缺权限时规则会被跳过而不是误报干净。**只选 5.7 / 8.0 / 8.4 三版都有交集的列**，这是刻意的：这个表的列名改过两次——LAST_SEEN_TRANSACTION（5.7 有，8.0 移除）、APPLYING_TRANSACTION 与 APPLYING_TRANSACTION_RETRIES_COUNT（8.0 才加）；引用任何一侧都会让规则在另一侧报 1054 而整条失效。代价是拿不到"正在应用哪个事务/重试了几次"，需要这些细节时按版本单独查：5.7 看 LAST_SEEN_TRANSACTION，8.0+ 看 LAST_APPLIED_TRANSACTION / APPLYING_TRANSACTION / APPLYING_TRANSACTION_RETRIES_COUNT。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN w.LAST_ERROR_NUMBER <> 0 THEN 'critical' ELSE 'warn' END AS severity,
  w.CHANNEL_NAME                       AS channel_name,
  w.WORKER_ID                          AS worker_id,
  w.SERVICE_STATE                      AS service_state,
  w.LAST_ERROR_NUMBER                  AS last_error_number,
  LEFT(w.LAST_ERROR_MESSAGE, 240)      AS last_error_message,
  w.LAST_ERROR_TIMESTAMP               AS last_error_at
FROM performance_schema.replication_applier_status_by_worker w
WHERE w.LAST_ERROR_NUMBER <> 0
   OR w.SERVICE_STATE <> 'ON'
ORDER BY w.CHANNEL_NAME, w.WORKER_ID
```

</details>

## binlog_retention_unbounded

**binlog 永不自动清理（存在撑满磁盘的风险）**

- 严重度 `warn` · 维度 `capacity` · 作用域 `instance` · 对象 `setting:binlog_expire_logs_seconds`
- 精确度 `exact` · 起始版本 `8.0`
- 依赖能力位：`p_s`
- 参考：-
- 标签：binlog, capacity

**处置**：log_bin=ON 但过期时间被显式设为 0（或自动清理被关掉），等于"永远不删 binlog"，写入量大的实例迟早把数据盘写满，而磁盘写满会连带 InnoDB 无法刷盘、实例整体不可写。设置 binlog_expire_logs_seconds 为一个与"最长可接受恢复点"匹配的值（默认 2592000 = 30 天），并确保 binlog_expire_logs_auto_purge=ON。设置过短会让从库断档后无法重连（需要的 binlog 已被删）——设之前先确认最长的主从延迟与备份窗口。

**注意（误报条件与局限）**：MySQL 8.0 中 binlog_expire_logs_seconds 优先于已废弃的 expire_logs_days，前者非零时后者被忽略，所以本规则只看前者的值。8.0 之前的版本用 expire_logs_days，见 binlog_retention_unbounded_57。**版本边界**：binlog_expire_logs_auto_purge 是 8.0.29 才引入的变量，在 8.0.0~8.0.28 上不存在；规则改为从 performance_schema.global_variables 取值并在缺失时按 'ON' 处理（那之前的版本只要 seconds 非零就会清理），因此不会在旧 8.0 上被 1193 拒绝。该规则不判断磁盘实际使用率：磁盘更大、写入更少的实例可能永远撑不满，此时把规则加入 skip 而不是改参数。

<details><summary>SQL</summary>

```sql
SELECT
  'warn'                            AS severity,
  'binlog_expire_logs_seconds'      AS variable_name,
  v.secs                            AS current_seconds,
  '2592000 (30 天)'                 AS suggested_value,
  v.log_bin                         AS log_bin,
  COALESCE(ap.VARIABLE_VALUE, 'ON') AS auto_purge,
  CASE
    WHEN COALESCE(ap.VARIABLE_VALUE, 'ON') = 'OFF'
      THEN 'binlog_expire_logs_auto_purge=OFF：过期时间被完全忽略，binlog 永不自动清理'
    ELSE 'binlog_expire_logs_seconds=0：没有设置过期时间'
  END                               AS hit_reason
FROM (
  SELECT @@log_bin AS log_bin, @@binlog_expire_logs_seconds AS secs
) v
LEFT JOIN performance_schema.global_variables ap
       ON ap.VARIABLE_NAME = 'binlog_expire_logs_auto_purge'
WHERE v.log_bin <> 0
  AND (v.secs = 0
       OR COALESCE(ap.VARIABLE_VALUE, 'ON') = 'OFF')
```

</details>

## binlog_retention_unbounded_57

**binlog 永不自动清理（5.7 口径：expire_logs_days=0）**

- 严重度 `warn` · 维度 `capacity` · 作用域 `instance` · 对象 `setting:expire_logs_days`
- 精确度 `exact` · 起始版本 `5.7` · 移除于 `8.0`
- 依赖能力位：无
- 参考：-
- 标签：binlog, capacity

**处置**：设置 expire_logs_days 为与"最长可接受恢复点"匹配的天数（如 7 或 30）。等于 0 表示永不自动清理 binlog，写入量大的实例会把磁盘写满。

**注意（误报条件与局限）**：8.0 起该变量被 binlog_expire_logs_seconds 取代（且 8.4 已彻底移除），所以本规则声明 @removed_in: 8.0 —— 在 8.0+ 上会被自动跳过，由 binlog_retention_unbounded 接手。这条规则的存在只为覆盖 5.7/5.6 的老实例，避免在那些版本上直接报"未知系统变量"。

<details><summary>SQL</summary>

```sql
SELECT
  'warn'                AS severity,
  'expire_logs_days'    AS variable_name,
  @@expire_logs_days    AS current_days,
  '7'                   AS suggested_days,
  @@log_bin             AS log_bin
FROM DUAL
WHERE @@log_bin <> 0
  AND @@expire_logs_days = 0
```

</details>

## buffer_pool_undersized

**InnoDB 缓冲池小于数据总量**

- 严重度 `warn` · 维度 `capacity` · 作用域 `schema` · 对象 `setting:innodb_buffer_pool_size`
- 精确度 `catalog` · 起始版本 `5.7`
- 依赖能力位：`p_s`, `schema_select`
- 参考：pgbot/work_mem_low

**处置**：若为独占数据库实例，缓冲池通常可给到物理内存的 60%~75%；与 Web 服务混布时按实际内存余量分配。目标是把工作集装进内存，而不是把全部数据装进内存。

**注意（误报条件与局限）**：缓冲池小于数据总量本身不一定有问题——只要热数据能装下就行。本规则是"需要进一步确认"的信号，不是结论。数据量小于 1GB 时不应命中。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN raw.ratio < 0.5 THEN 'critical' ELSE 'warn' END AS severity,
  ROUND(raw.pool_bytes / 1024 / 1024 / 1024, 2) AS pool_gb,
  ROUND(raw.data_bytes / 1024 / 1024 / 1024, 2) AS innodb_data_gb,
  ROUND(raw.ratio, 3) AS pool_to_data_ratio
FROM (
  SELECT
    bp.pool_bytes                                          AS pool_bytes,
    d.data_bytes                                           AS data_bytes,
    (bp.pool_bytes / NULLIF(d.data_bytes, 0))               AS ratio
  FROM
    (SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS pool_bytes
       FROM performance_schema.global_variables
      WHERE VARIABLE_NAME = 'innodb_buffer_pool_size') bp
  CROSS JOIN
    (SELECT SUM(DATA_LENGTH + INDEX_LENGTH) AS data_bytes
       FROM information_schema.TABLES
      WHERE ENGINE = 'InnoDB'
        AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')) d
) raw
WHERE raw.data_bytes > 1073741824
  AND raw.ratio < 1.0
```

</details>

## connection_headroom_low

**连接数余量不足（历史峰值逼近 max_connections）**

- 严重度 `warn` · 维度 `capacity` · 作用域 `instance` · 对象 `setting:max_connections`
- 精确度 `cumulative` · 起始版本 `5.7`
- 依赖能力位：`p_s`
- 参考：-
- 标签：connection, capacity

**处置**：Max_used_connections 是自实例启动以来的历史峰值，达到 max_connections 的那一刻，后续新连接会被直接拒绝（error 1040 Too many connections），连管理员都可能挤不进去。先判断峰值是多少、发生在什么时候：如果只是某次批量任务造成的尖峰，限制那个任务的并发比调大上限更合适；如果确实持续增长，再提高 max_connections，并同步评估内存（每连接约 数百 KB 到数 MB，取决于排序/连接缓冲区）与 open_files_limit。

**注意（误报条件与局限）**：Max_used_connections 自启动累计、不衰减，一次历史尖峰会让该指标长期保持高位直到重启——不要仅凭它调参，结合 Threads_connected 的常态水位一起看。另外建议始终给 max_connections 留出应急余量，并保留一个具备 CONNECTION_ADMIN（8.0+）/ SUPER 的账号作为"最后一把钥匙"。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN r.pct >= 95 THEN 'critical' ELSE 'warn' END AS severity,
  r.max_used          AS max_used_connections,
  r.max_conn          AS max_connections,
  ROUND(r.pct, 1)     AS peak_used_pct,
  r.threads_connected AS threads_connected_now,
  r.threads_running   AS threads_running_now,
  r.uptime_s          AS uptime_s
FROM (
  SELECT
    s.max_used,
    s.threads_connected,
    s.threads_running,
    s.uptime_s,
    v.max_conn,
    100 * s.max_used / NULLIF(v.max_conn, 0) AS pct
  FROM (
    SELECT
      MAX(CASE WHEN VARIABLE_NAME = 'Max_used_connections' THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS max_used,
      MAX(CASE WHEN VARIABLE_NAME = 'Threads_connected'    THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS threads_connected,
      MAX(CASE WHEN VARIABLE_NAME = 'Threads_running'      THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS threads_running,
      MAX(CASE WHEN VARIABLE_NAME = 'Uptime'               THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS uptime_s
    FROM performance_schema.global_status
  ) s
  CROSS JOIN (
    SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS max_conn
    FROM performance_schema.global_variables
    WHERE VARIABLE_NAME = 'max_connections'
  ) v
) r
WHERE r.max_conn > 0
  AND r.pct >= 80
```

</details>

## innodb_file_per_table_off

**未使用独立表空间（innodb_file_per_table=OFF）**

- 严重度 `warn` · 维度 `capacity` · 作用域 `instance` · 对象 `setting:innodb_file_per_table`
- 精确度 `exact` · 起始版本 `5.7`
- 依赖能力位：无
- 参考：-
- 标签：innodb, capacity

**处置**：改为 ON（动态生效，只影响之后新建/重建的表）。关闭时所有 InnoDB 表共用 ibdata1：**DROP TABLE 不会把空间还给操作系统**——删掉 500GB 的表，磁盘占用一点不减，只能靠导出重建整个实例来回收。打开后每表一个 .ibd 文件，DROP/TRUNCATE 即可释放，且支持单表压缩与单表传输。

**注意（误报条件与局限）**：改成 ON 之后，已有的表**仍留在 ibdata1 里**，需要 ALTER TABLE ... ENGINE=InnoDB（或 pt-online-schema-change）逐表重建才会迁出。这个重建过程对大实例是重活，要分批做并监控磁盘余量。另外 ibdata1 不会自动缩小，通常需要重建实例才能真正回收。

<details><summary>SQL</summary>

```sql
SELECT
  'warn'                    AS severity,
  'innodb_file_per_table'   AS variable_name,
  @@innodb_file_per_table   AS current_value,
  'ON'                      AS suggested_value,
  '已有表需 ALTER TABLE ... ENGINE=InnoDB 才会迁出 ibdata1' AS note
FROM DUAL
WHERE @@innodb_file_per_table = 0
```

</details>

## performance_schema_off

**performance_schema 未启用（丧失全部内建观测能力）**

- 严重度 `warn` · 维度 `hygiene` · 作用域 `instance` · 对象 `setting:performance_schema`
- 精确度 `exact` · 起始版本 `5.7`
- 依赖能力位：无
- 参考：-
- 标签：observability

**处置**：设为 ON 并重启。这不是"可选特性"：语句摘要、等待事件、索引使用统计、元数据锁与 data_locks——所有"哪条 SQL 慢、哪个索引没被用、谁锁住了谁"的证据链都在这里。关掉它之后，MySQL 只剩 SHOW STATUS 里那些粗粒度累计计数器，故障排查只能靠猜。

**注意（误报条件与局限）**：该参数**不能**动态修改，必须重启实例——这是本规则为 warn 而不是 critical 的原因（无法立即处置）。P_S 开着的代价是少量 CPU 与内存（默认可接受），高并发短查询场景可通过关闭部分 consumer/instrument 来降开销，而不必整个关掉。注意：P_S 关闭时本工具的其他 P_S 依赖规则会全部被跳过并在报告里逐条列出，不会静默给出"干净"结论。本规则用 @@performance_schema 判断，而不是去读 performance_schema 自己——关了就读不到了。

<details><summary>SQL</summary>

```sql
SELECT
  'warn'                AS severity,
  'performance_schema'  AS variable_name,
  @@performance_schema  AS current_value,
  'ON'                  AS suggested_value,
  '需要重启实例生效'      AS note
FROM DUAL
WHERE @@performance_schema = 0
```

</details>

## slow_query_log_off

**慢查询日志未开启**

- 严重度 `warn` · 维度 `hygiene` · 作用域 `instance` · 对象 `setting:slow_query_log`
- 精确度 `exact` · 起始版本 `5.7`
- 依赖能力位：无
- 参考：-
- 标签：observability, sql

**处置**：打开 slow_query_log（动态生效），并把 log_output 设为 FILE 或 TABLE。慢日志是事后定位"昨晚那波卡顿是谁造成的"唯一可靠的证据来源——P_S 的语句摘要只看得到统计聚合，看不到具体时刻和具体值。生产环境建议同时配上 log_slow_admin_statements 与 log_slow_extra 以补全元信息。

**注意（误报条件与局限）**：P_S 的 events_statements_summary_by_digest 能在一定程度上替代慢日志（本工具的其他规则就依赖它），所以"慢日志关闭"不等于"完全瞎"；但对需要精确复现单次问题的场景，慢日志不可替代。容器化部署时常把日志写到不受采集的路径，若已开启但从未被采集，本规则不会发现——它只检查开关。

<details><summary>SQL</summary>

```sql
SELECT
  'warn'             AS severity,
  'slow_query_log'   AS variable_name,
  @@slow_query_log   AS current_value,
  'ON'               AS suggested_value,
  @@long_query_time  AS long_query_time,
  @@log_output       AS log_output
FROM DUAL
WHERE @@slow_query_log = 0
```

</details>

## stats_expiry_too_long

**表统计信息使用缓存的过期值（information_schema_stats_expiry > 0）**

- 严重度 `warn` · 维度 `hygiene` · 作用域 `instance` · 对象 `setting:information_schema_stats_expiry`
- 精确度 `exact` · 起始版本 `8.0`
- 依赖能力位：无
- 参考：-
- 标签：statistics, optimizer

**处置**：设为 0（动态生效，全局与会话均可）。这个参数从 8.0 引入、默认 86400 秒，含义是：从 information_schema.TABLES / STATISTICS 读到的 TABLE_ROWS、DATA_LENGTH、CARDINALITY 等统计值，允许返回最多 24 小时前的缓存快照，而不是去存储引擎现取。后果有两层——**对监控是致命的**：任何"表多大、多少行、索引基数多少"的判断都可能基于一天前的数据，报出来的容量与倾斜结论直接是错的；**对业务影响较小**：优化器走的是自己的统计信息路径，不读这个缓存。

**注意（误报条件与局限）**：读的是 @@GLOBAL——本工具的巡检会话会把该变量强制置 0，若读会话值就会永远看不到这个问题。设成 0 之后，每次查询 information_schema 的统计列都会触发一次存储引擎采样，在表非常多（上万张）的实例上会带来可感知的开销；此时折中方案是设一个短周期（如 60 秒）而不是 0。本工具在跑规则前会在会话里强制置 0，所以 mysqlbot 自己的结论不受影响——这条规则针对的是"你手工查 information_schema 时会被它骗到"。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN @@GLOBAL.information_schema_stats_expiry >= 86400 THEN 'warn' ELSE 'info' END AS severity,
  'information_schema_stats_expiry'                        AS variable_name,
  @@GLOBAL.information_schema_stats_expiry                 AS current_seconds,
  ROUND(@@GLOBAL.information_schema_stats_expiry / 3600, 1) AS current_hours,
  '0'                                                      AS suggested_seconds,
  'mysqlbot 巡检时会话级强制置 0'                            AS mitigation
FROM DUAL
WHERE @@GLOBAL.information_schema_stats_expiry > 0
```

</details>

## buffer_pool_hit_low

**InnoDB 缓冲池命中率过低**

- 严重度 `warn` · 维度 `latency` · 作用域 `workload` · 对象 `setting:innodb_buffer_pool_size`
- 精确度 `cumulative` · 起始版本 `5.7`
- 依赖能力位：`p_s` · 需要运行满 3600s
- 参考：pgbot/low_cache_hit

**处置**：先对比 innodb_buffer_pool_size 与 InnoDB 数据总量；OLTP 期望命中率 > 99%。若缓冲池已足够大仍低，考虑是否有大范围扫描或全表扫描在冲刷缓冲池。

**注意（误报条件与局限）**：刚重启的实例比率不可信，已用运行时长门禁（@min_uptime: 1 小时）保证——不满足时本规则会被显式跳过并给出原因，而不是报"干净"。冷备份、大批量导入会临时拉低比率，不要据此改参数。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN raw.hit < 0.90 THEN 'critical' ELSE 'warn' END AS severity,
  ROUND(100 * raw.hit, 2) AS hit_pct,
  raw.disk_reads          AS disk_reads,
  raw.logical_reads       AS logical_reads,
  raw.uptime_s            AS uptime_s
FROM (
  SELECT
    (1 - a.disk / NULLIF(b.req, 0)) AS hit,
    a.disk     AS disk_reads,
    b.req      AS logical_reads,
    c.uptime   AS uptime_s
  FROM
    (SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS disk
       FROM performance_schema.global_status
      WHERE VARIABLE_NAME = 'Innodb_buffer_pool_reads') a
  CROSS JOIN
    (SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS req
       FROM performance_schema.global_status
      WHERE VARIABLE_NAME = 'Innodb_buffer_pool_read_requests') b
  CROSS JOIN
    (SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS uptime
       FROM performance_schema.global_status
      WHERE VARIABLE_NAME = 'Uptime') c
) raw
WHERE raw.hit < 0.95
  AND raw.logical_reads > 100000
```

</details>

## innodb_log_waits

**事务等待 redo log 空间（日志写入跟不上）**

- 严重度 `warn` · 维度 `latency` · 作用域 `instance` · 对象 `setting:innodb_redo_log_capacity`
- 精确度 `cumulative` · 起始版本 `5.7`
- 依赖能力位：`p_s`
- 参考：-
- 标签：innodb, redo

**处置**：只要有非零值就说明曾经有事务因为 redo 空间不足而等待——这是写入延迟的直接来源。MySQL 8.0.30+ 改用 innodb_redo_log_capacity（默认 100MB，动态可调），调大它通常立竿见影；5.7/8.0.29 以下是 innodb_log_file_size × innodb_log_files_in_group，需要重启。调大之前先确认磁盘能容纳。

**注意（误报条件与局限）**：在 MySQL 8.0.30 之后，redo log 由固定文件改为可动态调整的容量池，Innodb_log_waits 的统计口径也随之变化（不再是"等待 checkpoint"而是"等待写入 redo 缓冲区空间"），因此不同版本之间该数值不可直接比较。该计数器自实例启动累计，不重置；重启后清零。只要非零就报——因为"曾经等待"本身就说明容量规划偏紧。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN r.waits >= 100 THEN 'warn' ELSE 'info' END AS severity,
  r.waits                     AS log_waits,
  r.write_requests            AS log_write_requests,
  ROUND(100 * r.waits / NULLIF(r.write_requests, 0), 4) AS wait_pct,
  r.uptime_s                  AS uptime_s,
  r.redo_capacity_bytes       AS innodb_redo_log_capacity_bytes
FROM (
  SELECT
    s.waits,
    s.write_requests,
    s.uptime_s,
    COALESCE(v.redo_capacity_bytes, v.log_file_size_bytes) AS redo_capacity_bytes,
    s.waits / NULLIF(s.write_requests, 0) AS wait_rate
  FROM (
    SELECT
      MAX(CASE WHEN VARIABLE_NAME = 'Innodb_log_waits'          THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS waits,
      MAX(CASE WHEN VARIABLE_NAME = 'Innodb_log_write_requests' THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS write_requests,
      MAX(CASE WHEN VARIABLE_NAME = 'Uptime'                    THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS uptime_s
    FROM performance_schema.global_status
  ) s
  LEFT JOIN (
    SELECT
      CAST(MAX(CASE WHEN VARIABLE_NAME = 'innodb_redo_log_capacity' THEN VARIABLE_VALUE END) AS DECIMAL(30,0)) AS redo_capacity_bytes,
      CAST(MAX(CASE WHEN VARIABLE_NAME = 'innodb_log_file_size'     THEN VARIABLE_VALUE END) AS DECIMAL(30,0)) AS log_file_size_bytes
    FROM performance_schema.global_variables
    WHERE VARIABLE_NAME IN ('innodb_redo_log_capacity', 'innodb_log_file_size')
  ) v ON 1 = 1
) r
WHERE r.waits > 0
```

</details>

## tmp_table_disk_spill

**临时表大量落盘**

- 严重度 `warn` · 维度 `latency` · 作用域 `workload` · 对象 `setting:tmp_table_size`
- 精确度 `cumulative` · 起始版本 `5.7`
- 依赖能力位：`p_s` · 需要运行满 3600s
- 参考：pgbot/table_bloat

**处置**：同时调大 tmp_table_size 与 max_heap_table_size（两者必须一致，否则以较小者为准）；然后定位产生大临时表的查询——通常是 GROUP BY / DISTINCT 命中了 TEXT/BLOB 列，或 ORDER BY 无法走索引。

**注意（误报条件与局限）**：内部临时表分内存表与磁盘表，只有内存表超限才落盘。命中说明存在落盘，但落盘量小（绝对条数少）时不必处理，已用总临时表数 > 1000 做门禁。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN raw.ratio >= 0.5 THEN 'critical' ELSE 'warn' END AS severity,
  ROUND(100 * raw.ratio, 1) AS disk_tmp_pct,
  raw.disk_tmp              AS created_tmp_disk_tables,
  raw.total_tmp             AS created_tmp_tables,
  raw.uptime_s              AS uptime_s
FROM (
  SELECT
    (a.v / NULLIF(b.v, 0)) AS ratio,
    a.v                    AS disk_tmp,
    b.v                    AS total_tmp,
    c.v                    AS uptime_s
  FROM
    (SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS v
       FROM performance_schema.global_status
      WHERE VARIABLE_NAME = 'Created_tmp_disk_tables') a
  CROSS JOIN
    (SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS v
       FROM performance_schema.global_status
      WHERE VARIABLE_NAME = 'Created_tmp_tables') b
  CROSS JOIN
    (SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS v
       FROM performance_schema.global_status
      WHERE VARIABLE_NAME = 'Uptime') c
) raw
WHERE raw.ratio > 0.25
  AND raw.total_tmp > 1000
```

</details>

## blocking_chains

**存在行锁等待链（有事务在等另一事务持有的行锁）**

- 严重度 `warn` · 维度 `risk` · 作用域 `workload` · 对象 `trx`
- 精确度 `catalog` · 起始版本 `8.0`
- 依赖能力位：`p_s_locks`, `process`
- 参考：pgbot/blocking_chains
- 标签：lock, innodb

**处置**：先看 blocking 侧的 SQL：通常是缺索引导致锁范围放大（本该锁一行却锁了一片），或批量更新没有按主键排序造成交叉死锁。定位到阻塞方后，优先 kill 阻塞方而不是等待方——等待方往往是无辜的业务请求。真正要修的是阻塞方那条 SQL 的加锁范围。

**注意（误报条件与局限）**：直读 performance_schema.data_lock_waits / data_locks，**不走 sys.innodb_lock_waits**——因为 sys 视图是 SQL SECURITY INVOKER，且其函数 DEFINER mysql.sys 只有 USAGE，会让最小权限账号（只有 PROCESS + SELECT ON sys.*）拿到 1356 错误；直读 P_S 只需 PROCESS。代价是只覆盖 InnoDB 行锁，不含表锁与元数据锁（元数据锁见 metadata_lock_wait），且 5.7 没有 data_lock_waits 表（5.7 用 information_schema.INNODB_LOCK_WAITS，本工具暂未覆盖该版本路径）。等待时长取自 information_schema.INNODB_TRX.TRX_WAIT_STARTED，该列在事务开始等待时才会被赋值。已用"等待 >= 10 秒"过滤掉瞬时争用——1~2 秒的等待在正常写入下很常见，报出来是噪音。

**⚠️ 含可执行语句**：`KILL <blocking_pid>` — 证据列 suggested_kill 是一个可直接执行的 KILL 语句。kill 会回滚阻塞方未提交的事务——先确认那不是一个正在跑的关键批处理，否则会把一次"等待"变成一次"业务失败"。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN w.wait_s >= 300 THEN 'critical' ELSE 'warn' END AS severity,
  w.object_schema   AS locked_schema,
  w.object_name     AS locked_table,
  w.index_name      AS locked_index,
  w.lock_type       AS locked_type,
  w.lock_mode       AS waiting_lock_mode,
  w.lock_data       AS waiting_lock_data,
  w.wait_s          AS wait_seconds,
  w.waiting_pid     AS waiting_pid,
  w.waiting_user    AS waiting_user,
  w.waiting_query   AS waiting_query,
  w.blocking_pid    AS blocking_pid,
  w.blocking_user   AS blocking_user,
  w.blocking_query  AS blocking_query,
  w.blocking_trx    AS blocking_trx_id,
  w.kill_blocker    AS suggested_kill
FROM (
  SELECT
    rl.OBJECT_SCHEMA                                  AS object_schema,
    rl.OBJECT_NAME                                    AS object_name,
    rl.INDEX_NAME                                     AS index_name,
    rl.LOCK_TYPE                                      AS lock_type,
    rl.LOCK_MODE                                      AS lock_mode,
    LEFT(rl.LOCK_DATA, 80)                            AS lock_data,
    TIMESTAMPDIFF(SECOND, wt.TRX_WAIT_STARTED, NOW())  AS wait_s,
    rt.PROCESSLIST_ID                                 AS waiting_pid,
    rt.PROCESSLIST_USER                               AS waiting_user,
    LEFT(rt.PROCESSLIST_INFO, 200)                    AS waiting_query,
    gt.PROCESSLIST_ID                                 AS blocking_pid,
    gt.PROCESSLIST_USER                               AS blocking_user,
    LEFT(gt.PROCESSLIST_INFO, 200)                    AS blocking_query,
    bt.TRX_ID                                         AS blocking_trx,
    CONCAT('KILL ', gt.PROCESSLIST_ID, ';')           AS kill_blocker
  FROM performance_schema.data_lock_waits lw
  JOIN performance_schema.data_locks rl
    ON rl.ENGINE_LOCK_ID = lw.REQUESTING_ENGINE_LOCK_ID
  LEFT JOIN information_schema.INNODB_TRX wt
    ON wt.TRX_ID = CAST(lw.REQUESTING_ENGINE_TRANSACTION_ID AS UNSIGNED)
  LEFT JOIN information_schema.INNODB_TRX bt
    ON bt.TRX_ID = CAST(lw.BLOCKING_ENGINE_TRANSACTION_ID AS UNSIGNED)
  LEFT JOIN performance_schema.threads rt
    ON rt.THREAD_ID = lw.REQUESTING_THREAD_ID
  LEFT JOIN performance_schema.threads gt
    ON gt.THREAD_ID = lw.BLOCKING_THREAD_ID
) w
WHERE w.wait_s >= 10
ORDER BY w.wait_s DESC
```

</details>

## blocking_chains_57

**存在行锁等待链（5.7 路径）**

- 严重度 `warn` · 维度 `risk` · 作用域 `workload` · 对象 `trx`
- 精确度 `catalog` · 起始版本 `5.7` · 移除于 `8.0`
- 依赖能力位：`process`
- 参考：pgbot/blocking_chains
- 标签：lock, innodb

**处置**：先看 blocking 侧的 SQL：通常是缺索引导致锁范围放大（本该锁一行却锁了一片），或批量更新没有按主键排序造成交叉死锁。定位到阻塞方后，优先 kill 阻塞方而不是等待方——等待方往往是无辜的业务请求。真正要修的是阻塞方那条 SQL 的加锁范围。

**注意（误报条件与局限）**：这是 8.0 版 blocking_chains 的 5.7 变体。8.0 移除了 information_schema.INNODB_LOCKS 与 INNODB_LOCK_WAITS（改用 performance_schema.data_locks / data_lock_waits），所以两个版本必须用两套 SQL——规则用 @since/@removed_in 门禁，同一实例上只会启用其中一条，不会重复报。5.7 的 INNODB_LOCKS 只包含"正在等待的锁"和"正在阻塞别人的锁"，不含全部锁，这正好就是本规则关心的那部分。locked_schema / locked_table 由 LOCK_TABLE 按第一个点号切开，库名或表名里含点号时会切错——这种命名极少见，但看到可疑结果时以 LOCK_TABLE 原文为准。等待时长取自 TRX_WAIT_STARTED，该列在事务开始等待时才被赋值。已用"等待 >= 10 秒"过滤瞬时争用。INNODB_LOCKS 在 5.7 已是 deprecated 的 I_S 表，实例日志里可能有弃用告警，与本规则无关；它返回 0 行时不代表没有锁竞争，只代表此刻没有等待链。

**⚠️ 含可执行语句**：`KILL <blocking_pid>` — 证据列 suggested_kill 是一个可直接执行的 KILL 语句。kill 会回滚阻塞方未提交的事务——先确认那不是一个正在跑的关键批处理，否则会把一次"等待"变成一次"业务失败"。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN w.wait_s >= 300 THEN 'critical' ELSE 'warn' END AS severity,
  w.locked_schema   AS locked_schema,
  w.locked_table    AS locked_table,
  w.locked_index    AS locked_index,
  w.locked_type     AS locked_type,
  w.lock_mode       AS waiting_lock_mode,
  w.lock_data       AS waiting_lock_data,
  w.wait_s          AS wait_seconds,
  w.waiting_pid     AS waiting_pid,
  w.waiting_user    AS waiting_user,
  w.waiting_query   AS waiting_query,
  w.blocking_pid    AS blocking_pid,
  w.blocking_user   AS blocking_user,
  w.blocking_query  AS blocking_query,
  w.blocking_trx    AS blocking_trx_id,
  w.blocking_age_s  AS blocking_trx_age_seconds,
  w.kill_blocker    AS suggested_kill
FROM (
  SELECT
    REPLACE(SUBSTRING_INDEX(rl.LOCK_TABLE, '.', 1), '`', '')  AS locked_schema,
    REPLACE(SUBSTRING_INDEX(rl.LOCK_TABLE, '.', -1), '`', '') AS locked_table,
    rl.LOCK_INDEX                                             AS locked_index,
    rl.LOCK_TYPE                                              AS locked_type,
    rl.LOCK_MODE                                              AS lock_mode,
    LEFT(rl.LOCK_DATA, 80)                                    AS lock_data,
    TIMESTAMPDIFF(SECOND, wt.TRX_WAIT_STARTED, NOW())         AS wait_s,
    wt.TRX_MYSQL_THREAD_ID                                    AS waiting_pid,
    wp.USER                                                   AS waiting_user,
    LEFT(COALESCE(wt.TRX_QUERY, wp.INFO), 200)                 AS waiting_query,
    bt.TRX_MYSQL_THREAD_ID                                    AS blocking_pid,
    bp.USER                                                   AS blocking_user,
    LEFT(COALESCE(bt.TRX_QUERY, bp.INFO), 200)                 AS blocking_query,
    bt.TRX_ID                                                 AS blocking_trx,
    TIMESTAMPDIFF(SECOND, bt.TRX_STARTED, NOW())              AS blocking_age_s,
    CASE WHEN bt.TRX_MYSQL_THREAD_ID IS NULL
         THEN '(阻塞事务没有对应会话，无法 KILL——多半是已断开的连接残留)'
         ELSE CONCAT('KILL ', bt.TRX_MYSQL_THREAD_ID, ';')
    END                                                       AS kill_blocker
  FROM information_schema.INNODB_LOCK_WAITS lw
  JOIN information_schema.INNODB_LOCKS rl
    ON rl.LOCK_ID = lw.REQUESTED_LOCK_ID
  JOIN information_schema.INNODB_TRX wt
    ON wt.TRX_ID = lw.REQUESTING_TRX_ID
  JOIN information_schema.INNODB_TRX bt
    ON bt.TRX_ID = lw.BLOCKING_TRX_ID
  LEFT JOIN (SELECT ID, USER, INFO FROM information_schema.PROCESSLIST) wp
    ON wp.ID = wt.TRX_MYSQL_THREAD_ID
  LEFT JOIN (SELECT ID, USER, INFO FROM information_schema.PROCESSLIST) bp
    ON bp.ID = bt.TRX_MYSQL_THREAD_ID
) w
WHERE w.wait_s >= 10
  AND (w.waiting_user IS NULL
       OR w.waiting_user <> SUBSTRING_INDEX(CURRENT_USER(), '@', 1))
ORDER BY w.wait_s DESC
```

</details>

## connection_saturation

**连接数接近上限**

- 严重度 `warn` · 维度 `risk` · 作用域 `workload` · 对象 `setting:max_connections`
- 精确度 `cumulative` · 起始版本 `5.7`
- 依赖能力位：`p_s`
- 参考：pgbot/connection_saturation

**处置**：先查应用侧是否有连接泄漏（连接池未归还），再考虑提高 max_connections。盲目调大只会把压力转成线程与内存压力；MySQL 每连接开销远大于 PG。

**注意（误报条件与局限）**：瞬时高峰触发的命中不等于持续问题，建议连续几次观测都命中再动手；Threads_connected 是瞬时值，采样时点会影响结论。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN raw.used_ratio >= 0.95 THEN 'critical' ELSE 'warn' END AS severity,
  raw.threads_connected                                           AS threads_connected,
  raw.max_connections                                             AS max_connections,
  ROUND(100 * raw.used_ratio, 1)                                   AS used_pct,
  raw.threads_running                                             AS threads_running,
  raw.err_max_conn                                                AS conn_errors_max_connections
FROM (
  SELECT
    st.threads_connected,
    st.threads_running,
    st.err_max_conn,
    gv.mc                                    AS max_connections,
    (st.threads_connected / NULLIF(gv.mc, 0)) AS used_ratio
  FROM
    (SELECT
       MAX(CASE WHEN VARIABLE_NAME = 'Threads_connected' THEN CAST(VARIABLE_VALUE AS SIGNED) END) AS threads_connected,
       MAX(CASE WHEN VARIABLE_NAME = 'Threads_running'   THEN CAST(VARIABLE_VALUE AS SIGNED) END) AS threads_running,
       MAX(CASE WHEN VARIABLE_NAME = 'Connection_errors_max_connections'
                THEN CAST(VARIABLE_VALUE AS SIGNED) END)                                        AS err_max_conn
       FROM performance_schema.global_status
      WHERE VARIABLE_NAME IN ('Threads_connected', 'Threads_running', 'Connection_errors_max_connections')) st
  CROSS JOIN
    (SELECT CAST(VARIABLE_VALUE AS SIGNED) AS mc
       FROM performance_schema.global_variables
      WHERE VARIABLE_NAME = 'max_connections') gv
) raw
WHERE raw.max_connections > 0
  AND raw.used_ratio >= 0.85
```

</details>

## idle_in_transaction

**事务开着但没有语句在执行**

- 严重度 `warn` · 维度 `risk` · 作用域 `workload` · 对象 `trx`
- 精确度 `catalog` · 起始版本 `5.7`
- 依赖能力位：`process`
- 参考：pgbot/idle_in_transaction

**处置**：典型成因是应用取了连接、开了事务却忘了 commit/rollback（例如异常分支没有回滚）。它比长事务更隐蔽：CPU 和 QPS 都看不出来，但 purge 被卡住、undo 持续增长、行锁一直不释放。

**注意（误报条件与局限）**：判定依据是 TRX_STATE='RUNNING' 且 TRX_QUERY 为空——事务活着但此刻没有语句在跑。应用连接池在两条语句之间也会短暂呈现该状态，因此已用 60 秒做门禁。MySQL 不暴露"事务从何时开始空闲"，open_seconds 是事务总年龄，是空闲时长的上界。取会话的用户/来源走 information_schema.PROCESSLIST（只需 PROCESS），不用 performance_schema.threads——后者要 SELECT ON performance_schema.*，业务账号通常没有，用它会整条规则被拒。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN t.open_s >= 900 THEN 'critical' ELSE 'warn' END AS severity,
  t.trx_state   AS trx_state,
  t.started_at  AS started_at,
  t.open_s      AS open_seconds,
  t.thread_id   AS thread_id,
  t.db_user     AS db_user,
  t.client_host AS client_host,
  t.rows_locked AS rows_locked
FROM (
  SELECT
    trx.trx_state                                  AS trx_state,
    trx.trx_started                                AS started_at,
    TIMESTAMPDIFF(SECOND, trx.trx_started, NOW())   AS open_s,
    trx.trx_mysql_thread_id                         AS thread_id,
    pl.USER                                         AS db_user,
    pl.HOST                                         AS client_host,
    trx.trx_rows_locked                             AS rows_locked
  FROM information_schema.INNODB_TRX trx
  LEFT JOIN information_schema.PROCESSLIST pl
         ON pl.ID = trx.trx_mysql_thread_id
  WHERE trx.trx_state = 'RUNNING'
    AND trx.trx_query IS NULL
) t
WHERE t.open_s >= 60
  AND (t.db_user IS NULL
       OR t.db_user <> SUBSTRING_INDEX(CURRENT_USER(), '@', 1))
ORDER BY t.open_s DESC
```

</details>

## log_bin_off

**未开启 binlog（无法做时间点恢复，无法搭建从库）**

- 严重度 `warn` · 维度 `risk` · 作用域 `instance` · 对象 `setting:log_bin`
- 精确度 `exact` · 起始版本 `5.7`
- 依赖能力位：无
- 参考：-
- 标签：backup, replication

**处置**：开启 log_bin 并重启。没有 binlog 意味着恢复点只能到"最近一次全量备份"为止——误删一张表、误改一批数据，除了回滚到备份别无他法，中间几小时/几天的数据全部丢失。同时它也堵死了搭建从库、CDC 同步（Canal/Debezium）、审计追溯等一整类能力。

**注意（误报条件与局限）**：单机开发环境、纯缓存用途的实例刻意关闭是合理的，请加入 skip。开启 binlog 会带来额外写入量与磁盘占用，务必同时规划 binlog_expire_logs_seconds（见 binlog_retention_unbounded 规则）与磁盘容量。该参数需要重启生效，且开启后建议同时确认 server_id 非 0（复制要求，本规则一并输出）。

<details><summary>SQL</summary>

```sql
SELECT
  'warn'       AS severity,
  'log_bin'    AS variable_name,
  @@log_bin    AS current_value,
  'ON'         AS suggested_value,
  @@server_id  AS server_id,
  @@log_bin_basename AS log_bin_basename,
  '需要重启实例生效' AS note
FROM DUAL
WHERE @@log_bin = 0
```

</details>

## long_running_transaction

**存在长时间运行的事务**

- 严重度 `warn` · 维度 `risk` · 作用域 `workload` · 对象 `trx`
- 精确度 `catalog` · 起始版本 `5.7`
- 依赖能力位：`process`
- 参考：pgbot/long_running_transaction

**处置**：长事务会阻止 InnoDB purge、放大 undo 体积、并长时间持有行锁。先确认是应用漏了 commit（最常见）、还是批量任务本身过大（拆分批次）。必要时 kill 前务必确认会话用途。

**注意（误报条件与局限）**：大批量导入/DDL 期间长事务是预期的；只读长事务不发警告的前提是它不持有 undo，但 InnoDB 里无法区分，因此一律报出。取会话的用户/来源走 information_schema.PROCESSLIST 而不是 performance_schema.threads——后者需要 SELECT ON performance_schema.*，而业务账号通常没有，一旦用它会整条规则被拒（1142）、白白丢掉这条高价值发现；PROCESSLIST 在 5.7/8.0/8.4 都只需 PROCESS 即可看到全部会话。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN t.age_s >= 3600 THEN 'critical' ELSE 'warn' END AS severity,
  t.trx_state     AS trx_state,
  t.started_at    AS started_at,
  t.age_s         AS age_s,
  t.thread_id     AS thread_id,
  t.db_user       AS db_user,
  t.client_host   AS client_host,
  t.rows_locked   AS rows_locked,
  t.rows_modified AS rows_modified,
  t.query_head    AS query_head
FROM (
  SELECT
    trx.trx_id                                   AS trx_id,
    trx.trx_state                                AS trx_state,
    trx.trx_started                              AS started_at,
    TIMESTAMPDIFF(SECOND, trx.trx_started, NOW()) AS age_s,
    trx.trx_mysql_thread_id                       AS thread_id,
    pl.USER                                       AS db_user,
    pl.HOST                                       AS client_host,
    trx.trx_rows_locked                           AS rows_locked,
    trx.trx_rows_modified                         AS rows_modified,
    LEFT(COALESCE(trx.trx_query, '(idle)'), 200)  AS query_head
  FROM information_schema.INNODB_TRX trx
  LEFT JOIN information_schema.PROCESSLIST pl
         ON pl.ID = trx.trx_mysql_thread_id
) t
WHERE t.age_s >= 300
  AND (t.db_user IS NULL
       OR t.db_user <> SUBSTRING_INDEX(CURRENT_USER(), '@', 1))
ORDER BY t.age_s DESC
```

</details>

## metadata_lock_wait

**存在元数据锁（MDL）等待**

- 严重度 `warn` · 维度 `risk` · 作用域 `workload` · 对象 `table`
- 精确度 `catalog` · 起始版本 `5.7`
- 依赖能力位：`p_s_mdl`, `process`
- 参考：-

**处置**：MDL 等待意味着有 DDL 在排队，而它后面所有访问该表的事务都会被一起堵住——这是 MySQL 最典型的"一个 ALTER 搞挂整个库"。查 blocking_pids 找出持锁的长事务或未提交事务，先处理它们，DDL 才能继续。

**注意（误报条件与局限）**：只报"同一对象上既有 PENDING 锁又有 GRANTED 锁"的情况，即真正的争用，不报瞬间过路的排队；OBJECT_TYPE 为 GLOBAL 的锁会在 FLUSH TABLES 时瞬时出现，已排除。performance_schema.metadata_locks 自 5.7.3 起就存在（不是 8.0 专属），本规则用的 OBJECT_TYPE/OBJECT_SCHEMA/OBJECT_NAME/LOCK_STATUS/OWNER_THREAD_ID 五个列 5.7 也都有，因此 5.7/8.0/8.4 通用。注意 P_S 的 metadata_locks 表需要 metadata_locks 这个 instrument 被打开（默认开），关掉它本规则会静默返回 0 行。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN COUNT(DISTINCT w.waiting_pid) >= 5 THEN 'critical' ELSE 'warn' END AS severity,
  w.object_type       AS object_type,
  w.object_schema     AS object_schema,
  w.object_name       AS object_name,
  COUNT(DISTINCT w.waiting_pid)  AS waiting_threads,
  GROUP_CONCAT(DISTINCT w.waiting_pid ORDER BY w.waiting_pid)   AS waiting_pids,
  GROUP_CONCAT(DISTINCT w.blocking_pid ORDER BY w.blocking_pid) AS blocking_pids,
  MAX(w.waiting_sql)  AS sample_waiting_sql,
  MAX(w.blocking_sql) AS sample_blocking_sql
FROM (
  SELECT
    p.OBJECT_TYPE                  AS object_type,
    p.OBJECT_SCHEMA                AS object_schema,
    p.OBJECT_NAME                  AS object_name,
    pt.PROCESSLIST_ID              AS waiting_pid,
    LEFT(pt.PROCESSLIST_INFO, 160) AS waiting_sql,
    gt.PROCESSLIST_ID              AS blocking_pid,
    LEFT(gt.PROCESSLIST_INFO, 160) AS blocking_sql
  FROM performance_schema.metadata_locks p
  JOIN performance_schema.threads pt
    ON pt.THREAD_ID = p.OWNER_THREAD_ID
  JOIN performance_schema.metadata_locks g
    ON  g.OBJECT_TYPE = p.OBJECT_TYPE
    AND g.OBJECT_SCHEMA <=> p.OBJECT_SCHEMA
    AND g.OBJECT_NAME <=> p.OBJECT_NAME
    AND g.LOCK_STATUS = 'GRANTED'
  LEFT JOIN performance_schema.threads gt
    ON gt.THREAD_ID = g.OWNER_THREAD_ID
  WHERE p.LOCK_STATUS = 'PENDING'
    AND p.OBJECT_TYPE IN ('TABLE', 'SCHEMA')
    AND (pt.PROCESSLIST_USER IS NULL
         OR pt.PROCESSLIST_USER <> SUBSTRING_INDEX(CURRENT_USER(), '@', 1))
) w
GROUP BY w.object_type, w.object_schema, w.object_name
ORDER BY COUNT(DISTINCT w.waiting_pid) DESC
```

</details>

## non_innodb_table

**存在非 InnoDB 引擎的业务表**

- 严重度 `warn` · 维度 `risk` · 作用域 `schema` · 对象 `table`
- 精确度 `catalog` · 起始版本 `5.7`
- 依赖能力位：`schema_select`
- 参考：-

**处置**：转成 InnoDB：ALTER TABLE ... ENGINE=InnoDB。MyISAM 没有事务、没有崩溃恢复、只有表级锁，且不支持在线备份——大表上的表锁会直接变成业务故障。

**注意（误报条件与局限）**：系统库（mysql/sys 等）里的 MyISAM 表是 MySQL 自身的实现细节，已排除。老版本升级上来的库常见历史遗留 MyISAM 表，逐个评估迁移成本即可，不必一次性全转。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN t.bytes >= 1073741824 THEN 'critical' ELSE 'warn' END AS severity,
  t.TABLE_SCHEMA AS table_schema,
  t.TABLE_NAME   AS table_name,
  t.ENGINE       AS engine,
  t.TABLE_ROWS   AS estimated_rows,
  ROUND(t.bytes / 1024 / 1024, 1) AS size_mb
FROM (
  SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE, TABLE_ROWS,
         (IFNULL(DATA_LENGTH, 0) + IFNULL(INDEX_LENGTH, 0)) AS bytes
  FROM information_schema.TABLES
  WHERE TABLE_TYPE = 'BASE TABLE'
    AND ENGINE IS NOT NULL
    AND ENGINE <> 'InnoDB'
    AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
) t
ORDER BY t.bytes DESC
```

</details>

## replica_writable

**从库可写（read_only 关闭）**

- 严重度 `warn` · 维度 `risk` · 作用域 `cluster` · 对象 `replication`
- 精确度 `catalog` · 起始版本 `5.7`
- 依赖能力位：`p_s`, `replication`
- 参考：-
- 标签：replication, safety

**处置**：存在复制通道且 read_only=OFF，意味着业务代码可以把写请求打到从库上，产生主从不一致，且这些写入会与 SQL 线程的写入冲突。正确做法是开启 read_only=ON 或 super_read_only=ON（后者连 SUPER 账号也拦住，能防住"用管理员账号误写"）。

**注意（误报条件与局限）**：该规则只在"已经存在复制通道"时才触发，因此不适用于承担写流量的主库。有些架构刻意让从库可写（例如多主、双写、或把从库当只读业务库但接受不一致），这类情况下应把本规则加入 skip 列表而不是调参。读取 P_S 复制表需要 REPLICATION CLIENT 权限，缺权限时本规则会被跳过而不是误报干净。

<details><summary>SQL</summary>

```sql
SELECT
  'warn'            AS severity,
  @@read_only       AS read_only,
  @@super_read_only AS super_read_only,
  (SELECT GROUP_CONCAT(DISTINCT s.CHANNEL_NAME)
     FROM performance_schema.replication_applier_status s) AS channels,
  (SELECT COUNT(*)
     FROM performance_schema.replication_applier_status)   AS channel_count
FROM DUAL
WHERE @@read_only = 0
  AND EXISTS (SELECT 1 FROM performance_schema.replication_applier_status)
```

</details>

## sync_binlog_not_1

**binlog 未每次提交同步（sync_binlog 非 1）**

- 严重度 `warn` · 维度 `risk` · 作用域 `instance` · 对象 `setting:sync_binlog`
- 精确度 `exact` · 起始版本 `5.7`
- 依赖能力位：无
- 参考：-
- 标签：durability, replication

**处置**：设回 1（每次提交 fsync binlog）。非 1 的取值在主机断电时会丢失已提交但未落盘的事务——对主库意味着数据丢失，对从库意味着接到的 binlog 比预期少，而在 MGR 或半同步复制下还可能造成成员间数据分歧。

**注意（误报条件与局限）**：该参数只在 log_bin=ON 时有意义，因此本规则内联判断了 log_bin。大批量导入时临时设成 0 是常见提速手段，但必须记得改回来——本规则会一直报到你改回来为止，这正是它存在的价值。MySQL 8.0 默认即为 1。用 @@变量 直读，避免依赖 8.4 已移除的 information_schema.GLOBAL_VARIABLES。

<details><summary>SQL</summary>

```sql
SELECT
  'warn'            AS severity,
  'sync_binlog'     AS variable_name,
  @@sync_binlog     AS current_value,
  '1'               AS suggested_value,
  @@log_bin         AS log_bin
FROM DUAL
WHERE @@sync_binlog <> 1
  AND @@log_bin <> 0
```

</details>

## table_without_primary_key

**InnoDB 表没有主键（也没有等效的唯一非空索引）**

- 严重度 `warn` · 维度 `risk` · 作用域 `schema` · 对象 `table`
- 精确度 `catalog` · 起始版本 `5.7`
- 依赖能力位：`schema_select`
- 参考：-

**处置**：补一个自增或业务主键。无主键的 InnoDB 表会隐式生成 6 字节 rowid，且该 rowid 全局共享同一个计数器——高并发插入时这个计数器会成为热点，同时影响复制性能与表空间回收。

**注意（误报条件与局限）**：已排除"存在唯一且所有列都非空"的索引——那种表实际上有聚簇索引，不影响性能。这是 MySQL 特有的坑，PostgreSQL 没有等价问题。信息来自 information_schema，若监控账号无 schema 读权限则看不到任何行（会误报为"干净"，见 probe 的 schema_visibility 能力位）。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN t.bytes >= 1073741824 THEN 'warn' ELSE 'info' END AS severity,
  t.TABLE_SCHEMA   AS table_schema,
  t.TABLE_NAME     AS table_name,
  t.TABLE_ROWS     AS estimated_rows,
  ROUND(t.bytes / 1024 / 1024, 1) AS size_mb
FROM (
  SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_ROWS,
         (IFNULL(DATA_LENGTH, 0) + IFNULL(INDEX_LENGTH, 0)) AS bytes
  FROM information_schema.TABLES
  WHERE TABLE_TYPE = 'BASE TABLE'
    AND ENGINE = 'InnoDB'
    AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
) t
WHERE t.bytes >= 1048576
  AND NOT EXISTS (
    SELECT 1 FROM information_schema.TABLE_CONSTRAINTS c
     WHERE c.TABLE_SCHEMA = t.TABLE_SCHEMA
       AND c.TABLE_NAME   = t.TABLE_NAME
       AND c.CONSTRAINT_TYPE = 'PRIMARY KEY')
  AND NOT EXISTS (
    SELECT 1 FROM information_schema.STATISTICS s
     WHERE s.TABLE_SCHEMA = t.TABLE_SCHEMA
       AND s.TABLE_NAME   = t.TABLE_NAME
       AND s.NON_UNIQUE   = 0
       AND NOT EXISTS (
         SELECT 1 FROM information_schema.COLUMNS col
          WHERE col.TABLE_SCHEMA = s.TABLE_SCHEMA
            AND col.TABLE_NAME   = s.TABLE_NAME
            AND col.COLUMN_NAME  = s.COLUMN_NAME
            AND col.IS_NULLABLE  = 'YES'))
ORDER BY t.bytes DESC
```

</details>

## trx_commit_not_durable

**提交不落盘（innodb_flush_log_at_trx_commit 非 1）**

- 严重度 `warn` · 维度 `risk` · 作用域 `instance` · 对象 `setting:innodb_flush_log_at_trx_commit`
- 精确度 `exact` · 起始版本 `5.7`
- 依赖能力位：无
- 参考：-
- 标签：durability, safety

**处置**：值 1 表示每次提交都写 redo 并 fsync，是唯一能保证"提交即持久"的设置。值 2 只写到 OS 缓存，MySQL 进程崩溃不丢数据但操作系统/断电会丢；值 0 连 OS 缓存都不保证，任何崩溃都可能丢最近 1 秒的已提交事务，而且**返回给客户端的 commit 成功是假的**。金融/交易类库必须设为 1；只为压测提速而设 0/2 的实例，请确认它不被当作可靠存储使用。

**注意（误报条件与局限）**：这是明确的取舍而非缺陷：大批量导入、离线分析库、可重建的数据仓库常常刻意用 0/2 换取写入吞吐。判定前先确认这台实例承载的业务是否允许丢数据——本规则不做这个判断，只把事实摆出来。顺序上有依赖：若 sync_binlog 也非 1，则复制环境下的数据丢失窗口会进一步放大。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN @@innodb_flush_log_at_trx_commit = 0 THEN 'critical' ELSE 'warn' END AS severity,
  'innodb_flush_log_at_trx_commit'                           AS variable_name,
  @@innodb_flush_log_at_trx_commit                           AS current_value,
  '1'                                                        AS suggested_value,
  CASE @@innodb_flush_log_at_trx_commit
    WHEN 0 THEN '每秒才写 redo 日志：进程崩溃即可能丢失最近约 1 秒的已提交事务'
    WHEN 2 THEN '每次提交写 OS 缓存、每秒 fsync：操作系统崩溃或断电可能丢失最近约 1 秒的已提交事务'
    ELSE '未知取值'
  END                                                        AS risk_description
FROM DUAL
WHERE @@innodb_flush_log_at_trx_commit <> 1
```

</details>

## undo_history_list_long

**InnoDB 历史链表过长（purge 落后）**

- 严重度 `warn` · 维度 `risk` · 作用域 `workload` · 对象 `none`
- 精确度 `sampled` · 起始版本 `5.7`
- 依赖能力位：`process`
- 参考：pgbot/vacuum_horizon_blocked

**处置**：purge 被长时间存活的事务卡住是首要原因——先看 long_running_transaction / idle_in_transaction 两条规则是否同时命中。其次是写放大过高（批量 DELETE/UPDATE 产生的 undo 来不及清理），考虑拆批。

**注意（误报条件与局限）**：阈值 10 万 / 100 万是经验值，写放大很高的库常态偏高；要结合写入速率一起看，单看绝对值容易误判。指标需 INNODB_METRICS 已启用（trx_rseg_history_len 默认启用）。5.7 上该表同样存在。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN m.COUNT >= 1000000 THEN 'critical' ELSE 'warn' END AS severity,
  m.COUNT   AS history_list_length,
  m.COMMENT AS metric_comment
FROM information_schema.INNODB_METRICS m
WHERE m.NAME = 'trx_rseg_history_len'
  AND m.COUNT >= 100000
```

</details>

## open_tables_pressure

**当前打开的表数量逼近 table_open_cache 上限**

- 严重度 `info` · 维度 `capacity` · 作用域 `instance` · 对象 `setting:table_open_cache`
- 精确度 `scraped` · 起始版本 `5.7`
- 依赖能力位：`p_s`
- 参考：-
- 标签：tuning, capacity

**处置**：Open_tables 贴近 table_open_cache 时，表会被反复关闭再打开，表现为元数据锁竞争加剧与 CPU 空转（对应 table_open_cache_miss 规则里的 misses）。把 table_open_cache 提到明显高于常态 Open_tables 的值即可。注意内存代价：每个表缓存项占用约几百字节到 1KB，另需相应打开的文件描述符（受 open_files_limit 约束）。

**注意（误报条件与局限）**：Open_tables 是瞬时值（读 SHOW GLOBAL STATUS 的那一刻），业务高低峰差异大的实例可能只在峰值命中——这恰恰是想要的信号。它与 table_open_cache_miss 是同一问题的两种视角：这里看"水位"，那里看"已经发生的未命中"，两者一起看更准。调整 table_open_cache 会影响所有连接，属于全局参数，需要评估内存与文件句柄上限。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN r.pct >= 100 THEN 'warn' ELSE 'info' END AS severity,
  r.open_tables       AS open_tables,
  r.cache_size        AS table_open_cache,
  ROUND(r.pct, 1)     AS used_pct,
  r.overflows         AS cache_overflows,
  r.uptime_s          AS uptime_s
FROM (
  SELECT
    s.open_tables,
    s.overflows,
    s.uptime_s,
    v.cache_size,
    100 * s.open_tables / NULLIF(v.cache_size, 0) AS pct
  FROM (
    SELECT
      MAX(CASE WHEN VARIABLE_NAME = 'Open_tables'                THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS open_tables,
      MAX(CASE WHEN VARIABLE_NAME = 'Table_open_cache_overflows'  THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS overflows,
      MAX(CASE WHEN VARIABLE_NAME = 'Uptime'                      THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS uptime_s
    FROM performance_schema.global_status
  ) s
  CROSS JOIN (
    SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS cache_size
    FROM performance_schema.global_variables
    WHERE VARIABLE_NAME = 'table_open_cache'
  ) v
) r
WHERE r.cache_size > 0
  AND r.pct >= 85
```

</details>

## oversized_table

**单表体积过大（归档/分区候选）**

- 严重度 `info` · 维度 `capacity` · 作用域 `schema` · 对象 `table`
- 精确度 `catalog` · 起始版本 `5.7`
- 依赖能力位：`schema_select`
- 参考：-
- 标签：capacity, schema

**处置**：单表超过 50GB 后，DDL、备份、误删恢复的代价都会陡增。先确认它是否按时间增长：如果是流水/日志类表，按时间分区或定期归档到历史库是最有效的办法。若必须保留在线，至少把索引瘦身（见 redundant_index / unused_index），并确认 innodb_file_per_table=ON 便于单独回收空间。

**注意（误报条件与局限）**：这是阈值型信号，不是缺陷——有些业务表本来就应该很大（订单主表、用户表），这类情况应把规则加入 skip 列表，而不是去拆表。表大小读的是 information_schema 的统计值，InnoDB 的 DATA_LENGTH 是页数估算，存在偏差；本工具已把 information_schema_stats_expiry 设为 0 以保证新鲜度。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN t.bytes >= 53687091200 THEN 'warn' ELSE 'info' END AS severity,
  t.TABLE_SCHEMA AS table_schema,
  t.TABLE_NAME   AS table_name,
  t.ENGINE       AS engine,
  t.TABLE_ROWS   AS estimated_rows,
  ROUND(t.data_bytes / 1024 / 1024 / 1024, 2)  AS data_gb,
  ROUND(t.index_bytes / 1024 / 1024 / 1024, 2) AS index_gb,
  ROUND(t.bytes / 1024 / 1024 / 1024, 2)       AS total_gb,
  ROUND(100 * t.index_bytes / NULLIF(t.bytes, 0), 1) AS index_pct,
  ROUND(t.bytes / NULLIF(t.TABLE_ROWS, 0), 0)  AS avg_row_bytes
FROM (
  SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE, TABLE_ROWS,
         IFNULL(DATA_LENGTH, 0)  AS data_bytes,
         IFNULL(INDEX_LENGTH, 0) AS index_bytes,
         IFNULL(DATA_LENGTH, 0) + IFNULL(INDEX_LENGTH, 0) AS bytes
  FROM information_schema.TABLES
  WHERE TABLE_TYPE = 'BASE TABLE'
    AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
) t
WHERE t.bytes >= 10737418240
ORDER BY t.bytes DESC
LIMIT 50
```

</details>

## long_query_time_high

**慢查询阈值过高（会漏掉大部分值得看的语句）**

- 严重度 `info` · 维度 `hygiene` · 作用域 `instance` · 对象 `setting:long_query_time`
- 精确度 `exact` · 起始版本 `5.7`
- 依赖能力位：无
- 参考：-
- 标签：observability, sql

**处置**：把 long_query_time 降到 1 秒甚至 0.5 秒。默认 10 秒意味着"低于 10 秒的语句一律不记录"，而 OLTP 场景里真正的问题往往是几千条 0.5~2 秒的语句累积成的。配合 pt-query-digest 或 mysqldumpslow 做聚合，不要直接读原始慢日志。

**注意（误报条件与局限）**：读的是 @@GLOBAL 而不是会话值——业务连接池常常自行 SET SESSION long_query_time，会话值不能代表实例配置。阈值调低会显著增加日志量，请同时规划日志轮转（logrotate），否则慢日志本身会成为磁盘隐患。分析型/报表型实例用 10 秒甚至更长是合理的，这类实例请把本规则加入 skip。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN @@GLOBAL.long_query_time >= 5 THEN 'warn' ELSE 'info' END AS severity,
  'long_query_time'            AS variable_name,
  @@GLOBAL.long_query_time     AS current_seconds,
  '1'                          AS suggested_seconds,
  @@GLOBAL.slow_query_log      AS slow_query_log
FROM DUAL
WHERE @@GLOBAL.long_query_time >= 2
```

</details>

## redundant_index

**冗余索引（存在可覆盖它的其它索引）**

- 严重度 `info` · 维度 `hygiene` · 作用域 `schema` · 对象 `index`
- 精确度 `catalog` · 起始版本 `5.7`
- 依赖能力位：`schema_select`, `sys`
- 参考：pgbot/duplicate_indexes
- 标签：index, schema

**处置**：sys.schema_redundant_indexes 已经算出"被哪个索引完全覆盖"，按 dominant_index_name 保留、把 redundant_index_name 删掉即可。删除后写入会变快（少一次索引维护）、占用空间会下降。大表 DROP INDEX 是 online DDL，但仍需短暂 MDL，放到低峰期执行。

**注意（误报条件与局限）**：冗余不等于可以无脑删：如果冗余索引是某个外键唯一可用的索引，DROP 会被 InnoDB 拒绝（error 1553）；如果它是唯一索引而 dominant 是普通索引，删掉会丢唯一约束——本规则已排除"冗余索引是唯一索引"的情况。另一个常见误判来源是只服务于特定查询的短前缀索引，删之前先确认没有语句依赖它的排序。

**⚠️ 含可执行语句**：`DROP INDEX` — 证据列 suggested_drop 是 sys 自动生成的可执行 DROP INDEX 语句。执行前请确认该索引不是外键依赖项，并在低峰期操作。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN t.bytes >= 1073741824 THEN 'warn' ELSE 'info' END AS severity,
  r.table_schema            AS table_schema,
  r.table_name              AS table_name,
  r.redundant_index_name    AS redundant_index,
  r.redundant_index_columns AS redundant_columns,
  r.dominant_index_name     AS dominant_index,
  r.dominant_index_columns  AS dominant_columns,
  ROUND(t.bytes / 1024 / 1024, 1) AS table_size_mb,
  r.sql_drop_index          AS suggested_drop
FROM sys.schema_redundant_indexes r
JOIN (
  SELECT TABLE_SCHEMA, TABLE_NAME,
         IFNULL(DATA_LENGTH, 0) + IFNULL(INDEX_LENGTH, 0) AS bytes
  FROM information_schema.TABLES
  WHERE TABLE_TYPE = 'BASE TABLE'
) t ON t.TABLE_SCHEMA = r.table_schema AND t.TABLE_NAME = r.table_name
WHERE r.redundant_index_non_unique = 1
  AND r.dominant_index_non_unique = 1
ORDER BY t.bytes DESC
LIMIT 50
```

</details>

## sql_require_primary_key_off

**未强制新表必须有主键（sql_require_primary_key=OFF）**

- 严重度 `info` · 维度 `hygiene` · 作用域 `instance` · 对象 `setting:sql_require_primary_key`
- 精确度 `exact` · 起始版本 `8.0.13`
- 依赖能力位：无
- 参考：-
- 标签：schema, safety

**处置**：打开 sql_require_primary_key=ON（可动态设置），让"创建无主键表"这一动作直接失败。MySQL 8.0.13 引入该参数，是防止无主键表继续产生的最省事手段。注意：开启后，对已存在的无主键表做 ADD COLUMN 等需要重建表的 DDL 也会被拒绝，需要先补主键。

**注意（误报条件与局限）**：在 MySQL 8.0.13 之前以及 MariaDB 上不存在该变量——版本门禁已用 @since 声明，避免在那些版本上因"未知系统变量"而失败。仅有存量无主键表的实例请配合 table_without_primary_key 规则一起看：那条查存量，这条防增量。

<details><summary>SQL</summary>

```sql
SELECT
  'info'                    AS severity,
  'sql_require_primary_key' AS variable_name,
  @@sql_require_primary_key AS current_value,
  'ON'                      AS suggested_value
FROM DUAL
WHERE @@sql_require_primary_key = 0
```

</details>

## unused_index

**长期未被任何语句使用的索引**

- 严重度 `info` · 维度 `hygiene` · 作用域 `schema` · 对象 `index`
- 精确度 `sampled` · 起始版本 `5.7`
- 依赖能力位：`p_s_waits`, `schema_select`, `sys_indexes` · 需要运行满 259200s
- 参考：pgbot/unused_indexes
- 标签：index, schema

**处置**：候选删除对象来自 sys.schema_unused_indexes，它统计的是 performance_schema 的索引 IO 计数——只要实例运行期间该索引没被读过就进榜。删掉可以省空间、减小写入放大。删之前用业务高峰 + 月末/季末这类周期性查询覆盖一遍，避免删掉低频但关键的索引。

**注意（误报条件与局限）**：这类结论天然不可靠，三点必须知道：①计数器随实例重启清零，所以已用 Uptime >= 3 天做门禁，运行时间不足时本规则不产出任何行（那是"看不到"，不是"没有"）；②唯一索引被排除，删掉它们会丢约束；③服务于外键的索引删不掉（InnoDB 会拒绝）。周期性报表类查询如果本次统计窗口内没跑过，其索引会被误判为无用。

**⚠️ 含可执行语句**：`DROP INDEX` — 证据列 suggested_drop 是可执行的 DROP INDEX 语句。执行前请确认该索引不被低频查询与外键依赖。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN t.bytes >= 1073741824 THEN 'warn' ELSE 'info' END AS severity,
  u.object_schema AS table_schema,
  u.object_name   AS table_name,
  u.index_name    AS unused_index,
  s.columns       AS index_columns,
  t.rows_est      AS estimated_rows,
  ROUND(t.bytes / 1024 / 1024, 1) AS table_size_mb,
  up.uptime_s     AS uptime_s,
  CONCAT('ALTER TABLE `', u.object_schema, '`.`', u.object_name,
         '` DROP INDEX `', u.index_name, '`') AS suggested_drop
FROM sys.schema_unused_indexes u
JOIN (
  SELECT TABLE_SCHEMA, TABLE_NAME, MAX(TABLE_ROWS) AS rows_est,
         IFNULL(MAX(DATA_LENGTH), 0) + IFNULL(MAX(INDEX_LENGTH), 0) AS bytes
  FROM information_schema.TABLES
  WHERE TABLE_TYPE = 'BASE TABLE' AND ENGINE = 'InnoDB'
  GROUP BY TABLE_SCHEMA, TABLE_NAME
) t ON t.TABLE_SCHEMA = u.object_schema AND t.TABLE_NAME = u.object_name
JOIN (
  SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME,
         GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS columns,
         MIN(NON_UNIQUE) AS non_unique
  FROM information_schema.STATISTICS
  GROUP BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME
) s ON s.TABLE_SCHEMA = u.object_schema AND s.TABLE_NAME = u.object_name AND s.INDEX_NAME = u.index_name
CROSS JOIN (
  SELECT CAST(MAX(CASE WHEN VARIABLE_NAME = 'Uptime' THEN VARIABLE_VALUE END) AS DECIMAL(30,0)) AS uptime_s
  FROM performance_schema.global_status
) up
WHERE s.non_unique = 1
  AND t.bytes >= 10485760
ORDER BY t.bytes DESC
LIMIT 50
```

</details>

## binlog_cache_disk_spill

**事务 binlog 缓存溢出到磁盘**

- 严重度 `info` · 维度 `latency` · 作用域 `workload` · 对象 `setting:binlog_cache_size`
- 精确度 `cumulative` · 起始版本 `5.7`
- 依赖能力位：`p_s`
- 参考：-
- 标签：binlog, transaction

**处置**：说明有事务的 binlog 事件超过 binlog_cache_size，溢出部分被写到临时文件。大事务（批量 INSERT/UPDATE、大字段更新）是主因。先判断是否值得调大 binlog_cache_size（它是"每连接"的，调大要乘以并发连接数算内存），更根本的做法是拆分大事务。5.7+ 已默认启用 binlog_group_commit_sync_delay 等机制，单纯调 cache 收益有限。

**注意（误报条件与局限）**：仅当 log_bin=ON 时才有意义——log_bin 关闭时这两个计数器恒为 0，规则会返回 0 行（假干净）。已用 Binlog_cache_use >= 1000 做门禁。MySQL 8.0 的 binlog 事务压缩（binlog_transaction_compression=ON）会改变缓存占用特征。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN r.spill_rate >= 0.20 THEN 'warn' ELSE 'info' END AS severity,
  ROUND(100 * r.spill_rate, 2) AS disk_use_pct,
  r.disk_use                   AS binlog_cache_disk_use,
  r.cache_use                  AS binlog_cache_use,
  r.log_bin                    AS log_bin
FROM (
  SELECT
    s.disk_use,
    s.cache_use,
    s.disk_use / NULLIF(s.cache_use, 0) AS spill_rate,
    v.log_bin
  FROM (
    SELECT
      MAX(CASE WHEN VARIABLE_NAME = 'Binlog_cache_disk_use' THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS disk_use,
      MAX(CASE WHEN VARIABLE_NAME = 'Binlog_cache_use'      THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS cache_use
    FROM performance_schema.global_status
  ) s
  CROSS JOIN (
    SELECT VARIABLE_VALUE AS log_bin
    FROM performance_schema.global_variables
    WHERE VARIABLE_NAME = 'log_bin'
  ) v
) r
WHERE UPPER(COALESCE(r.log_bin, 'OFF')) IN ('ON', '1')
  AND r.cache_use >= 1000
  AND r.spill_rate >= 0.01
```

</details>

## full_table_scan_heavy

**存在大量不走索引的语句（全表扫描放大）**

- 严重度 `info` · 维度 `latency` · 作用域 `workload` · 对象 `statement`
- 精确度 `cumulative` · 起始版本 `5.7`
- 依赖能力位：`p_s_statements`
- 参考：pgbot/seq_scan_heavy
- 标签：index, sql

**处置**：按 digest 拿到样本 SQL 后，重点看两件事：WHERE 列有没有索引、以及索引是否因为隐式类型转换（列是 varchar 却比数字）而失效。扫描行数极大而返回行数极小，是最典型的"缺索引"信号。

**注意（误报条件与局限）**：直接读 events_statements_summary_by_digest 而不是 sys 视图，是为了拿到精确的数值列——sys 视图里的 *_latency 是格式化字符串，按它排序会得到错误的名次。digest 表在 P_S 启动后才有数据，刚重启的实例这里会是空的（此时报"干净"是假干净）。语句摘要受 performance_schema_digests_size 限制，超限语句会归到 digest='' 的汇总行，本规则已排除该行。样本列取 DIGEST_TEXT 而非 QUERY_SAMPLE_TEXT：后者是 8.0.22 才加的列，用它会让本规则在 5.7 上直接报 1054；DIGEST_TEXT 从 5.7 起一直存在，跨版本可用。代价是拿到的是参数已被 `?` 替换的规范化文本，看不到字面值——需要字面值时按 digest 去 P_S 或慢日志里捞。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN (100 * d.SUM_NO_INDEX_USED / NULLIF(d.COUNT_STAR, 0)) >= 90 THEN 'warn' ELSE 'info' END AS severity,
  d.SCHEMA_NAME                                   AS db,
  d.COUNT_STAR                                    AS exec_count,
  d.SUM_NO_INDEX_USED                              AS no_index_used,
  ROUND(100 * d.SUM_NO_INDEX_USED / NULLIF(d.COUNT_STAR, 0), 1) AS no_index_pct,
  ROUND(d.SUM_ROWS_EXAMINED / NULLIF(d.COUNT_STAR, 0), 0)       AS rows_examined_avg,
  ROUND(d.SUM_ROWS_SENT / NULLIF(d.COUNT_STAR, 0), 0)           AS rows_sent_avg,
  d.SUM_ROWS_EXAMINED                                          AS rows_examined_total,
  LEFT(d.DIGEST_TEXT, 160)                                      AS query_sample,
  d.DIGEST                                                     AS digest
FROM performance_schema.events_statements_summary_by_digest d
WHERE d.DIGEST_TEXT IS NOT NULL
  AND d.DIGEST <> ''
  AND d.SCHEMA_NAME IS NOT NULL
  AND d.SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  AND d.COUNT_STAR >= 10
  AND d.SUM_NO_INDEX_USED > 0
  AND d.SUM_ROWS_EXAMINED >= 100000
ORDER BY d.SUM_ROWS_EXAMINED DESC
LIMIT 10
```

</details>

## innodb_redo_undersized

**redo log 容量相对缓冲池偏小**

- 严重度 `info` · 维度 `latency` · 作用域 `instance` · 对象 `setting:innodb_redo_log_capacity`
- 精确度 `catalog` · 起始版本 `5.7`
- 依赖能力位：`p_s`
- 参考：-
- 标签：innodb, redo

**处置**：redo 空间不足会迫使后台频繁做 checkpoint 刷脏页，写入吞吐随之下滑。经验做法是让 redo 至少能容纳"一次 checkpoint 周期内的写入量"，粗算可按缓冲池的 25%~100% 设。MySQL 8.0.30+ 可直接 SET GLOBAL innodb_redo_log_capacity（在线生效）；更低版本要改 innodb_log_file_size × innodb_log_files_in_group 并重启。

**注意（误报条件与局限）**：这是个启发式阈值，不是硬错误：只读为主、缓冲池很大（比如几百 GB）的实例，redo 占缓冲池比例天然很低且完全正常——此时应把本规则加入 skip。判定还忽略了一个更直接的证据：若 innodb_log_waits 非零（见该规则），说明确实已经在等待，那才是需要立刻处理的。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN r.ratio < 0.10 THEN 'warn' ELSE 'info' END AS severity,
  r.redo_bytes        AS redo_bytes,
  r.bp_bytes          AS buffer_pool_bytes,
  ROUND(100 * r.ratio, 1) AS redo_pct_of_buffer_pool,
  ROUND(r.redo_bytes / 1024 / 1024, 0) AS redo_mb,
  ROUND(r.bp_bytes   / 1024 / 1024, 0) AS buffer_pool_mb,
  r.source            AS redo_source
FROM (
  SELECT
    COALESCE(p.redo_capacity, p.log_file_size * NULLIF(p.log_files, 0)) AS redo_bytes,
    bp.bp_bytes AS bp_bytes,
    CASE WHEN p.redo_capacity IS NOT NULL THEN 'innodb_redo_log_capacity' ELSE 'innodb_log_file_size x innodb_log_files_in_group' END AS source,
    COALESCE(p.redo_capacity, p.log_file_size * NULLIF(p.log_files, 0)) / NULLIF(bp.bp_bytes, 0) AS ratio
  FROM (
    SELECT
      CAST(MAX(CASE WHEN VARIABLE_NAME = 'innodb_redo_log_capacity'  THEN VARIABLE_VALUE END) AS DECIMAL(30,0)) AS redo_capacity,
      CAST(MAX(CASE WHEN VARIABLE_NAME = 'innodb_log_file_size'      THEN VARIABLE_VALUE END) AS DECIMAL(30,0)) AS log_file_size,
      CAST(MAX(CASE WHEN VARIABLE_NAME = 'innodb_log_files_in_group' THEN VARIABLE_VALUE END) AS DECIMAL(30,0)) AS log_files
    FROM performance_schema.global_variables
  ) p
  CROSS JOIN (
    SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS bp_bytes
    FROM performance_schema.global_variables
    WHERE VARIABLE_NAME = 'innodb_buffer_pool_size'
  ) bp
) r
WHERE r.bp_bytes > 0
  AND r.redo_bytes IS NOT NULL
  AND r.ratio < 0.25
```

</details>

## innodb_row_lock_contention

**行锁等待占用时间偏高**

- 严重度 `info` · 维度 `latency` · 作用域 `history` · 对象 `none`
- 精确度 `cumulative` · 起始版本 `5.7`
- 依赖能力位：`p_s`
- 参考：pgbot/wait_lock_contention

**处置**：这是累计视角的趋势信号，用来判断"锁竞争是不是一个长期问题"。定位到具体争用请用 blocking_chains（瞬时视角）。长期偏高通常意味着热点行的更新并发过高（例如计数器表、状态字段），考虑改批量或换无锁方案。

**注意（误报条件与局限）**：两个计数器自实例启动累计，重启会清零，因此重启后一段时间内不报（已用 ratio 门禁而非绝对量）。avg_wait_ms 会被少量超长等待拉高，不代表典型等待时长。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN raw.lock_time_ratio >= 0.05 THEN 'warn' ELSE 'info' END AS severity,
  raw.waits                                                    AS row_lock_waits,
  ROUND(raw.avg_wait_ms, 2)                                    AS avg_wait_ms,
  ROUND(raw.total_wait_s, 1)                                   AS total_wait_s,
  ROUND(100 * raw.lock_time_ratio, 3)                          AS pct_of_uptime_in_lock_wait,
  raw.uptime_s                                                 AS uptime_s
FROM (
  SELECT
    w.v                                  AS waits,
    (t.v / NULLIF(w.v, 0))               AS avg_wait_ms,
    (t.v / 1000)                         AS total_wait_s,
    (t.v / NULLIF(u.v * 1000, 0))        AS lock_time_ratio,
    u.v                                  AS uptime_s
  FROM
    (SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS v
       FROM performance_schema.global_status
      WHERE VARIABLE_NAME = 'Innodb_row_lock_waits') w
  CROSS JOIN
    (SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS v
       FROM performance_schema.global_status
      WHERE VARIABLE_NAME = 'Innodb_row_lock_time') t
  CROSS JOIN
    (SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS v
       FROM performance_schema.global_status
      WHERE VARIABLE_NAME = 'Uptime') u
) raw
WHERE raw.waits > 100
  AND raw.lock_time_ratio >= 0.01
```

</details>

## sort_merge_passes

**排序合并次数偏高（sort_buffer 偏小）**

- 严重度 `info` · 维度 `latency` · 作用域 `workload` · 对象 `setting:sort_buffer_size`
- 精确度 `cumulative` · 起始版本 `5.7`
- 依赖能力位：`p_s` · 需要运行满 3600s
- 参考：-

**处置**：先定位产生大排序的查询。sort_buffer_size 是每连接分配，调大要按并发连接数核算内存；通常优化掉大排序比调大参数更有效。

**注意（误报条件与局限）**：这是启发式阈值，不是硬性错误——只要排序在业务可接受延迟内，合并几次无害。排序合并次数多但量小（每小时 < 100）不报。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN raw.per_hour > 10000 THEN 'warn' ELSE 'info' END AS severity,
  raw.merge_passes                                          AS sort_merge_passes,
  ROUND(raw.per_hour, 1)                                    AS merge_passes_per_hour,
  raw.uptime_s                                              AS uptime_s
FROM (
  SELECT
    (a.v / NULLIF(c.v / 3600, 0)) AS per_hour,
    a.v                           AS merge_passes,
    c.v                           AS uptime_s
  FROM
    (SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS v
       FROM performance_schema.global_status
      WHERE VARIABLE_NAME = 'Sort_merge_passes') a
  CROSS JOIN
    (SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS v
       FROM performance_schema.global_status
      WHERE VARIABLE_NAME = 'Uptime') c
) raw
WHERE raw.merge_passes > 1000
  AND raw.per_hour > 100
```

</details>

## stale_index_statistics

**索引统计信息失真（基数为 1 但表很大）**

- 严重度 `info` · 维度 `latency` · 作用域 `schema` · 对象 `index`
- 精确度 `catalog` · 起始版本 `5.7`
- 依赖能力位：`schema_select`
- 参考：-
- 标签：statistics, optimizer

**处置**：基数为 1 意味着优化器认为该索引所有值都相同，会直接放弃它转而全表扫描。执行 ANALYZE TABLE 重新采样。若 ANALYZE 后基数仍然很低，说明数据分布确实倾斜，或该列被函数包住（例如存的是 JSON 片段），此时应考虑改用生成列 + 索引。

**注意（误报条件与局限）**：读的是 information_schema.STATISTICS.CARDINALITY，它本身来自缓存——MySQL 8.0 默认 information_schema_stats_expiry=86400 秒，本工具已在会话里把它设为 0 保证读到实时值；用别的客户端手工跑这条规则时请自己先设置。刚建的表、刚做完大批量导入的表出现低基数是暂时的，不要立刻下结论。CARDINALITY 为 NULL 表示统计信息从未生成过，本规则已把它排除，避免与"未统计"混淆。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN t.TABLE_ROWS >= 1000000 THEN 'warn' ELSE 'info' END AS severity,
  s.TABLE_SCHEMA AS table_schema,
  s.TABLE_NAME   AS table_name,
  s.INDEX_NAME   AS index_name,
  s.COLUMN_NAME  AS leading_column,
  s.CARDINALITY  AS cardinality,
  t.TABLE_ROWS   AS estimated_rows,
  CONCAT('ANALYZE TABLE `', s.TABLE_SCHEMA, '`.`', s.TABLE_NAME, '`') AS suggested_fix
FROM information_schema.STATISTICS s
JOIN information_schema.TABLES t
  ON t.TABLE_SCHEMA = s.TABLE_SCHEMA
 AND t.TABLE_NAME   = s.TABLE_NAME
 AND t.TABLE_TYPE   = 'BASE TABLE'
WHERE s.SEQ_IN_INDEX = 1
  AND s.CARDINALITY IS NOT NULL
  AND s.CARDINALITY <= 1
  AND s.INDEX_NAME <> 'PRIMARY'
  AND t.TABLE_ROWS >= 10000
  AND t.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
ORDER BY t.TABLE_ROWS DESC
LIMIT 50
```

</details>

## statement_high_total_latency

**累计耗时最高的语句（按 digest 排序）**

- 严重度 `info` · 维度 `latency` · 作用域 `workload` · 对象 `statement`
- 精确度 `cumulative` · 起始版本 `5.7`
- 依赖能力位：`p_s_statements`
- 参考：pgbot/slow_queries
- 标签：sql, top-n

**处置**：这是"总时间"榜而不是"单次"榜：一条 5ms 的语句跑 100 万次，比一条 3s 的语句跑 10 次更值得先优化。先确认它是否高频且可以缓存/合并，再看执行计划能否降低单次成本。

**注意（误报条件与局限）**：SUM_TIMER_WAIT 单位是皮秒。已过滤系统 schema 与 digest 为空的汇总行。P_S 只保留受 performance_schema_digests_size 限制的 top 语句，超出的会汇总到 digest='' 行——所以这里看到的是"P_S 认为的 top"，不是绝对 top。CPU 时间列需要 performance_schema 的 CPU 计时 consumer。样本列取 DIGEST_TEXT 而非 QUERY_SAMPLE_TEXT（后者是 8.0.22+ 才有，用它会让本规则在 5.7 上报 1054）。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN ROUND(d.AVG_TIMER_WAIT / 1e9, 2) >= 500 OR d.SUM_TIMER_WAIT >= 600e12
       THEN 'warn' ELSE 'info' END                       AS severity,
  d.SCHEMA_NAME                                          AS db,
  ROUND(d.SUM_TIMER_WAIT / 1e12, 2)                      AS total_seconds,
  ROUND(d.AVG_TIMER_WAIT / 1e9, 2)                       AS avg_ms,
  ROUND(d.MAX_TIMER_WAIT / 1e12, 3)                      AS max_seconds,
  d.COUNT_STAR                                           AS exec_count,
  d.SUM_ROWS_EXAMINED                                    AS rows_examined_total,
  d.SUM_CREATED_TMP_DISK_TABLES                          AS tmp_disk_tables,
  d.SUM_SORT_MERGE_PASSES                                AS sort_merge_passes,
  LEFT(d.DIGEST_TEXT, 160)                               AS query_sample,
  d.DIGEST                                               AS digest
FROM performance_schema.events_statements_summary_by_digest d
WHERE d.DIGEST_TEXT IS NOT NULL
  AND d.DIGEST <> ''
  AND d.SCHEMA_NAME IS NOT NULL
  AND d.SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  AND d.COUNT_STAR >= 100
  AND d.SUM_TIMER_WAIT >= 10e12
ORDER BY d.SUM_TIMER_WAIT DESC
LIMIT 10
```

</details>

## table_open_cache_miss

**表缓存未命中率偏高（反复打开表定义）**

- 严重度 `info` · 维度 `latency` · 作用域 `instance` · 对象 `setting:table_open_cache`
- 精确度 `cumulative` · 起始版本 `5.7`
- 依赖能力位：`p_s` · 需要运行满 3600s
- 参考：pgbot/low_cache_hit
- 标签：tuning, cache

**处置**：先看 table_open_cache 与 Open_tables 的差距：若 Open_tables 长期贴近 table_open_cache，把 table_open_cache 提高（单个连接句柄的表缓存上限由 table_open_cache 决定，句柄占用总量还受 table_open_cache_instances 影响）。若 misses 高但 Open_tables 远小于上限，说明工作集本身比缓存大，优先确认是否有大量一次性表（临时表、按月分表）在轮转。

**注意（误报条件与局限）**：累计计数器，实例重启后清零，故用运行时长门禁（@min_uptime: 1 小时）显式跳过而不是报干净；另有"命中+未命中 > 1 万次"门禁以排除低流量实例。此指标只反映"表定义是否需要重新打开"，不是磁盘 IO 指标——命中率低会带来元数据锁竞争，但不会直接体现为慢查询。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN r.miss_rate >= 0.25 THEN 'warn' ELSE 'info' END AS severity,
  ROUND(100 * r.miss_rate, 2) AS miss_pct,
  r.hits                     AS cache_hits,
  r.misses                   AS cache_misses,
  r.overflows                AS cache_overflows,
  r.uptime_s                 AS uptime_s
FROM (
  SELECT
    raw.hits,
    raw.misses,
    raw.overflows,
    raw.uptime_s,
    raw.misses / NULLIF(raw.hits + raw.misses, 0) AS miss_rate
  FROM (
    SELECT
      MAX(CASE WHEN VARIABLE_NAME = 'Table_open_cache_hits'      THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS hits,
      MAX(CASE WHEN VARIABLE_NAME = 'Table_open_cache_misses'    THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS misses,
      MAX(CASE WHEN VARIABLE_NAME = 'Table_open_cache_overflows' THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS overflows,
      MAX(CASE WHEN VARIABLE_NAME = 'Uptime'                     THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS uptime_s
    FROM performance_schema.global_status
  ) raw
) r
WHERE (r.hits + r.misses) > 10000
  AND r.miss_rate >= 0.05
```

</details>

## thread_cache_miss

**连接线程复用率低（频繁创建/销毁线程）**

- 严重度 `info` · 维度 `latency` · 作用域 `instance` · 对象 `setting:thread_cache_size`
- 精确度 `cumulative` · 起始版本 `5.7`
- 依赖能力位：`p_s` · 需要运行满 3600s
- 参考：pgbot/low_cache_hit
- 标签：tuning, connection

**处置**：把 thread_cache_size 调到能覆盖峰值并发连接（常见做法是没有专门理由就设成 max_connections 的 1/4 以上，或直接设成几百）。thread_cache_size=0 表示每来一个连接就创建新线程，短连接场景下这是明确的浪费。

**注意（误报条件与局限）**：用运行时长门禁（@min_uptime: 1 小时）与 Connections > 1000 双重门控，避免低流量/刚重启实例误报——不满足时本规则被显式跳过，不会误报干净。连接池架构下这个指标天然很低，不要为此调参。MariaDB 的线程池（thread_handling=pool-of-threads）下该指标无意义。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN r.miss_rate >= 0.30 THEN 'warn' ELSE 'info' END AS severity,
  ROUND(100 * r.miss_rate, 2) AS miss_pct,
  r.cache_size                AS thread_cache_size,
  r.created                   AS threads_created,
  r.conns                     AS connections,
  r.uptime_s                  AS uptime_s
FROM (
  SELECT
    s.created,
    s.conns,
    s.uptime_s,
    v.cache_size,
    s.created / NULLIF(s.conns, 0) AS miss_rate
  FROM (
    SELECT
      MAX(CASE WHEN VARIABLE_NAME = 'Threads_created' THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS created,
      MAX(CASE WHEN VARIABLE_NAME = 'Connections'     THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS conns,
      MAX(CASE WHEN VARIABLE_NAME = 'Uptime'          THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS uptime_s
    FROM performance_schema.global_status
  ) s
  CROSS JOIN (
    SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS cache_size
    FROM performance_schema.global_variables
    WHERE VARIABLE_NAME = 'thread_cache_size'
  ) v
) r
WHERE r.conns > 1000
  AND r.miss_rate >= 0.05
```

</details>

## auto_increment_exhaustion

**自增主键接近类型上限**

- 严重度 `info` · 维度 `risk` · 作用域 `schema` · 对象 `column`
- 精确度 `catalog` · 起始版本 `5.7`
- 依赖能力位：`schema_select`
- 参考：-
- 标签：schema, capacity

**处置**：用 int（上限约 21 亿）做自增主键、且写入速率高的表，跑满只是时间问题，而耗尽之后所有 INSERT 会直接失败（error 1062/1467），属于典型"凌晨炸"的故障。到 70% 就该动手：改成 BIGINT UNSIGNED 需要重建表（ALTER TABLE ... MODIFY，配合 pt-online-schema-change 或 gh-ost 减少锁表时间）。

**注意（误报条件与局限）**：已用"已用百分比超过类型上限的 50%"作为门槛，低于此不报，避免刷屏。判定依据是 information_schema.TABLES.AUTO_INCREMENT，它可能滞后于真实插入位置（缓存分配），因此百分比是估算。另外 AUTO_INCREMENT 会因为删除最大值、回滚、以及 InnoDB 8.0 之前的计数器不持久化而回退，不要在它上面做精确容量规划。用雪花 ID 当主键、或曾被人工改成极大值的表，AUTO_INCREMENT 会在 10^18 量级（bigint unsigned 的 ~11%），此时"百分比"没有实际意义，但它离上限确实还很远，不会命中；若这类表在你的库里很多，把本规则加入 skip。

<details><summary>SQL</summary>

```sql
SELECT
  CASE WHEN x.used_pct >= 90 THEN 'critical' ELSE 'warn' END AS severity,
  x.TABLE_SCHEMA    AS table_schema,
  x.TABLE_NAME      AS table_name,
  x.COLUMN_NAME     AS column_name,
  x.COLUMN_TYPE     AS column_type,
  x.AUTO_INCREMENT  AS current_auto_increment,
  x.max_val         AS type_max_value,
  ROUND(x.used_pct, 2) AS used_pct
FROM (
  SELECT
    m.TABLE_SCHEMA,
    m.TABLE_NAME,
    m.COLUMN_NAME,
    m.COLUMN_TYPE,
    m.AUTO_INCREMENT,
    m.max_val,
    CAST(m.AUTO_INCREMENT AS DECIMAL(30, 0)) * 100
      / NULLIF(CAST(m.max_val AS DECIMAL(30, 0)), 0) AS used_pct
  FROM (
    SELECT
      t.TABLE_SCHEMA,
      t.TABLE_NAME,
      c.COLUMN_NAME,
      c.COLUMN_TYPE,
      t.AUTO_INCREMENT,
      CASE
        WHEN c.DATA_TYPE = 'tinyint'   THEN IF(c.COLUMN_TYPE LIKE '%unsigned%', 255, 127)
        WHEN c.DATA_TYPE = 'smallint'  THEN IF(c.COLUMN_TYPE LIKE '%unsigned%', 65535, 32767)
        WHEN c.DATA_TYPE = 'mediumint' THEN IF(c.COLUMN_TYPE LIKE '%unsigned%', 16777215, 8388607)
        WHEN c.DATA_TYPE = 'int'       THEN IF(c.COLUMN_TYPE LIKE '%unsigned%', 4294967295, 2147483647)
        WHEN c.DATA_TYPE = 'bigint'    THEN IF(c.COLUMN_TYPE LIKE '%unsigned%', 18446744073709551615, 9223372036854775807)
      END AS max_val
    FROM information_schema.TABLES t
    JOIN information_schema.COLUMNS c
      ON c.TABLE_SCHEMA = t.TABLE_SCHEMA
     AND c.TABLE_NAME   = t.TABLE_NAME
     AND c.EXTRA LIKE '%auto_increment%'
    WHERE t.TABLE_TYPE = 'BASE TABLE'
      AND t.AUTO_INCREMENT IS NOT NULL
      AND t.AUTO_INCREMENT > 1
      AND t.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  ) m
) x
WHERE x.max_val IS NOT NULL
  AND x.used_pct >= 50
ORDER BY x.used_pct DESC
LIMIT 50
```

</details>
