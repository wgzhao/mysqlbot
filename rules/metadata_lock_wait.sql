-- @id: metadata_lock_wait
-- @title: 存在元数据锁（MDL）等待
-- @severity: warn
-- @dimension: risk
-- @scope: workload
-- @object: table
-- @requires: p_s_mdl,process
-- @exactness: catalog
-- @since: 5.7
-- @remediation: MDL 等待意味着有 DDL 在排队，而它后面所有访问该表的事务都会被一起堵住——这是 MySQL 最典型的"一个 ALTER 搞挂整个库"。查 blocking_pids 找出持锁的长事务或未提交事务，先处理它们，DDL 才能继续。
-- @caveats: 只报"同一对象上既有 PENDING 锁又有 GRANTED 锁"的情况，即真正的争用，不报瞬间过路的排队；OBJECT_TYPE 为 GLOBAL 的锁会在 FLUSH TABLES 时瞬时出现，已排除。performance_schema.metadata_locks 自 5.7.3 起就存在（不是 8.0 专属），本规则用的 OBJECT_TYPE/OBJECT_SCHEMA/OBJECT_NAME/LOCK_STATUS/OWNER_THREAD_ID 五个列 5.7 也都有，因此 5.7/8.0/8.4 通用。注意 P_S 的 metadata_locks 表需要 metadata_locks 这个 instrument 被打开（默认开），关掉它本规则会静默返回 0 行。
-- @ref: -
SELECT
  CASE WHEN COUNT(DISTINCT w.waiting_pid) >= 5 THEN 'critical' ELSE 'warn' END AS severity,
  w.object_type       AS object_type,
  w.object_schema     AS object_schema,
  w.object_name       AS object_name,
  COUNT(DISTINCT w.waiting_pid)  AS waiting_threads,
  GROUP_CONCAT(DISTINCT w.waiting_pid ORDER BY w.waiting_pid)   AS waiting_pids,
  GROUP_CONCAT(DISTINCT w.blocking_pid ORDER BY w.blocking_pid) AS blocking_pids,
  MAX(w.waiting_sql)  AS sample_waiting_sql,
  MAX(w.blocking_sql) AS sample_blocking_sql
FROM (
  SELECT
    p.OBJECT_TYPE                  AS object_type,
    p.OBJECT_SCHEMA                AS object_schema,
    p.OBJECT_NAME                  AS object_name,
    pt.PROCESSLIST_ID              AS waiting_pid,
    LEFT(pt.PROCESSLIST_INFO, 160) AS waiting_sql,
    gt.PROCESSLIST_ID              AS blocking_pid,
    LEFT(gt.PROCESSLIST_INFO, 160) AS blocking_sql
  FROM performance_schema.metadata_locks p
  JOIN performance_schema.threads pt
    ON pt.THREAD_ID = p.OWNER_THREAD_ID
  JOIN performance_schema.metadata_locks g
    ON  g.OBJECT_TYPE = p.OBJECT_TYPE
    AND g.OBJECT_SCHEMA <=> p.OBJECT_SCHEMA
    AND g.OBJECT_NAME <=> p.OBJECT_NAME
    AND g.LOCK_STATUS = 'GRANTED'
  LEFT JOIN performance_schema.threads gt
    ON gt.THREAD_ID = g.OWNER_THREAD_ID
  WHERE p.LOCK_STATUS = 'PENDING'
    AND p.OBJECT_TYPE IN ('TABLE', 'SCHEMA')
    AND (pt.PROCESSLIST_USER IS NULL
         OR pt.PROCESSLIST_USER <> SUBSTRING_INDEX(CURRENT_USER(), '@', 1))
) w
GROUP BY w.object_type, w.object_schema, w.object_name
ORDER BY COUNT(DISTINCT w.waiting_pid) DESC
