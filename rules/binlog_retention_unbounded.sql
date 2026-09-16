-- @id: binlog_retention_unbounded
-- @title: binlog 永不自动清理（存在撑满磁盘的风险）
-- @severity: warn
-- @dimension: capacity
-- @scope: instance
-- @object: setting:binlog_expire_logs_seconds
-- @requires: p_s
-- @exactness: exact
-- @since: 8.0
-- @tags: binlog,capacity
-- @remediation: log_bin=ON 但过期时间被显式设为 0（或自动清理被关掉），等于"永远不删 binlog"，写入量大的实例迟早把数据盘写满，而磁盘写满会连带 InnoDB 无法刷盘、实例整体不可写。设置 binlog_expire_logs_seconds 为一个与"最长可接受恢复点"匹配的值（默认 2592000 = 30 天），并确保 binlog_expire_logs_auto_purge=ON。设置过短会让从库断档后无法重连（需要的 binlog 已被删）——设之前先确认最长的主从延迟与备份窗口。
-- @caveats: MySQL 8.0 中 binlog_expire_logs_seconds 优先于已废弃的 expire_logs_days，前者非零时后者被忽略，所以本规则只看前者的值。8.0 之前的版本用 expire_logs_days，见 binlog_retention_unbounded_57。**版本边界**：binlog_expire_logs_auto_purge 是 8.0.29 才引入的变量，在 8.0.0~8.0.28 上不存在；规则改为从 performance_schema.global_variables 取值并在缺失时按 'ON' 处理（那之前的版本只要 seconds 非零就会清理），因此不会在旧 8.0 上被 1193 拒绝。该规则不判断磁盘实际使用率：磁盘更大、写入更少的实例可能永远撑不满，此时把规则加入 skip 而不是改参数。
-- @ref: -
--
-- 【坑】不能用 `FROM DUAL LEFT JOIN ...`：MySQL 把 DUAL 特例化了，DUAL 不能作为
-- JOIN 的左表，会直接报 1064。要取一个"可能不存在"的变量只能包成派生表再 LEFT JOIN。
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  'warn'                            AS severity,
  'binlog_expire_logs_seconds'      AS variable_name,
  v.secs                            AS current_seconds,
  '2592000 (30 天)'                 AS suggested_value,
  v.log_bin                         AS log_bin,
  COALESCE(ap.VARIABLE_VALUE, 'ON') AS auto_purge,
  CASE
    WHEN COALESCE(ap.VARIABLE_VALUE, 'ON') = 'OFF'
      THEN 'binlog_expire_logs_auto_purge=OFF：过期时间被完全忽略，binlog 永不自动清理'
    ELSE 'binlog_expire_logs_seconds=0：没有设置过期时间'
  END                               AS hit_reason
FROM (
  SELECT @@log_bin AS log_bin, @@binlog_expire_logs_seconds AS secs
) v
LEFT JOIN performance_schema.global_variables ap
       ON ap.VARIABLE_NAME = 'binlog_expire_logs_auto_purge'
WHERE v.log_bin <> 0
  AND (v.secs = 0
       OR COALESCE(ap.VARIABLE_VALUE, 'ON') = 'OFF')
