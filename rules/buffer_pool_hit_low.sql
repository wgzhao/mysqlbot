-- @id: buffer_pool_hit_low
-- @title: InnoDB 缓冲池命中率过低
-- @severity: warn
-- @dimension: latency
-- @scope: workload
-- @object: setting:innodb_buffer_pool_size
-- @requires: p_s
-- @exactness: cumulative
-- @since: 5.7
-- @min_uptime: 3600
-- @remediation: 先对比 innodb_buffer_pool_size 与 InnoDB 数据总量；OLTP 期望命中率 > 99%。若缓冲池已足够大仍低，考虑是否有大范围扫描或全表扫描在冲刷缓冲池。
-- @caveats: 刚重启的实例比率不可信，已用运行时长门禁（@min_uptime: 1 小时）保证——不满足时本规则会被显式跳过并给出原因，而不是报"干净"。冷备份、大批量导入会临时拉低比率，不要据此改参数。
-- @ref: pgbot/low_cache_hit
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
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
