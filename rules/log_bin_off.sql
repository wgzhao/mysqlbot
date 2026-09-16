-- @id: log_bin_off
-- @title: 未开启 binlog（无法做时间点恢复，无法搭建从库）
-- @severity: warn
-- @dimension: risk
-- @scope: instance
-- @object: setting:log_bin
-- @requires: -
-- @exactness: exact
-- @since: 5.7
-- @tags: backup,replication
-- @remediation: 开启 log_bin 并重启。没有 binlog 意味着恢复点只能到"最近一次全量备份"为止——误删一张表、误改一批数据，除了回滚到备份别无他法，中间几小时/几天的数据全部丢失。同时它也堵死了搭建从库、CDC 同步（Canal/Debezium）、审计追溯等一整类能力。
-- @caveats: 单机开发环境、纯缓存用途的实例刻意关闭是合理的，请加入 skip。开启 binlog 会带来额外写入量与磁盘占用，务必同时规划 binlog_expire_logs_seconds（见 binlog_retention_unbounded 规则）与磁盘容量。该参数需要重启生效，且开启后建议同时确认 server_id 非 0（复制要求，本规则一并输出）。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  'warn'       AS severity,
  'log_bin'    AS variable_name,
  @@log_bin    AS current_value,
  'ON'         AS suggested_value,
  @@server_id  AS server_id,
  @@log_bin_basename AS log_bin_basename,
  '需要重启实例生效' AS note
FROM DUAL
WHERE @@log_bin = 0
