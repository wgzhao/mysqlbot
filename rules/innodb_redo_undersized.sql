-- @id: innodb_redo_undersized
-- @title: redo log 容量相对缓冲池偏小
-- @severity: info
-- @dimension: latency
-- @scope: instance
-- @object: setting:innodb_redo_log_capacity
-- @requires: p_s
-- @exactness: catalog
-- @since: 5.7
-- @tags: innodb,redo
-- @remediation: redo 空间不足会迫使后台频繁做 checkpoint 刷脏页，写入吞吐随之下滑。经验做法是让 redo 至少能容纳"一次 checkpoint 周期内的写入量"，粗算可按缓冲池的 25%~100% 设。MySQL 8.0.30+ 可直接 SET GLOBAL innodb_redo_log_capacity（在线生效）；更低版本要改 innodb_log_file_size × innodb_log_files_in_group 并重启。
-- @caveats: 这是个启发式阈值，不是硬错误：只读为主、缓冲池很大（比如几百 GB）的实例，redo 占缓冲池比例天然很低且完全正常——此时应把本规则加入 skip。判定还忽略了一个更直接的证据：若 innodb_log_waits 非零（见该规则），说明确实已经在等待，那才是需要立刻处理的。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
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
