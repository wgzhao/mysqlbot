-- ============================================================================
--  自测夹具 3/3：把实例配置调成"有问题"的状态
--  ⚠️ 这些都是 GLOBAL 变更，只允许在一次性实例上执行
--  每条都对应一条期望命中的配置类规则。
-- ============================================================================

-- 期望命中：trx_commit_not_durable
SET GLOBAL innodb_flush_log_at_trx_commit = 2;

-- 期望命中：sync_binlog_not_1（需 log_bin=ON）
SET GLOBAL sync_binlog = 0;

-- 期望命中：slow_query_log_off
SET GLOBAL slow_query_log = OFF;

-- 期望命中：long_query_time_high
SET GLOBAL long_query_time = 10;

-- 期望命中：sql_require_primary_key_off
SET GLOBAL sql_require_primary_key = OFF;

-- 期望命中：stats_expiry_too_long
SET GLOBAL information_schema_stats_expiry = 86400;

-- 期望命中：innodb_file_per_table_off
SET GLOBAL innodb_file_per_table = OFF;

-- 期望命中：binlog_retention_unbounded
SET GLOBAL binlog_expire_logs_seconds = 0;

-- 让内部临时表容易落盘（配合风暴脚本，期望命中 tmp_table_disk_spill）
SET GLOBAL tmp_table_size     = 16384;
SET GLOBAL max_heap_table_size = 16384;

-- 让排序容易发生多路归并（配合风暴脚本，期望命中 sort_merge_passes）
SET GLOBAL sort_buffer_size   = 32768;

SELECT '实例配置已置为"有问题"状态' AS status;
