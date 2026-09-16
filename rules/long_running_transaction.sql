-- @id: long_running_transaction
-- @title: 存在长时间运行的事务
-- @severity: warn
-- @dimension: risk
-- @scope: workload
-- @object: trx
-- @requires: process
-- @exactness: catalog
-- @since: 5.7
-- @remediation: 长事务会阻止 InnoDB purge、放大 undo 体积、并长时间持有行锁。先确认是应用漏了 commit（最常见）、还是批量任务本身过大（拆分批次）。必要时 kill 前务必确认会话用途。
-- @caveats: 大批量导入/DDL 期间长事务是预期的；只读长事务不发警告的前提是它不持有 undo，但 InnoDB 里无法区分，因此一律报出。取会话的用户/来源走 information_schema.PROCESSLIST 而不是 performance_schema.threads——后者需要 SELECT ON performance_schema.*，而业务账号通常没有，一旦用它会整条规则被拒（1142）、白白丢掉这条高价值发现；PROCESSLIST 在 5.7/8.0/8.4 都只需 PROCESS 即可看到全部会话。
-- @ref: pgbot/long_running_transaction
SELECT
  CASE WHEN t.age_s >= 3600 THEN 'critical' ELSE 'warn' END AS severity,
  t.trx_state     AS trx_state,
  t.started_at    AS started_at,
  t.age_s         AS age_s,
  t.thread_id     AS thread_id,
  t.db_user       AS db_user,
  t.client_host   AS client_host,
  t.rows_locked   AS rows_locked,
  t.rows_modified AS rows_modified,
  t.query_head    AS query_head
FROM (
  SELECT
    trx.trx_id                                   AS trx_id,
    trx.trx_state                                AS trx_state,
    trx.trx_started                              AS started_at,
    TIMESTAMPDIFF(SECOND, trx.trx_started, NOW()) AS age_s,
    trx.trx_mysql_thread_id                       AS thread_id,
    pl.USER                                       AS db_user,
    pl.HOST                                       AS client_host,
    trx.trx_rows_locked                           AS rows_locked,
    trx.trx_rows_modified                         AS rows_modified,
    LEFT(COALESCE(trx.trx_query, '(idle)'), 200)  AS query_head
  FROM information_schema.INNODB_TRX trx
  LEFT JOIN information_schema.PROCESSLIST pl
         ON pl.ID = trx.trx_mysql_thread_id
) t
WHERE t.age_s >= 300
  AND (t.db_user IS NULL
       OR t.db_user <> SUBSTRING_INDEX(CURRENT_USER(), '@', 1))
ORDER BY t.age_s DESC
