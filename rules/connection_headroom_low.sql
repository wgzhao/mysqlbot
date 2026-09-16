-- @id: connection_headroom_low
-- @title: 连接数余量不足（历史峰值逼近 max_connections）
-- @severity: warn
-- @dimension: capacity
-- @scope: instance
-- @object: setting:max_connections
-- @requires: p_s
-- @exactness: cumulative
-- @since: 5.7
-- @tags: connection,capacity
-- @remediation: Max_used_connections 是自实例启动以来的历史峰值，达到 max_connections 的那一刻，后续新连接会被直接拒绝（error 1040 Too many connections），连管理员都可能挤不进去。先判断峰值是多少、发生在什么时候：如果只是某次批量任务造成的尖峰，限制那个任务的并发比调大上限更合适；如果确实持续增长，再提高 max_connections，并同步评估内存（每连接约 数百 KB 到数 MB，取决于排序/连接缓冲区）与 open_files_limit。
-- @caveats: Max_used_connections 自启动累计、不衰减，一次历史尖峰会让该指标长期保持高位直到重启——不要仅凭它调参，结合 Threads_connected 的常态水位一起看。另外建议始终给 max_connections 留出应急余量，并保留一个具备 CONNECTION_ADMIN（8.0+）/ SUPER 的账号作为"最后一把钥匙"。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  CASE WHEN r.pct >= 95 THEN 'critical' ELSE 'warn' END AS severity,
  r.max_used          AS max_used_connections,
  r.max_conn          AS max_connections,
  ROUND(r.pct, 1)     AS peak_used_pct,
  r.threads_connected AS threads_connected_now,
  r.threads_running   AS threads_running_now,
  r.uptime_s          AS uptime_s
FROM (
  SELECT
    s.max_used,
    s.threads_connected,
    s.threads_running,
    s.uptime_s,
    v.max_conn,
    100 * s.max_used / NULLIF(v.max_conn, 0) AS pct
  FROM (
    SELECT
      MAX(CASE WHEN VARIABLE_NAME = 'Max_used_connections' THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS max_used,
      MAX(CASE WHEN VARIABLE_NAME = 'Threads_connected'    THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS threads_connected,
      MAX(CASE WHEN VARIABLE_NAME = 'Threads_running'      THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS threads_running,
      MAX(CASE WHEN VARIABLE_NAME = 'Uptime'               THEN CAST(VARIABLE_VALUE AS DECIMAL(30,0)) END) AS uptime_s
    FROM performance_schema.global_status
  ) s
  CROSS JOIN (
    SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS max_conn
    FROM performance_schema.global_variables
    WHERE VARIABLE_NAME = 'max_connections'
  ) v
) r
WHERE r.max_conn > 0
  AND r.pct >= 80
