-- @id: full_table_scan_heavy
-- @title: 存在大量不走索引的语句（全表扫描放大）
-- @severity: info
-- @dimension: latency
-- @scope: workload
-- @object: statement
-- @requires: p_s_statements
-- @exactness: cumulative
-- @since: 5.7
-- @tags: index,sql
-- @remediation: 按 digest 拿到样本 SQL 后，重点看两件事：WHERE 列有没有索引、以及索引是否因为隐式类型转换（列是 varchar 却比数字）而失效。扫描行数极大而返回行数极小，是最典型的"缺索引"信号。
-- @caveats: 直接读 events_statements_summary_by_digest 而不是 sys 视图，是为了拿到精确的数值列——sys 视图里的 *_latency 是格式化字符串，按它排序会得到错误的名次。digest 表在 P_S 启动后才有数据，刚重启的实例这里会是空的（此时报"干净"是假干净）。语句摘要受 performance_schema_digests_size 限制，超限语句会归到 digest='' 的汇总行，本规则已排除该行。样本列取 DIGEST_TEXT 而非 QUERY_SAMPLE_TEXT：后者是 8.0.22 才加的列，用它会让本规则在 5.7 上直接报 1054；DIGEST_TEXT 从 5.7 起一直存在，跨版本可用。代价是拿到的是参数已被 `?` 替换的规范化文本，看不到字面值——需要字面值时按 digest 去 P_S 或慢日志里捞。
-- @ref: pgbot/seq_scan_heavy
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  CASE WHEN (100 * d.SUM_NO_INDEX_USED / NULLIF(d.COUNT_STAR, 0)) >= 90 THEN 'warn' ELSE 'info' END AS severity,
  d.SCHEMA_NAME                                   AS db,
  d.COUNT_STAR                                    AS exec_count,
  d.SUM_NO_INDEX_USED                              AS no_index_used,
  ROUND(100 * d.SUM_NO_INDEX_USED / NULLIF(d.COUNT_STAR, 0), 1) AS no_index_pct,
  ROUND(d.SUM_ROWS_EXAMINED / NULLIF(d.COUNT_STAR, 0), 0)       AS rows_examined_avg,
  ROUND(d.SUM_ROWS_SENT / NULLIF(d.COUNT_STAR, 0), 0)           AS rows_sent_avg,
  d.SUM_ROWS_EXAMINED                                          AS rows_examined_total,
  LEFT(d.DIGEST_TEXT, 160)                                      AS query_sample,
  d.DIGEST                                                     AS digest
FROM performance_schema.events_statements_summary_by_digest d
WHERE d.DIGEST_TEXT IS NOT NULL
  AND d.DIGEST <> ''
  AND d.SCHEMA_NAME IS NOT NULL
  AND d.SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  AND d.COUNT_STAR >= 10
  AND d.SUM_NO_INDEX_USED > 0
  AND d.SUM_ROWS_EXAMINED >= 100000
ORDER BY d.SUM_ROWS_EXAMINED DESC
LIMIT 10
