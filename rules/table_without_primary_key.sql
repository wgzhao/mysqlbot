-- @id: table_without_primary_key
-- @title: InnoDB 表没有主键（也没有等效的唯一非空索引）
-- @severity: warn
-- @dimension: risk
-- @scope: schema
-- @object: table
-- @requires: schema_select
-- @exactness: catalog
-- @since: 5.7
-- @remediation: 补一个自增或业务主键。无主键的 InnoDB 表会隐式生成 6 字节 rowid，且该 rowid 全局共享同一个计数器——高并发插入时这个计数器会成为热点，同时影响复制性能与表空间回收。
-- @caveats: 已排除"存在唯一且所有列都非空"的索引——那种表实际上有聚簇索引，不影响性能。这是 MySQL 特有的坑，PostgreSQL 没有等价问题。信息来自 information_schema，若监控账号无 schema 读权限则看不到任何行（会误报为"干净"，见 probe 的 schema_visibility 能力位）。
-- @ref: -
SELECT
  CASE WHEN t.bytes >= 1073741824 THEN 'warn' ELSE 'info' END AS severity,
  t.TABLE_SCHEMA   AS table_schema,
  t.TABLE_NAME     AS table_name,
  t.TABLE_ROWS     AS estimated_rows,
  ROUND(t.bytes / 1024 / 1024, 1) AS size_mb
FROM (
  SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_ROWS,
         (IFNULL(DATA_LENGTH, 0) + IFNULL(INDEX_LENGTH, 0)) AS bytes
  FROM information_schema.TABLES
  WHERE TABLE_TYPE = 'BASE TABLE'
    AND ENGINE = 'InnoDB'
    AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
) t
WHERE t.bytes >= 1048576
  AND NOT EXISTS (
    SELECT 1 FROM information_schema.TABLE_CONSTRAINTS c
     WHERE c.TABLE_SCHEMA = t.TABLE_SCHEMA
       AND c.TABLE_NAME   = t.TABLE_NAME
       AND c.CONSTRAINT_TYPE = 'PRIMARY KEY')
  AND NOT EXISTS (
    SELECT 1 FROM information_schema.STATISTICS s
     WHERE s.TABLE_SCHEMA = t.TABLE_SCHEMA
       AND s.TABLE_NAME   = t.TABLE_NAME
       AND s.NON_UNIQUE   = 0
       AND NOT EXISTS (
         SELECT 1 FROM information_schema.COLUMNS col
          WHERE col.TABLE_SCHEMA = s.TABLE_SCHEMA
            AND col.TABLE_NAME   = s.TABLE_NAME
            AND col.COLUMN_NAME  = s.COLUMN_NAME
            AND col.IS_NULLABLE  = 'YES'))
ORDER BY t.bytes DESC
