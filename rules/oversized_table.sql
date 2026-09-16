-- @id: oversized_table
-- @title: 单表体积过大（归档/分区候选）
-- @severity: info
-- @dimension: capacity
-- @scope: schema
-- @object: table
-- @requires: schema_select
-- @exactness: catalog
-- @since: 5.7
-- @tags: capacity,schema
-- @remediation: 单表超过 50GB 后，DDL、备份、误删恢复的代价都会陡增。先确认它是否按时间增长：如果是流水/日志类表，按时间分区或定期归档到历史库是最有效的办法。若必须保留在线，至少把索引瘦身（见 redundant_index / unused_index），并确认 innodb_file_per_table=ON 便于单独回收空间。
-- @caveats: 这是阈值型信号，不是缺陷——有些业务表本来就应该很大（订单主表、用户表），这类情况应把规则加入 skip 列表，而不是去拆表。表大小读的是 information_schema 的统计值，InnoDB 的 DATA_LENGTH 是页数估算，存在偏差；本工具已把 information_schema_stats_expiry 设为 0 以保证新鲜度。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  CASE WHEN t.bytes >= 53687091200 THEN 'warn' ELSE 'info' END AS severity,
  t.TABLE_SCHEMA AS table_schema,
  t.TABLE_NAME   AS table_name,
  t.ENGINE       AS engine,
  t.TABLE_ROWS   AS estimated_rows,
  ROUND(t.data_bytes / 1024 / 1024 / 1024, 2)  AS data_gb,
  ROUND(t.index_bytes / 1024 / 1024 / 1024, 2) AS index_gb,
  ROUND(t.bytes / 1024 / 1024 / 1024, 2)       AS total_gb,
  ROUND(100 * t.index_bytes / NULLIF(t.bytes, 0), 1) AS index_pct,
  ROUND(t.bytes / NULLIF(t.TABLE_ROWS, 0), 0)  AS avg_row_bytes
FROM (
  SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE, TABLE_ROWS,
         IFNULL(DATA_LENGTH, 0)  AS data_bytes,
         IFNULL(INDEX_LENGTH, 0) AS index_bytes,
         IFNULL(DATA_LENGTH, 0) + IFNULL(INDEX_LENGTH, 0) AS bytes
  FROM information_schema.TABLES
  WHERE TABLE_TYPE = 'BASE TABLE'
    AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
) t
WHERE t.bytes >= 10737418240
ORDER BY t.bytes DESC
LIMIT 50
