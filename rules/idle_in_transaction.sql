-- @id: idle_in_transaction
-- @title: 事务开着但没有语句在执行
-- @severity: warn
-- @dimension: risk
-- @scope: workload
-- @object: trx
-- @requires: p_s,process
-- @exactness: catalog
-- @since: 5.7
-- @remediation: 典型成因是应用取了连接、开了事务却忘了 commit/rollback（例如异常分支没有回滚）。它比长事务更隐蔽：CPU 和 QPS 都看不出来，但 purge 被卡住、undo 持续增长、行锁一直不释放。
-- @caveats: 判定依据是 TRX_STATE='RUNNING' 且 TRX_QUERY 为空——事务活着但此刻没有语句在跑。应用连接池在两条语句之间也会短暂呈现该状态，因此已用 60 秒做门禁。MySQL 不暴露"事务从何时开始空闲"，open_seconds 是事务总年龄，是空闲时长的上界。
-- @ref: pgbot/idle_in_transaction
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  CASE WHEN t.open_s >= 900 THEN 'critical' ELSE 'warn' END AS severity,
  t.trx_state   AS trx_state,
  t.started_at  AS started_at,
  t.open_s      AS open_seconds,
  t.thread_id   AS thread_id,
  t.db_user     AS db_user,
  t.client_host AS client_host,
  t.rows_locked AS rows_locked
FROM (
  SELECT
    trx.trx_state                                  AS trx_state,
    trx.trx_started                                AS started_at,
    TIMESTAMPDIFF(SECOND, trx.trx_started, NOW())   AS open_s,
    trx.trx_mysql_thread_id                         AS thread_id,
    th.PROCESSLIST_USER                             AS db_user,
    th.PROCESSLIST_HOST                             AS client_host,
    trx.trx_rows_locked                             AS rows_locked
  FROM information_schema.INNODB_TRX trx
  LEFT JOIN performance_schema.threads th
         ON th.PROCESSLIST_ID = trx.trx_mysql_thread_id
  WHERE trx.trx_state = 'RUNNING'
    AND trx.trx_query IS NULL
) t
WHERE t.open_s >= 60
  AND (t.db_user IS NULL
       OR t.db_user <> SUBSTRING_INDEX(CURRENT_USER(), '@', 1))
ORDER BY t.open_s DESC
