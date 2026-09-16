-- @id: redundant_index
-- @title: 冗余索引（存在可覆盖它的其它索引）
-- @severity: info
-- @dimension: hygiene
-- @scope: schema
-- @object: index
-- @requires: schema_select,sys
-- @exactness: catalog
-- @since: 5.7
-- @tags: index,schema
-- @remediation: sys.schema_redundant_indexes 已经算出"被哪个索引完全覆盖"，按 dominant_index_name 保留、把 redundant_index_name 删掉即可。删除后写入会变快（少一次索引维护）、占用空间会下降。大表 DROP INDEX 是 online DDL，但仍需短暂 MDL，放到低峰期执行。
-- @caveats: 冗余不等于可以无脑删：如果冗余索引是某个外键唯一可用的索引，DROP 会被 InnoDB 拒绝（error 1553）；如果它是唯一索引而 dominant 是普通索引，删掉会丢唯一约束——本规则已排除"冗余索引是唯一索引"的情况。另一个常见误判来源是只服务于特定查询的短前缀索引，删之前先确认没有语句依赖它的排序。
-- @ref: pgbot/duplicate_indexes
-- @safety: DROP INDEX
-- @safety_note: 证据列 suggested_drop 是 sys 自动生成的可执行 DROP INDEX 语句。执行前请确认该索引不是外键依赖项，并在低峰期操作。
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  CASE WHEN t.bytes >= 1073741824 THEN 'warn' ELSE 'info' END AS severity,
  r.table_schema            AS table_schema,
  r.table_name              AS table_name,
  r.redundant_index_name    AS redundant_index,
  r.redundant_index_columns AS redundant_columns,
  r.dominant_index_name     AS dominant_index,
  r.dominant_index_columns  AS dominant_columns,
  ROUND(t.bytes / 1024 / 1024, 1) AS table_size_mb,
  r.sql_drop_index          AS suggested_drop
FROM sys.schema_redundant_indexes r
JOIN (
  SELECT TABLE_SCHEMA, TABLE_NAME,
         IFNULL(DATA_LENGTH, 0) + IFNULL(INDEX_LENGTH, 0) AS bytes
  FROM information_schema.TABLES
  WHERE TABLE_TYPE = 'BASE TABLE'
) t ON t.TABLE_SCHEMA = r.table_schema AND t.TABLE_NAME = r.table_name
WHERE r.redundant_index_non_unique = 1
  AND r.dominant_index_non_unique = 1
ORDER BY t.bytes DESC
LIMIT 50
