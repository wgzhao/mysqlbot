-- @id: sync_binlog_not_1
-- @title: binlog 未每次提交同步（sync_binlog 非 1）
-- @severity: warn
-- @dimension: risk
-- @scope: instance
-- @object: setting:sync_binlog
-- @requires: -
-- @exactness: exact
-- @since: 5.7
-- @tags: durability,replication
-- @remediation: 设回 1（每次提交 fsync binlog）。非 1 的取值在主机断电时会丢失已提交但未落盘的事务——对主库意味着数据丢失，对从库意味着接到的 binlog 比预期少，而在 MGR 或半同步复制下还可能造成成员间数据分歧。
-- @caveats: 该参数只在 log_bin=ON 时有意义，因此本规则内联判断了 log_bin。大批量导入时临时设成 0 是常见提速手段，但必须记得改回来——本规则会一直报到你改回来为止，这正是它存在的价值。MySQL 8.0 默认即为 1。用 @@变量 直读，避免依赖 8.4 已移除的 information_schema.GLOBAL_VARIABLES。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  'warn'            AS severity,
  'sync_binlog'     AS variable_name,
  @@sync_binlog     AS current_value,
  '1'               AS suggested_value,
  @@log_bin         AS log_bin
FROM DUAL
WHERE @@sync_binlog <> 1
  AND @@log_bin <> 0
