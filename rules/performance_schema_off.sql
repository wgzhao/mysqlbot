-- @id: performance_schema_off
-- @title: performance_schema 未启用（丧失全部内建观测能力）
-- @severity: warn
-- @dimension: hygiene
-- @scope: instance
-- @object: setting:performance_schema
-- @requires: -
-- @exactness: exact
-- @since: 5.7
-- @tags: observability
-- @remediation: 设为 ON 并重启。这不是"可选特性"：语句摘要、等待事件、索引使用统计、元数据锁与 data_locks——所有"哪条 SQL 慢、哪个索引没被用、谁锁住了谁"的证据链都在这里。关掉它之后，MySQL 只剩 SHOW STATUS 里那些粗粒度累计计数器，故障排查只能靠猜。
-- @caveats: 该参数**不能**动态修改，必须重启实例——这是本规则为 warn 而不是 critical 的原因（无法立即处置）。P_S 开着的代价是少量 CPU 与内存（默认可接受），高并发短查询场景可通过关闭部分 consumer/instrument 来降开销，而不必整个关掉。注意：P_S 关闭时本工具的其他 P_S 依赖规则会全部被跳过并在报告里逐条列出，不会静默给出"干净"结论。本规则用 @@performance_schema 判断，而不是去读 performance_schema 自己——关了就读不到了。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  'warn'                AS severity,
  'performance_schema'  AS variable_name,
  @@performance_schema  AS current_value,
  'ON'                  AS suggested_value,
  '需要重启实例生效'      AS note
FROM DUAL
WHERE @@performance_schema = 0
