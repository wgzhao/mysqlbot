-- @id: undo_history_list_long
-- @title: InnoDB 历史链表过长（purge 落后）
-- @severity: warn
-- @dimension: risk
-- @scope: workload
-- @object: none
-- @requires: process
-- @exactness: sampled
-- @since: 5.7
-- @remediation: purge 被长时间存活的事务卡住是首要原因——先看 long_running_transaction / idle_in_transaction 两条规则是否同时命中。其次是写放大过高（批量 DELETE/UPDATE 产生的 undo 来不及清理），考虑拆批。
-- @caveats: 阈值 10 万 / 100 万是经验值，写放大很高的库常态偏高；要结合写入速率一起看，单看绝对值容易误判。指标需 INNODB_METRICS 已启用（trx_rseg_history_len 默认启用）。5.7 上该表同样存在。
-- @ref: pgbot/vacuum_horizon_blocked
SELECT
  CASE WHEN m.COUNT >= 1000000 THEN 'critical' ELSE 'warn' END AS severity,
  m.COUNT   AS history_list_length,
  m.COMMENT AS metric_comment
FROM information_schema.INNODB_METRICS m
WHERE m.NAME = 'trx_rseg_history_len'
  AND m.COUNT >= 100000
