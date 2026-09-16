-- @id: innodb_log_waits
-- @title: 事务等待 redo log 空间（日志写入跟不上）
-- @severity: warn
-- @dimension: latency
-- @scope: instance
-- @object: setting:innodb_redo_log_capacity
-- @requires: p_s
-- @exactness: cumulative
-- @since: 5.7
-- @tags: innodb,redo
-- @remediation: 只要有非零值就说明曾经有事务因为 redo 空间不足而等待——这是写入延迟的直接来源。MySQL 8.0.30+ 改用 innodb_redo_log_capacity（默认 100MB，动态可调），调大它通常立竿见影；5.7/8.0.29 以下是 innodb_log_file_size × innodb_log_files_in_group，需要重启。调大之前先确认磁盘能容纳。
-- @caveats: 在 MySQL 8.0.30 之后，redo log 由固定文件改为可动态调整的容量池，Innodb_log_waits 的统计口径也随之变化（不再是"等待 checkpoint"而是"等待写入 redo 缓冲区空间"），因此不同版本之间该数值不可直接比较。该计数器自实例启动累计，不重置；重启后清零。只要非零就报——因为"曾经等待"本身就说明容量规划偏紧。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
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
