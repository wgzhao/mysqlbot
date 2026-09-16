-- @id: binlog_retention_unbounded_57
-- @title: binlog 永不自动清理（5.7 口径：expire_logs_days=0）
-- @severity: warn
-- @dimension: capacity
-- @scope: instance
-- @object: setting:expire_logs_days
-- @requires: -
-- @exactness: exact
-- @since: 5.7
-- @removed_in: 8.0
-- @tags: binlog,capacity
-- @remediation: 设置 expire_logs_days 为与"最长可接受恢复点"匹配的天数（如 7 或 30）。等于 0 表示永不自动清理 binlog，写入量大的实例会把磁盘写满。
-- @caveats: 8.0 起该变量被 binlog_expire_logs_seconds 取代（且 8.4 已彻底移除），所以本规则声明 @removed_in: 8.0 —— 在 8.0+ 上会被自动跳过，由 binlog_retention_unbounded 接手。这条规则的存在只为覆盖 5.7/5.6 的老实例，避免在那些版本上直接报"未知系统变量"。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  'warn'                AS severity,
  'expire_logs_days'    AS variable_name,
  @@expire_logs_days    AS current_days,
  '7'                   AS suggested_days,
  @@log_bin             AS log_bin
FROM DUAL
WHERE @@log_bin <> 0
  AND @@expire_logs_days = 0
