-- @id: innodb_row_lock_contention
-- @title: 行锁等待占用时间偏高
-- @severity: info
-- @dimension: latency
-- @scope: history
-- @object: none
-- @requires: p_s
-- @exactness: cumulative
-- @since: 5.7
-- @remediation: 这是累计视角的趋势信号，用来判断"锁竞争是不是一个长期问题"。定位到具体争用请用 blocking_chains（瞬时视角）。长期偏高通常意味着热点行的更新并发过高（例如计数器表、状态字段），考虑改批量或换无锁方案。
-- @caveats: 两个计数器自实例启动累计，重启会清零，因此重启后一段时间内不报（已用 ratio 门禁而非绝对量）。avg_wait_ms 会被少量超长等待拉高，不代表典型等待时长。
-- @ref: pgbot/wait_lock_contention
SELECT
  CASE WHEN raw.lock_time_ratio >= 0.05 THEN 'warn' ELSE 'info' END AS severity,
  raw.waits                                                    AS row_lock_waits,
  ROUND(raw.avg_wait_ms, 2)                                    AS avg_wait_ms,
  ROUND(raw.total_wait_s, 1)                                   AS total_wait_s,
  ROUND(100 * raw.lock_time_ratio, 3)                          AS pct_of_uptime_in_lock_wait,
  raw.uptime_s                                                 AS uptime_s
FROM (
  SELECT
    w.v                                  AS waits,
    (t.v / NULLIF(w.v, 0))               AS avg_wait_ms,
    (t.v / 1000)                         AS total_wait_s,
    (t.v / NULLIF(u.v * 1000, 0))        AS lock_time_ratio,
    u.v                                  AS uptime_s
  FROM
    (SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS v
       FROM performance_schema.global_status
      WHERE VARIABLE_NAME = 'Innodb_row_lock_waits') w
  CROSS JOIN
    (SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS v
       FROM performance_schema.global_status
      WHERE VARIABLE_NAME = 'Innodb_row_lock_time') t
  CROSS JOIN
    (SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS v
       FROM performance_schema.global_status
      WHERE VARIABLE_NAME = 'Uptime') u
) raw
WHERE raw.waits > 100
  AND raw.lock_time_ratio >= 0.01
