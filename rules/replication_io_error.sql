-- @id: replication_io_error
-- @title: 复制 IO 线程连接源端失败
-- @severity: critical
-- @dimension: risk
-- @scope: cluster
-- @object: replication
-- @requires: p_s,replication
-- @exactness: catalog
-- @since: 5.7
-- @tags: replication
-- @remediation: LAST_ERROR_NUMBER 非零几乎总是网络/认证/源端 binlog 已被清理三类原因之一。LAST_HEARTBEAT_TIMESTAMP 长期不更新（超过 heartbeat_interval 的若干倍）说明心跳也断了。先确认源端端口可达、复制账号未过期、以及 sync_binlog/binlog_expire_logs_seconds 是否把需要的 binlog 删掉了。
-- @caveats: 心跳时间戳受源端 slave_net_timeout 与 MASTER_HEARTBEAT_PERIOD 影响，源端空闲时也可能看起来"很久没心跳"——必须结合 LAST_ERROR_NUMBER 一起判断，本规则只输出有错误或服务未运行的通道。非复制实例上该表为空，返回 0 行。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  'critical'                                  AS severity,
  c.CHANNEL_NAME                              AS channel_name,
  c.SERVICE_STATE                             AS service_state,
  c.LAST_ERROR_NUMBER                         AS last_error_number,
  LEFT(c.LAST_ERROR_MESSAGE, 240)             AS last_error_message,
  c.LAST_ERROR_TIMESTAMP                      AS last_error_at,
  c.LAST_HEARTBEAT_TIMESTAMP                  AS last_heartbeat_at,
  TIMESTAMPDIFF(SECOND, c.LAST_HEARTBEAT_TIMESTAMP, NOW()) AS heartbeat_age_seconds,
  c.COUNT_RECEIVED_HEARTBEATS                 AS heartbeats_received
FROM performance_schema.replication_connection_status c
WHERE c.LAST_ERROR_NUMBER <> 0
   OR c.SERVICE_STATE <> 'ON'
ORDER BY c.CHANNEL_NAME
