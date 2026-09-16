-- ============================================================================
--  mysqlbot 只读巡检账号 —— 最小权限授权
-- ============================================================================
--  设计原则：只读是**角色**，不是脚本里的开关。mysqlbot 自身没有任何写路径，
--  但要保证这一点，账号也不该有写权限。
--
--  执行前请替换：
--    mbot_reader                  巡检账号名
--    CHANGE_ME_STRONG_PASSWORD    强密码
--    '%'                          来源网段（生产上请收窄到巡检机 IP，如 '<巡检机 IP>'）
--
--  两档授权，按你要覆盖的规则选一档执行。不要两档都执行。
--  ----------------------------------------------------------------------------
--  注意：MySQL **没有** pgbot 里 pg_monitor 那样的"能看全库元信息但碰不到数据"
--  的角色。information_schema 是按权限过滤的——想让巡检账号看到表结构、索引、
--  容量，就必须给它那些 schema 的 SELECT，而那同时也给了它读取**数据**的能力。
--  这是 MySQL 的固有限制，不是本工具的疏忽。A 档是能保住"零数据访问"的版本，
--  代价是结构类规则（无主键表、冗余索引、超大表）会被自动跳过并在报告里列出。
-- ============================================================================


-- ============================================================================
--  A 档：零数据访问（推荐起步）
--  能看到：性能计数器、锁与等待、语句摘要、复制状态、变量
--  看不到：业务表结构与容量 —— 相关规则会被**显式跳过**，不会误报"干净"
-- ============================================================================
CREATE USER IF NOT EXISTS 'mbot_reader'@'%' IDENTIFIED BY 'CHANGE_ME_STRONG_PASSWORD';

-- PROCESS：读 information_schema.INNODB_TRX / INNODB_METRICS、看全量 PROCESSLIST。
--           这是判断长事务、无主事务、undo history 长度的前提。
GRANT PROCESS ON *.* TO 'mbot_reader'@'%';

-- REPLICATION CLIENT：读 performance_schema.replication_* 与 SHOW REPLICA STATUS。
--           缺它则复制类规则被跳过。不涉及任何数据读取。
GRANT REPLICATION CLIENT ON *.* TO 'mbot_reader'@'%';

-- performance_schema 与 sys：
--   * P_S 的读取由 PROCESS 权限满足，无需也不能显式 GRANT（部分版本会报错）。
--   * sys 库只给 SELECT 就够**一部分**视图用，这是实测结论而非推测：
--     sys 的视图是 SQL SECURITY **INVOKER**（不是 DEFINER），所以它底层引用的
--     performance_schema 表、以及它调用的 sys 函数，都要调用者自己有权。
--     而 sys 函数（format_time / format_statement / format_bytes ...）的
--     DEFINER 是 mysql.sys@localhost，该账号只有 USAGE —— 于是调用者必须额外
--     拿到 EXECUTE 才能用那些函数。
--   * 本工具的设计选择是：**核心发现一律直读 performance_schema，不依赖 sys 的
--     格式化视图**，因此不需要 EXECUTE。只有两个 sys 视图被保留依赖
--     （schema_redundant_indexes / schema_unused_indexes，实测在
--     "PROCESS + SELECT ON sys.*" 下可读，且实现了不值得自己重写的判定算法）。
GRANT SELECT ON `sys`.* TO 'mbot_reader'@'%';

-- 明确不给：INSERT / UPDATE / DELETE / CREATE / DROP / ALTER / SUPER / FILE / SHUTDOWN
-- 也不需要 EXECUTE —— 理由见上面 sys 那段。
-- mysqlbot 用不到其中任何一项。若你的合规要求更严，可再加：
--   REVOKE ALL PRIVILEGES ON *.* FROM 'mbot_reader'@'%';  然后只重新 GRANT 上面三项。

FLUSH PRIVILEGES;


-- ============================================================================
--  B 档：完整覆盖（会读数据）
--  在 A 档基础上再给 schema 读取权限，结构类规则才能工作。
--  两种给法，优先选第二种：
-- ============================================================================
-- B-1（覆盖全部 schema，权限等同于"可读全库数据" —— 仅在巡检机本身可信时使用）
-- GRANT SELECT ON *.* TO 'mbot_reader'@'%';
--
-- B-2（推荐：只给需要纳管的具体 schema，逐个列出）
-- GRANT SELECT ON `app_db`.*      TO 'mbot_reader'@'%';
-- GRANT SELECT ON `order_db`.*    TO 'mbot_reader'@'%';
-- GRANT SELECT ON `report_db`.*   TO 'mbot_reader'@'%';
--
-- 注意：B-2 这种"按 schema 授权"的形式，本工具的全局 SELECT 能力位探测**识别
-- 不到**（它只看 SHOW GRANTS 里有没有 `SELECT ... ON *.*`），因此结构类规则仍会
-- 被标为跳过。此时可以显式放行：mbot check --only 'table_without_primary_key,...'
-- 但更稳妥的做法是接受"被跳过"，或者按 B-1 授权并在网络层限制巡检机来源。


-- ============================================================================
--  验证：授权后跑一次自检，确认能力位与预期一致
-- ============================================================================
--   mbot doctor --host <host> --port <port> -u mbot_reader -p
--   mbot probe  --host <host> --port <port> -u mbot_reader -p | jq .flags
--
--   期望（A 档）：p_s / p_s_statements / p_s_waits / p_s_mdl / sys / process /
--                 replication 为 true；schema_select 为 false
--   期望（B 档）：以上全部 true
-- ============================================================================


-- ============================================================================
--  附：确认账号确实是只读（应当全部返回 N）
-- ============================================================================
-- SELECT
--   SUM(IF(PRIVILEGE_TYPE IN ('SELECT','PROCESS','REPLICATION CLIENT'), 1, 0)) AS allowed,
--   SUM(IF(PRIVILEGE_TYPE IN ('INSERT','UPDATE','DELETE','CREATE','DROP','ALTER',
--                             'SUPER','FILE','SHUTDOWN','GRANT OPTION','CREATE USER'), 1, 0)) AS forbidden
-- FROM information_schema.USER_PRIVILEGES
-- WHERE GRANTEE = "'mbot_reader'@'%'";
