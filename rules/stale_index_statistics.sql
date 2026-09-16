-- @id: stale_index_statistics
-- @title: 索引统计信息失真（基数为 1 但表很大）
-- @severity: info
-- @dimension: latency
-- @scope: schema
-- @object: index
-- @requires: schema_select
-- @exactness: catalog
-- @since: 5.7
-- @tags: statistics,optimizer
-- @remediation: 基数为 1 意味着优化器认为该索引所有值都相同，会直接放弃它转而全表扫描。执行 ANALYZE TABLE 重新采样。若 ANALYZE 后基数仍然很低，说明数据分布确实倾斜，或该列被函数包住（例如存的是 JSON 片段），此时应考虑改用生成列 + 索引。
-- @caveats: 读的是 information_schema.STATISTICS.CARDINALITY，它本身来自缓存——MySQL 8.0 默认 information_schema_stats_expiry=86400 秒，本工具已在会话里把它设为 0 保证读到实时值；用别的客户端手工跑这条规则时请自己先设置。刚建的表、刚做完大批量导入的表出现低基数是暂时的，不要立刻下结论。CARDINALITY 为 NULL 表示统计信息从未生成过，本规则已把它排除，避免与"未统计"混淆。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  CASE WHEN t.TABLE_ROWS >= 1000000 THEN 'warn' ELSE 'info' END AS severity,
  s.TABLE_SCHEMA AS table_schema,
  s.TABLE_NAME   AS table_name,
  s.INDEX_NAME   AS index_name,
  s.COLUMN_NAME  AS leading_column,
  s.CARDINALITY  AS cardinality,
  t.TABLE_ROWS   AS estimated_rows,
  'ANALYZE TABLE `' || s.TABLE_SCHEMA || '`.`' || s.TABLE_NAME || '`' AS suggested_fix
FROM information_schema.STATISTICS s
JOIN information_schema.TABLES t
  ON t.TABLE_SCHEMA = s.TABLE_SCHEMA
 AND t.TABLE_NAME   = s.TABLE_NAME
 AND t.TABLE_TYPE   = 'BASE TABLE'
WHERE s.SEQ_IN_INDEX = 1
  AND s.CARDINALITY IS NOT NULL
  AND s.CARDINALITY <= 1
  AND s.INDEX_NAME <> 'PRIMARY'
  AND t.TABLE_ROWS >= 10000
  AND t.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
ORDER BY t.TABLE_ROWS DESC
LIMIT 50
