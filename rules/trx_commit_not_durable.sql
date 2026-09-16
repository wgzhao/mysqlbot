-- @id: trx_commit_not_durable
-- @title: 提交不落盘（innodb_flush_log_at_trx_commit 非 1）
-- @severity: warn
-- @dimension: risk
-- @scope: instance
-- @object: setting:innodb_flush_log_at_trx_commit
-- @requires: -
-- @exactness: exact
-- @since: 5.7
-- @tags: durability,safety
-- @remediation: 值 1 表示每次提交都写 redo 并 fsync，是唯一能保证"提交即持久"的设置。值 2 只写到 OS 缓存，MySQL 进程崩溃不丢数据但操作系统/断电会丢；值 0 连 OS 缓存都不保证，任何崩溃都可能丢最近 1 秒的已提交事务，而且**返回给客户端的 commit 成功是假的**。金融/交易类库必须设为 1；只为压测提速而设 0/2 的实例，请确认它不被当作可靠存储使用。
-- @caveats: 这是明确的取舍而非缺陷：大批量导入、离线分析库、可重建的数据仓库常常刻意用 0/2 换取写入吞吐。判定前先确认这台实例承载的业务是否允许丢数据——本规则不做这个判断，只把事实摆出来。顺序上有依赖：若 sync_binlog 也非 1，则复制环境下的数据丢失窗口会进一步放大。
-- @ref: -
--
-- 用 @@变量 直读而不是查 information_schema：后者在 MySQL 8.4 已被移除
-- （GLOBAL_VARIABLES 表不存在），@@ 读取则在 5.7–9.x 全程可用且不需要任何权限。
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  CASE WHEN @@innodb_flush_log_at_trx_commit = 0 THEN 'critical' ELSE 'warn' END AS severity,
  'innodb_flush_log_at_trx_commit'                           AS variable_name,
  @@innodb_flush_log_at_trx_commit                           AS current_value,
  '1'                                                        AS suggested_value,
  CASE @@innodb_flush_log_at_trx_commit
    WHEN 0 THEN '每秒才写 redo 日志：进程崩溃即可能丢失最近约 1 秒的已提交事务'
    WHEN 2 THEN '每次提交写 OS 缓存、每秒 fsync：操作系统崩溃或断电可能丢失最近约 1 秒的已提交事务'
    ELSE '未知取值'
  END                                                        AS risk_description
FROM DUAL
WHERE @@innodb_flush_log_at_trx_commit <> 1
