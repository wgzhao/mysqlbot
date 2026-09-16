-- @id: thread_cache_miss
-- @title: 连接线程复用率低（频繁创建/销毁线程）
-- @severity: info
-- @dimension: latency
-- @scope: instance
-- @object: setting:thread_cache_size
-- @requires: p_s
-- @exactness: cumulative
-- @since: 5.7
-- @min_uptime: 3600
-- @tags: tuning,connection
-- @remediation: 把 thread_cache_size 调到能覆盖峰值并发连接（常见做法是没有专门理由就设成 max_connections 的 1/4 以上，或直接设成几百）。thread_cache_size=0 表示每来一个连接就创建新线程，短连接场景下这是明确的浪费。
-- @caveats: 用运行时长门禁（@min_uptime: 1 小时）与 Connections > 1000 双重门控，避免低流量/刚重启实例误报——不满足时本规则被显式跳过，不会误报干净。连接池架构下这个指标天然很低，不要为此调参。MariaDB 的线程池（thread_handling=pool-of-threads）下该指标无意义。
-- @ref: pgbot/low_cache_hit
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
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
