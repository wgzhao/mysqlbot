-- @id: slow_query_log_off
-- @title: 慢查询日志未开启
-- @severity: warn
-- @dimension: hygiene
-- @scope: instance
-- @object: setting:slow_query_log
-- @requires: -
-- @exactness: exact
-- @since: 5.7
-- @tags: observability,sql
-- @remediation: 打开 slow_query_log（动态生效），并把 log_output 设为 FILE 或 TABLE。慢日志是事后定位"昨晚那波卡顿是谁造成的"唯一可靠的证据来源——P_S 的语句摘要只看得到统计聚合，看不到具体时刻和具体值。生产环境建议同时配上 log_slow_admin_statements 与 log_slow_extra 以补全元信息。
-- @caveats: P_S 的 events_statements_summary_by_digest 能在一定程度上替代慢日志（本工具的其他规则就依赖它），所以"慢日志关闭"不等于"完全瞎"；但对需要精确复现单次问题的场景，慢日志不可替代。容器化部署时常把日志写到不受采集的路径，若已开启但从未被采集，本规则不会发现——它只检查开关。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  'warn'             AS severity,
  'slow_query_log'   AS variable_name,
  @@slow_query_log   AS current_value,
  'ON'               AS suggested_value,
  @@long_query_time  AS long_query_time,
  @@log_output       AS log_output
FROM DUAL
WHERE @@slow_query_log = 0
