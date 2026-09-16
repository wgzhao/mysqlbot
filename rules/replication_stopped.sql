-- @id: replication_stopped
-- @title: 复制通道的 applier 未在运行或有错误
-- @severity: critical
-- @dimension: risk
-- @scope: cluster
-- @object: replication
-- @requires: p_s,replication
-- @exactness: catalog
-- @since: 5.7
-- @tags: replication
-- @remediation: LAST_ERROR_NUMBER 非零说明 SQL 线程因冲突/约束失败而停：先看 LAST_ERROR_MESSAGE，判断是数据不一致还是 DDL 顺序问题，修好后再 START REPLICA。SERVICE_STATE='OFF' 且无错误，通常是有人手动 STOP REPLICA 或 gtid 断档，先确认为什么停的，别直接拉起来。
-- @caveats: 本规则只覆盖 applier（SQL）线程。IO 线程的故障见 replication_io_error。在非复制实例上，performance_schema.replication_applier_status_by_worker 是空表，本规则返回 0 行——空不等于健康，只表示"这台不是从库"。读取 P_S 复制表需要 REPLICATION CLIENT 权限，缺权限时规则会被跳过而不是误报干净。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  CASE WHEN w.LAST_ERROR_NUMBER <> 0 THEN 'critical' ELSE 'warn' END AS severity,
  w.CHANNEL_NAME                       AS channel_name,
  w.WORKER_ID                          AS worker_id,
  w.SERVICE_STATE                      AS service_state,
  w.LAST_ERROR_NUMBER                  AS last_error_number,
  LEFT(w.LAST_ERROR_MESSAGE, 240)      AS last_error_message,
  w.LAST_ERROR_TIMESTAMP               AS last_error_at,
  w.APPLYING_TRANSACTION_RETRIES_COUNT AS retries,
  LEFT(w.APPLYING_TRANSACTION, 80)     AS applying_transaction
FROM performance_schema.replication_applier_status_by_worker w
WHERE w.LAST_ERROR_NUMBER <> 0
   OR w.SERVICE_STATE <> 'ON'
ORDER BY w.CHANNEL_NAME, w.WORKER_ID
