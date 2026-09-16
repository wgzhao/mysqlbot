-- @id: sql_require_primary_key_off
-- @title: 未强制新表必须有主键（sql_require_primary_key=OFF）
-- @severity: info
-- @dimension: hygiene
-- @scope: instance
-- @object: setting:sql_require_primary_key
-- @requires: -
-- @exactness: exact
-- @since: 8.0.13
-- @tags: schema,safety
-- @remediation: 打开 sql_require_primary_key=ON（可动态设置），让"创建无主键表"这一动作直接失败。MySQL 8.0.13 引入该参数，是防止无主键表继续产生的最省事手段。注意：开启后，对已存在的无主键表做 ADD COLUMN 等需要重建表的 DDL 也会被拒绝，需要先补主键。
-- @caveats: 在 MySQL 8.0.13 之前以及 MariaDB 上不存在该变量——版本门禁已用 @since 声明，避免在那些版本上因"未知系统变量"而失败。仅有存量无主键表的实例请配合 table_without_primary_key 规则一起看：那条查存量，这条防增量。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  'info'                    AS severity,
  'sql_require_primary_key' AS variable_name,
  @@sql_require_primary_key AS current_value,
  'ON'                      AS suggested_value
FROM DUAL
WHERE @@sql_require_primary_key = 0
