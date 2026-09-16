-- @id: table_open_cache_miss
-- @title: 表缓存未命中率偏高（反复打开表定义）
-- @severity: info
-- @dimension: latency
-- @scope: instance
-- @object: setting:table_open_cache
-- @requires: p_s
-- @exactness: cumulative
-- @since: 5.7
-- @min_uptime: 3600
-- @tags: tuning,cache
-- @remediation: 先看 table_open_cache 与 Open_tables 的差距：若 Open_tables 长期贴近 table_open_cache，把 table_open_cache 提高（单个连接句柄的表缓存上限由 table_open_cache 决定，句柄占用总量还受 table_open_cache_instances 影响）。若 misses 高但 Open_tables 远小于上限，说明工作集本身比缓存大，优先确认是否有大量一次性表（临时表、按月分表）在轮转。
-- @caveats: 累计计数器，实例重启后清零，故用运行时长门禁（@min_uptime: 1 小时）显式跳过而不是报干净；另有"命中+未命中 > 1 万次"门禁以排除低流量实例。此指标只反映"表定义是否需要重新打开"，不是磁盘 IO 指标——命中率低会带来元数据锁竞争，但不会直接体现为慢查询。
-- @ref: pgbot/low_cache_hit
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
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
