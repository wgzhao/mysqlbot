-- @id: stats_expiry_too_long
-- @title: 表统计信息使用缓存的过期值（information_schema_stats_expiry > 0）
-- @severity: warn
-- @dimension: hygiene
-- @scope: instance
-- @object: setting:information_schema_stats_expiry
-- @requires: -
-- @exactness: exact
-- @since: 8.0
-- @tags: statistics,optimizer
-- @remediation: 设为 0（动态生效，全局与会话均可）。这个参数从 8.0 引入、默认 86400 秒，含义是：从 information_schema.TABLES / STATISTICS 读到的 TABLE_ROWS、DATA_LENGTH、CARDINALITY 等统计值，允许返回最多 24 小时前的缓存快照，而不是去存储引擎现取。后果有两层——**对监控是致命的**：任何"表多大、多少行、索引基数多少"的判断都可能基于一天前的数据，报出来的容量与倾斜结论直接是错的；**对业务影响较小**：优化器走的是自己的统计信息路径，不读这个缓存。
-- @caveats: 读的是 @@GLOBAL——本工具的巡检会话会把该变量强制置 0，若读会话值就会永远看不到这个问题。设成 0 之后，每次查询 information_schema 的统计列都会触发一次存储引擎采样，在表非常多（上万张）的实例上会带来可感知的开销；此时折中方案是设一个短周期（如 60 秒）而不是 0。本工具在跑规则前会在会话里强制置 0，所以 mysqlbot 自己的结论不受影响——这条规则针对的是"你手工查 information_schema 时会被它骗到"。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  CASE WHEN @@GLOBAL.information_schema_stats_expiry >= 86400 THEN 'warn' ELSE 'info' END AS severity,
  'information_schema_stats_expiry'                        AS variable_name,
  @@GLOBAL.information_schema_stats_expiry                 AS current_seconds,
  ROUND(@@GLOBAL.information_schema_stats_expiry / 3600, 1) AS current_hours,
  '0'                                                      AS suggested_seconds,
  'mysqlbot 巡检时会话级强制置 0'                            AS mitigation
FROM DUAL
WHERE @@GLOBAL.information_schema_stats_expiry > 0
