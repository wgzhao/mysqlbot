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
--
--  ============================================================================
--  【权限模型实测结论】MySQL 8.0.43，用业务账号逐表验证过，不要凭印象改：
--
--    无需任何授权即可读 : performance_schema.global_status / global_variables
--    PROCESS 即可读     : information_schema.INNODB_TRX / INNODB_METRICS
--                         information_schema.PROCESSLIST（全量会话）
--    必须显式 GRANT     : performance_schema 的其余表
--                         （threads / data_locks / metadata_locks /
--                           events_statements_summary_by_digest /
--                           table_io_waits_summary_by_index_usage /
--                           memory_summary_global_by_event_name / replication_*）
--                         → 只给 PROCESS 是不够的，会拿到 ERROR 1142
--    必须显式 GRANT     : sys.*  （视图是 SQL SECURITY INVOKER，见下方说明）
--    按 schema 过滤     : information_schema.TABLES / STATISTICS / COLUMNS
--                         （只对授了 SELECT 的库可见）
--
--  ★ 常见踩坑：以为 "PROCESS 就够了"。PROCESS 只解决 InnoDB 视图与 PROCESSLIST，
--    P_S 的锁表、MDL 表、语句摘要是**另一套权限**。少了它们，blocking_chains /
--    metadata_lock_wait / full_table_scan_heavy / statement_high_total_latency /
--    unused_index 这 5 条会整条被跳过——不是"没问题"，是"没检查"。
--
--  【5.7 与 8.0/8.4 的差异】同一份脚本在 5.7 上的表现不同，不是授权写错了：
--    * 5.7 **没有** performance_schema.data_locks —— 能力位 p_s_locks 在 5.7 上
--      必然是 false，再怎么授权也开不了。这是版本差异：5.7 的锁信息在
--      information_schema.INNODB_LOCKS / INNODB_LOCK_WAITS 里，只需要 PROCESS。
--      对应规则是 blocking_chains_57（@removed_in: 8.0），与 8.0+ 的
--      blocking_chains 互斥，不会重复报。
--    * 5.7 **有** performance_schema.metadata_locks（自 5.7.3 起），
--      metadata_lock_wait 在 5.7 上同样可用。
--    * 5.7 **没有** information_schema_stats_expiry —— 表统计本来就是实时算的，
--      不存在缓存过期问题，stats_expiry_too_long 会被版本门禁跳过（正常）。
--  ============================================================================


-- ============================================================================
--  A 档：零数据访问（推荐起步）
--  能看到：性能计数器、锁与等待、语句摘要、事务、复制状态、变量、全部会话
--  看不到：业务表结构与容量 —— 相关规则会被**显式跳过**，不会误报"干净"
--  A 档不含任何一行业务数据的读权限。
-- ============================================================================
CREATE USER IF NOT EXISTS 'mbot_reader'@'%' IDENTIFIED BY 'CHANGE_ME_STRONG_PASSWORD';

-- PROCESS：读 information_schema.INNODB_TRX / INNODB_METRICS，以及看到全量
--          PROCESSLIST（否则只能看到自己的会话）。是判断长事务、空闲事务、
--          undo history 长度的前提。
GRANT PROCESS ON *.* TO 'mbot_reader'@'%';

-- REPLICATION CLIENT：读 performance_schema.replication_* 与 SHOW REPLICA STATUS。
--          缺它则 3 条复制类规则（replication_stopped / replication_io_error /
--          replica_writable）被跳过。不涉及任何数据读取。
GRANT REPLICATION CLIENT ON *.* TO 'mbot_reader'@'%';

-- performance_schema：**必须显式授权**。缺它会被跳过的规则：
--          p_s_locks    → blocking_chains
--          p_s_mdl      → metadata_lock_wait
--          p_s_statements → full_table_scan_heavy, statement_high_total_latency
--          p_s_waits    → unused_index
--          p_s_memory   → （当前无规则依赖，预留给内存类发现）
--          这些表里只有 SQL 文本摘要、对象名、计数与锁信息，**不含业务行数据**。
GRANT SELECT ON `performance_schema`.* TO 'mbot_reader'@'%';

-- sys：只给 SELECT 就够**一部分**视图用，这是实测结论而非推测：
--   * sys 的视图是 SQL SECURITY **INVOKER**（不是 DEFINER），所以它底层引用的
--     performance_schema 表、以及它调用的 sys 函数，都要调用者自己有权。
--   * sys 函数（format_time / format_statement / format_bytes ...）的 DEFINER 是
--     mysql.sys@localhost，该账号只有 USAGE —— 调用者必须额外拿到 EXECUTE。
--   * 本工具的设计选择是：**核心发现一律直读 performance_schema，不依赖 sys 的
--     格式化视图**，因此不需要 EXECUTE。只有两个 sys 视图被保留依赖
--     （schema_redundant_indexes / schema_unused_indexes，实测在
--     "SELECT ON performance_schema.* + SELECT ON sys.*" 下可读，
--     且实现了不值得自己重写的判定算法）。
GRANT SELECT ON `sys`.* TO 'mbot_reader'@'%';

-- 明确不给：INSERT / UPDATE / DELETE / CREATE / DROP / ALTER / SUPER / FILE / SHUTDOWN
-- 也不需要 EXECUTE —— 理由见上面 sys 那段。
-- mysqlbot 用不到其中任何一项。若你的合规要求更严，可再加：
--   REVOKE ALL PRIVILEGES ON *.* FROM 'mbot_reader'@'%';  然后只重新 GRANT 上面四项。

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
-- B-2 是**受支持**的：工具会逐行解析 SHOW GRANTS，识别出"哪些库可读"，
-- 并把这份清单放进报告的 `visible_schemas`。information_schema 本身按权限过滤，
-- 所以规则天然只会覆盖到这些库——没授权的库不会被检查，也不会误报干净。
-- 报告里会带一条 note 明确写出覆盖范围，汇报时请把这句话一起讲出去。


-- ============================================================================
--  验证：授权后跑一次自检，确认能力位与预期一致
-- ============================================================================
--   mbot doctor --host <host> --port <port> -u mbot_reader -p
--   mbot probe  --host <host> --port <port> -u mbot_reader -p | jq '.flags, .visible_schemas'
--
--   期望（A 档）：p_s / p_s_statements / p_s_waits / p_s_mdl / p_s_locks /
--                 sys / sys_indexes / sys_functions / process / replication
--                 全部 true
--                 schema_select = false，visible_schemas = []
--   期望（B 档）：以上全部 true，且 visible_schemas 列出被授权的库
--
--   ⚠️ 在 MySQL 5.7 上 p_s_locks 会是 false —— 5.7 没有 data_locks 表，
--      这不是授权问题（见上方【5.7 与 8.0/8.4 的差异】）。
--
--   任何一项为 false 都会在报告里表现为对应规则的**跳过**（附原因），
--   而不是"检查过、没问题"。汇报时务必把跳过项一起说。


-- ============================================================================
--  附：确认账号确实是只读（应当全部返回 N）
-- ============================================================================
-- SELECT
--   SUM(IF(PRIVILEGE_TYPE IN ('SELECT','PROCESS','REPLICATION CLIENT'), 1, 0)) AS allowed,
--   SUM(IF(PRIVILEGE_TYPE IN ('INSERT','UPDATE','DELETE','CREATE','DROP','ALTER',
--                             'SUPER','FILE','SHUTDOWN','GRANT OPTION','CREATE USER'), 1, 0)) AS forbidden
-- FROM information_schema.USER_PRIVILEGES
-- WHERE GRANTEE = "'mbot_reader'@'%'";
