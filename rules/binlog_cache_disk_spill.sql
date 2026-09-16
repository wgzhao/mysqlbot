-- @id: binlog_cache_disk_spill
-- @title: 事务 binlog 缓存溢出到磁盘
-- @severity: info
-- @dimension: latency
-- @scope: workload
-- @object: setting:binlog_cache_size
-- @requires: p_s
-- @exactness: cumulative
-- @since: 5.7
-- @tags: binlog,transaction
-- @remediation: 说明有事务的 binlog 事件超过 binlog_cache_size，溢出部分被写到临时文件。大事务（批量 INSERT/UPDATE、大字段更新）是主因。先判断是否值得调大 binlog_cache_size（它是"每连接"的，调大要乘以并发连接数算内存），更根本的做法是拆分大事务。5.7+ 已默认启用 binlog_group_commit_sync_delay 等机制，单纯调 cache 收益有限。
-- @caveats: 仅当 log_bin=ON 时才有意义——log_bin 关闭时这两个计数器恒为 0，规则会返回 0 行（假干净）。已用 Binlog_cache_use >= 1000 做门禁。MySQL 8.0 的 binlog 事务压缩（binlog_transaction_compression=ON）会改变缓存占用特征。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
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
