-- @id: long_query_time_high
-- @title: 慢查询阈值过高（会漏掉大部分值得看的语句）
-- @severity: info
-- @dimension: hygiene
-- @scope: instance
-- @object: setting:long_query_time
-- @requires: -
-- @exactness: exact
-- @since: 5.7
-- @tags: observability,sql
-- @remediation: 把 long_query_time 降到 1 秒甚至 0.5 秒。默认 10 秒意味着"低于 10 秒的语句一律不记录"，而 OLTP 场景里真正的问题往往是几千条 0.5~2 秒的语句累积成的。配合 pt-query-digest 或 mysqldumpslow 做聚合，不要直接读原始慢日志。
-- @caveats: 读的是 @@GLOBAL 而不是会话值——业务连接池常常自行 SET SESSION long_query_time，会话值不能代表实例配置。阈值调低会显著增加日志量，请同时规划日志轮转（logrotate），否则慢日志本身会成为磁盘隐患。分析型/报表型实例用 10 秒甚至更长是合理的，这类实例请把本规则加入 skip。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  CASE WHEN @@GLOBAL.long_query_time >= 5 THEN 'warn' ELSE 'info' END AS severity,
  'long_query_time'            AS variable_name,
  @@GLOBAL.long_query_time     AS current_seconds,
  '1'                          AS suggested_seconds,
  @@GLOBAL.slow_query_log      AS slow_query_log
FROM DUAL
WHERE @@GLOBAL.long_query_time >= 2
