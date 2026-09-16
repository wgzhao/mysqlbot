-- @id: replica_writable
-- @title: 从库可写（read_only 关闭）
-- @severity: warn
-- @dimension: risk
-- @scope: cluster
-- @object: replication
-- @requires: p_s,replication
-- @exactness: catalog
-- @since: 5.7
-- @tags: replication,safety
-- @remediation: 存在复制通道且 read_only=OFF，意味着业务代码可以把写请求打到从库上，产生主从不一致，且这些写入会与 SQL 线程的写入冲突。正确做法是开启 read_only=ON 或 super_read_only=ON（后者连 SUPER 账号也拦住，能防住"用管理员账号误写"）。
-- @caveats: 该规则只在"已经存在复制通道"时才触发，因此不适用于承担写流量的主库。有些架构刻意让从库可写（例如多主、双写、或把从库当只读业务库但接受不一致），这类情况下应把本规则加入 skip 列表而不是调参。读取 P_S 复制表需要 REPLICATION CLIENT 权限，缺权限时本规则会被跳过而不是误报干净。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  'warn'            AS severity,
  @@read_only       AS read_only,
  @@super_read_only AS super_read_only,
  (SELECT GROUP_CONCAT(DISTINCT s.CHANNEL_NAME)
     FROM performance_schema.replication_applier_status s) AS channels,
  (SELECT COUNT(*)
     FROM performance_schema.replication_applier_status)   AS channel_count
FROM DUAL
WHERE @@read_only = 0
  AND EXISTS (SELECT 1 FROM performance_schema.replication_applier_status)
