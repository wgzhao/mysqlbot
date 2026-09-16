-- @id: connection_saturation
-- @title: 连接数接近上限
-- @severity: warn
-- @dimension: risk
-- @scope: workload
-- @object: setting:max_connections
-- @requires: p_s
-- @exactness: cumulative
-- @since: 5.7
-- @remediation: 先查应用侧是否有连接泄漏（连接池未归还），再考虑提高 max_connections。盲目调大只会把压力转成线程与内存压力；MySQL 每连接开销远大于 PG。
-- @caveats: 瞬时高峰触发的命中不等于持续问题，建议连续几次观测都命中再动手；Threads_connected 是瞬时值，采样时点会影响结论。
-- @ref: pgbot/connection_saturation
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  CASE WHEN raw.used_ratio >= 0.95 THEN 'critical' ELSE 'warn' END AS severity,
  raw.threads_connected                                           AS threads_connected,
  raw.max_connections                                             AS max_connections,
  ROUND(100 * raw.used_ratio, 1)                                   AS used_pct,
  raw.threads_running                                             AS threads_running,
  raw.err_max_conn                                                AS conn_errors_max_connections
FROM (
  SELECT
    st.threads_connected,
    st.threads_running,
    st.err_max_conn,
    gv.mc                                    AS max_connections,
    (st.threads_connected / NULLIF(gv.mc, 0)) AS used_ratio
  FROM
    (SELECT
       MAX(CASE WHEN VARIABLE_NAME = 'Threads_connected' THEN CAST(VARIABLE_VALUE AS SIGNED) END) AS threads_connected,
       MAX(CASE WHEN VARIABLE_NAME = 'Threads_running'   THEN CAST(VARIABLE_VALUE AS SIGNED) END) AS threads_running,
       MAX(CASE WHEN VARIABLE_NAME = 'Connection_errors_max_connections'
                THEN CAST(VARIABLE_VALUE AS SIGNED) END)                                        AS err_max_conn
       FROM performance_schema.global_status
      WHERE VARIABLE_NAME IN ('Threads_connected', 'Threads_running', 'Connection_errors_max_connections')) st
  CROSS JOIN
    (SELECT CAST(VARIABLE_VALUE AS SIGNED) AS mc
       FROM performance_schema.global_variables
      WHERE VARIABLE_NAME = 'max_connections') gv
) raw
WHERE raw.max_connections > 0
  AND raw.used_ratio >= 0.85
