-- @id: unused_index
-- @title: 长期未被任何语句使用的索引
-- @severity: info
-- @dimension: hygiene
-- @scope: schema
-- @object: index
-- @requires: p_s_waits,schema_select,sys_indexes
-- @exactness: sampled
-- @since: 5.7
-- @min_uptime: 259200
-- @tags: index,schema
-- @remediation: 候选删除对象来自 sys.schema_unused_indexes，它统计的是 performance_schema 的索引 IO 计数——只要实例运行期间该索引没被读过就进榜。删掉可以省空间、减小写入放大。删之前用业务高峰 + 月末/季末这类周期性查询覆盖一遍，避免删掉低频但关键的索引。
-- @caveats: 这类结论天然不可靠，三点必须知道：①计数器随实例重启清零，所以已用 Uptime >= 3 天做门禁，运行时间不足时本规则不产出任何行（那是"看不到"，不是"没有"）；②唯一索引被排除，删掉它们会丢约束；③服务于外键的索引删不掉（InnoDB 会拒绝）。周期性报表类查询如果本次统计窗口内没跑过，其索引会被误判为无用。
-- @ref: pgbot/unused_indexes
-- @safety: DROP INDEX
-- @safety_note: 证据列 suggested_drop 是可执行的 DROP INDEX 语句。执行前请确认该索引不被低频查询与外键依赖。
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  CASE WHEN t.bytes >= 1073741824 THEN 'warn' ELSE 'info' END AS severity,
  u.object_schema AS table_schema,
  u.object_name   AS table_name,
  u.index_name    AS unused_index,
  s.columns       AS index_columns,
  t.rows_est      AS estimated_rows,
  ROUND(t.bytes / 1024 / 1024, 1) AS table_size_mb,
  up.uptime_s     AS uptime_s,
  CONCAT('ALTER TABLE `', u.object_schema, '`.`', u.object_name,
         '` DROP INDEX `', u.index_name, '`') AS suggested_drop
FROM sys.schema_unused_indexes u
JOIN (
  SELECT TABLE_SCHEMA, TABLE_NAME, MAX(TABLE_ROWS) AS rows_est,
         IFNULL(MAX(DATA_LENGTH), 0) + IFNULL(MAX(INDEX_LENGTH), 0) AS bytes
  FROM information_schema.TABLES
  WHERE TABLE_TYPE = 'BASE TABLE' AND ENGINE = 'InnoDB'
  GROUP BY TABLE_SCHEMA, TABLE_NAME
) t ON t.TABLE_SCHEMA = u.object_schema AND t.TABLE_NAME = u.object_name
JOIN (
  SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME,
         GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS columns,
         MIN(NON_UNIQUE) AS non_unique
  FROM information_schema.STATISTICS
  GROUP BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME
) s ON s.TABLE_SCHEMA = u.object_schema AND s.TABLE_NAME = u.object_name AND s.INDEX_NAME = u.index_name
CROSS JOIN (
  SELECT CAST(MAX(CASE WHEN VARIABLE_NAME = 'Uptime' THEN VARIABLE_VALUE END) AS DECIMAL(30,0)) AS uptime_s
  FROM performance_schema.global_status
) up
WHERE s.non_unique = 1
  AND t.bytes >= 10485760
ORDER BY t.bytes DESC
LIMIT 50
