-- @id: open_tables_pressure
-- @title: 当前打开的表数量逼近 table_open_cache 上限
-- @severity: info
-- @dimension: capacity
-- @scope: instance
-- @object: setting:table_open_cache
-- @requires: p_s
-- @exactness: scraped
-- @since: 5.7
-- @tags: tuning,capacity
-- @remediation: Open_tables 贴近 table_open_cache 时，表会被反复关闭再打开，表现为元数据锁竞争加剧与 CPU 空转（对应 table_open_cache_miss 规则里的 misses）。把 table_open_cache 提到明显高于常态 Open_tables 的值即可。注意内存代价：每个表缓存项占用约几百字节到 1KB，另需相应打开的文件描述符（受 open_files_limit 约束）。
-- @caveats: Open_tables 是瞬时值（读 SHOW GLOBAL STATUS 的那一刻），业务高低峰差异大的实例可能只在峰值命中——这恰恰是想要的信号。它与 table_open_cache_miss 是同一问题的两种视角：这里看"水位"，那里看"已经发生的未命中"，两者一起看更准。调整 table_open_cache 会影响所有连接，属于全局参数，需要评估内存与文件句柄上限。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
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
