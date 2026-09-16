-- @id: binlog_retention_unbounded
-- @title: binlog 永不自动清理（存在撑满磁盘的风险）
-- @severity: warn
-- @dimension: capacity
-- @scope: instance
-- @object: setting:binlog_expire_logs_seconds
-- @requires: -
-- @exactness: exact
-- @since: 8.0
-- @tags: binlog,capacity
-- @remediation: log_bin=ON 但过期时间被显式设为 0，等于"永远不删 binlog"，写入量大的实例迟早把数据盘写满，而磁盘写满会连带 InnoDB 无法刷盘、实例整体不可写。设置 binlog_expire_logs_seconds 为一个与"最长可接受恢复点"匹配的值（默认 2592000 = 30 天）。设置过短会让从库断档后无法重连（需要的 binlog 已被删）——设之前先确认最长的主从延迟与备份窗口。
-- @caveats: MySQL 8.0 中 binlog_expire_logs_seconds 优先于已废弃的 expire_logs_days，前者非零时后者被忽略，所以本规则只看前者的值。8.0 之前的版本用 expire_logs_days，见 binlog_retention_unbounded_57。该规则不判断磁盘实际使用率：磁盘更大、写入更少的实例可能永远撑不满，此时把规则加入 skip 而不是改参数。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  'warn'                            AS severity,
  'binlog_expire_logs_seconds'      AS variable_name,
  @@binlog_expire_logs_seconds      AS current_seconds,
  '2592000 (30 天)'                 AS suggested_value,
  @@log_bin                         AS log_bin,
  @@binlog_expire_logs_auto_purge   AS auto_purge
FROM DUAL
WHERE @@log_bin <> 0
  AND @@binlog_expire_logs_seconds = 0
