-- @id: sort_merge_passes
-- @title: 排序合并次数偏高（sort_buffer 偏小）
-- @severity: info
-- @dimension: latency
-- @scope: workload
-- @object: setting:sort_buffer_size
-- @requires: p_s
-- @exactness: cumulative
-- @since: 5.7
-- @min_uptime: 3600
-- @remediation: 先定位产生大排序的查询。sort_buffer_size 是每连接分配，调大要按并发连接数核算内存；通常优化掉大排序比调大参数更有效。
-- @caveats: 这是启发式阈值，不是硬性错误——只要排序在业务可接受延迟内，合并几次无害。排序合并次数多但量小（每小时 < 100）不报。
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
