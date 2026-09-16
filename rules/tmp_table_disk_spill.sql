-- @id: tmp_table_disk_spill
-- @title: 临时表大量落盘
-- @severity: warn
-- @dimension: latency
-- @scope: workload
-- @object: setting:tmp_table_size
-- @requires: p_s
-- @exactness: cumulative
-- @since: 5.7
-- @min_uptime: 3600
-- @remediation: 同时调大 tmp_table_size 与 max_heap_table_size（两者必须一致，否则以较小者为准）；然后定位产生大临时表的查询——通常是 GROUP BY / DISTINCT 命中了 TEXT/BLOB 列，或 ORDER BY 无法走索引。
-- @caveats: 内部临时表分内存表与磁盘表，只有内存表超限才落盘。命中说明存在落盘，但落盘量小（绝对条数少）时不必处理，已用总临时表数 > 1000 做门禁。
-- @ref: pgbot/table_bloat
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
