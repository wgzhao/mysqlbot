-- @id: statement_high_total_latency
-- @title: 累计耗时最高的语句（按 digest 排序）
-- @severity: info
-- @dimension: latency
-- @scope: workload
-- @object: statement
-- @requires: p_s_statements
-- @exactness: cumulative
-- @since: 5.7
-- @tags: sql,top-n
-- @remediation: 这是"总时间"榜而不是"单次"榜：一条 5ms 的语句跑 100 万次，比一条 3s 的语句跑 10 次更值得先优化。先确认它是否高频且可以缓存/合并，再看执行计划能否降低单次成本。
-- @caveats: SUM_TIMER_WAIT 单位是皮秒。已过滤系统 schema 与 digest 为空的汇总行。P_S 只保留受 performance_schema_digests_size 限制的 top 语句，超出的会汇总到 digest='' 行——所以这里看到的是"P_S 认为的 top"，不是绝对 top。CPU 时间列需要 performance_schema 的 CPU 计时 consumer。样本列取 DIGEST_TEXT 而非 QUERY_SAMPLE_TEXT（后者是 8.0.22+ 才有，用它会让本规则在 5.7 上报 1054）。
-- @ref: pgbot/slow_queries
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  CASE WHEN ROUND(d.AVG_TIMER_WAIT / 1e9, 2) >= 500 OR d.SUM_TIMER_WAIT >= 600e12
       THEN 'warn' ELSE 'info' END                       AS severity,
  d.SCHEMA_NAME                                          AS db,
  ROUND(d.SUM_TIMER_WAIT / 1e12, 2)                      AS total_seconds,
  ROUND(d.AVG_TIMER_WAIT / 1e9, 2)                       AS avg_ms,
  ROUND(d.MAX_TIMER_WAIT / 1e12, 3)                      AS max_seconds,
  d.COUNT_STAR                                           AS exec_count,
  d.SUM_ROWS_EXAMINED                                    AS rows_examined_total,
  d.SUM_CREATED_TMP_DISK_TABLES                          AS tmp_disk_tables,
  d.SUM_SORT_MERGE_PASSES                                AS sort_merge_passes,
  LEFT(d.DIGEST_TEXT, 160)                               AS query_sample,
  d.DIGEST                                               AS digest
FROM performance_schema.events_statements_summary_by_digest d
WHERE d.DIGEST_TEXT IS NOT NULL
  AND d.DIGEST <> ''
  AND d.SCHEMA_NAME IS NOT NULL
  AND d.SCHEMA_NAME NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
  AND d.COUNT_STAR >= 100
  AND d.SUM_TIMER_WAIT >= 10e12
ORDER BY d.SUM_TIMER_WAIT DESC
LIMIT 10
