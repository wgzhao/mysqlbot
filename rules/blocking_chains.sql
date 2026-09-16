-- @id: blocking_chains
-- @title: 存在行锁等待链（有事务在等另一事务持有的行锁）
-- @severity: warn
-- @dimension: risk
-- @scope: workload
-- @object: trx
-- @requires: p_s_locks,process
-- @exactness: catalog
-- @since: 8.0
-- @tags: lock,innodb
-- @remediation: 先看 blocking 侧的 SQL：通常是缺索引导致锁范围放大（本该锁一行却锁了一片），或批量更新没有按主键排序造成交叉死锁。定位到阻塞方后，优先 kill 阻塞方而不是等待方——等待方往往是无辜的业务请求。真正要修的是阻塞方那条 SQL 的加锁范围。
-- @caveats: 直读 performance_schema.data_lock_waits / data_locks，**不走 sys.innodb_lock_waits**——因为 sys 视图是 SQL SECURITY INVOKER，且其函数 DEFINER mysql.sys 只有 USAGE，会让最小权限账号（只有 PROCESS + SELECT ON sys.*）拿到 1356 错误；直读 P_S 只需 PROCESS。代价是只覆盖 InnoDB 行锁，不含表锁与元数据锁（元数据锁见 metadata_lock_wait），且 5.7 没有 data_lock_waits 表（5.7 用 information_schema.INNODB_LOCK_WAITS，本工具暂未覆盖该版本路径）。等待时长取自 information_schema.INNODB_TRX.TRX_WAIT_STARTED，该列在事务开始等待时才会被赋值。已用"等待 >= 10 秒"过滤掉瞬时争用——1~2 秒的等待在正常写入下很常见，报出来是噪音。
-- @ref: pgbot/blocking_chains
-- @safety: KILL <blocking_pid>
-- @safety_note: 证据列 suggested_kill 是一个可直接执行的 KILL 语句。kill 会回滚阻塞方未提交的事务——先确认那不是一个正在跑的关键批处理，否则会把一次"等待"变成一次"业务失败"。
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  CASE WHEN w.wait_s >= 300 THEN 'critical' ELSE 'warn' END AS severity,
  w.object_schema   AS locked_schema,
  w.object_name     AS locked_table,
  w.index_name      AS locked_index,
  w.lock_type       AS locked_type,
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
  w.kill_blocker    AS suggested_kill
FROM (
  SELECT
    rl.OBJECT_SCHEMA                                  AS object_schema,
    rl.OBJECT_NAME                                    AS object_name,
    rl.INDEX_NAME                                     AS index_name,
    rl.LOCK_TYPE                                      AS lock_type,
    rl.LOCK_MODE                                      AS lock_mode,
    LEFT(rl.LOCK_DATA, 80)                            AS lock_data,
    TIMESTAMPDIFF(SECOND, wt.TRX_WAIT_STARTED, NOW())  AS wait_s,
    rt.PROCESSLIST_ID                                 AS waiting_pid,
    rt.PROCESSLIST_USER                               AS waiting_user,
    LEFT(rt.PROCESSLIST_INFO, 200)                    AS waiting_query,
    gt.PROCESSLIST_ID                                 AS blocking_pid,
    gt.PROCESSLIST_USER                               AS blocking_user,
    LEFT(gt.PROCESSLIST_INFO, 200)                    AS blocking_query,
    bt.TRX_ID                                         AS blocking_trx,
    CONCAT('KILL ', gt.PROCESSLIST_ID, ';')           AS kill_blocker
  FROM performance_schema.data_lock_waits lw
  JOIN performance_schema.data_locks rl
    ON rl.ENGINE_LOCK_ID = lw.REQUESTING_ENGINE_LOCK_ID
  LEFT JOIN information_schema.INNODB_TRX wt
    ON wt.TRX_ID = CAST(lw.REQUESTING_ENGINE_TRANSACTION_ID AS UNSIGNED)
  LEFT JOIN information_schema.INNODB_TRX bt
    ON bt.TRX_ID = CAST(lw.BLOCKING_ENGINE_TRANSACTION_ID AS UNSIGNED)
  LEFT JOIN performance_schema.threads rt
    ON rt.THREAD_ID = lw.REQUESTING_THREAD_ID
  LEFT JOIN performance_schema.threads gt
    ON gt.THREAD_ID = lw.BLOCKING_THREAD_ID
) w
WHERE w.wait_s >= 10
ORDER BY w.wait_s DESC
