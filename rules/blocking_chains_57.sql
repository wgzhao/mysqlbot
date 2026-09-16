-- @id: blocking_chains_57
-- @title: 存在行锁等待链（5.7 路径）
-- @severity: warn
-- @dimension: risk
-- @scope: workload
-- @object: trx
-- @requires: process
-- @exactness: catalog
-- @since: 5.7
-- @removed_in: 8.0
-- @tags: lock,innodb
-- @remediation: 先看 blocking 侧的 SQL：通常是缺索引导致锁范围放大（本该锁一行却锁了一片），或批量更新没有按主键排序造成交叉死锁。定位到阻塞方后，优先 kill 阻塞方而不是等待方——等待方往往是无辜的业务请求。真正要修的是阻塞方那条 SQL 的加锁范围。
-- @caveats: 这是 8.0 版 blocking_chains 的 5.7 变体。8.0 移除了 information_schema.INNODB_LOCKS 与 INNODB_LOCK_WAITS（改用 performance_schema.data_locks / data_lock_waits），所以两个版本必须用两套 SQL——规则用 @since/@removed_in 门禁，同一实例上只会启用其中一条，不会重复报。5.7 的 INNODB_LOCKS 只包含"正在等待的锁"和"正在阻塞别人的锁"，不含全部锁，这正好就是本规则关心的那部分。locked_schema / locked_table 由 LOCK_TABLE 按第一个点号切开，库名或表名里含点号时会切错——这种命名极少见，但看到可疑结果时以 LOCK_TABLE 原文为准。等待时长取自 TRX_WAIT_STARTED，该列在事务开始等待时才被赋值。已用"等待 >= 10 秒"过滤瞬时争用。INNODB_LOCKS 在 5.7 已是 deprecated 的 I_S 表，实例日志里可能有弃用告警，与本规则无关；它返回 0 行时不代表没有锁竞争，只代表此刻没有等待链。
-- @ref: pgbot/blocking_chains
-- @safety: KILL <blocking_pid>
-- @safety_note: 证据列 suggested_kill 是一个可直接执行的 KILL 语句。kill 会回滚阻塞方未提交的事务——先确认那不是一个正在跑的关键批处理，否则会把一次"等待"变成一次"业务失败"。
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  CASE WHEN w.wait_s >= 300 THEN 'critical' ELSE 'warn' END AS severity,
  w.locked_schema   AS locked_schema,
  w.locked_table    AS locked_table,
  w.locked_index    AS locked_index,
  w.locked_type     AS locked_type,
  w.lock_mode       AS waiting_lock_mode,
  w.lock_data       AS waiting_lock_data,
  w.wait_s          AS wait_seconds,
  w.waiting_pid     AS waiting_pid,
  w.waiting_user    AS waiting_user,
  w.waiting_query   AS waiting_query,
  w.blocking_pid    AS blocking_pid,
  w.blocking_user   AS blocking_user,
  w.blocking_query  AS blocking_query,
  w.blocking_trx    AS blocking_trx_id,
  w.blocking_age_s  AS blocking_trx_age_seconds,
  w.kill_blocker    AS suggested_kill
FROM (
  SELECT
    REPLACE(SUBSTRING_INDEX(rl.LOCK_TABLE, '.', 1), '`', '')  AS locked_schema,
    REPLACE(SUBSTRING_INDEX(rl.LOCK_TABLE, '.', -1), '`', '') AS locked_table,
    rl.LOCK_INDEX                                             AS locked_index,
    rl.LOCK_TYPE                                              AS locked_type,
    rl.LOCK_MODE                                              AS lock_mode,
    LEFT(rl.LOCK_DATA, 80)                                    AS lock_data,
    TIMESTAMPDIFF(SECOND, wt.TRX_WAIT_STARTED, NOW())         AS wait_s,
    wt.TRX_MYSQL_THREAD_ID                                    AS waiting_pid,
    wp.USER                                                   AS waiting_user,
    LEFT(COALESCE(wt.TRX_QUERY, wp.INFO), 200)                 AS waiting_query,
    bt.TRX_MYSQL_THREAD_ID                                    AS blocking_pid,
    bp.USER                                                   AS blocking_user,
    LEFT(COALESCE(bt.TRX_QUERY, bp.INFO), 200)                 AS blocking_query,
    bt.TRX_ID                                                 AS blocking_trx,
    TIMESTAMPDIFF(SECOND, bt.TRX_STARTED, NOW())              AS blocking_age_s,
    CASE WHEN bt.TRX_MYSQL_THREAD_ID IS NULL
         THEN '(阻塞事务没有对应会话，无法 KILL——多半是已断开的连接残留)'
         ELSE CONCAT('KILL ', bt.TRX_MYSQL_THREAD_ID, ';')
    END                                                       AS kill_blocker
  FROM information_schema.INNODB_LOCK_WAITS lw
  JOIN information_schema.INNODB_LOCKS rl
    ON rl.LOCK_ID = lw.REQUESTED_LOCK_ID
  JOIN information_schema.INNODB_TRX wt
    ON wt.TRX_ID = lw.REQUESTING_TRX_ID
  JOIN information_schema.INNODB_TRX bt
    ON bt.TRX_ID = lw.BLOCKING_TRX_ID
  LEFT JOIN (SELECT ID, USER, INFO FROM information_schema.PROCESSLIST) wp
    ON wp.ID = wt.TRX_MYSQL_THREAD_ID
  LEFT JOIN (SELECT ID, USER, INFO FROM information_schema.PROCESSLIST) bp
    ON bp.ID = bt.TRX_MYSQL_THREAD_ID
) w
WHERE w.wait_s >= 10
  AND (w.waiting_user IS NULL
       OR w.waiting_user <> SUBSTRING_INDEX(CURRENT_USER(), '@', 1))
ORDER BY w.wait_s DESC
