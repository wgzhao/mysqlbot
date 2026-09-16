-- ============================================================================
--  自测夹具 2/3：灌数据（跨过各规则的数据量门禁）
--  ⚠️ 只允许在一次性实例上执行
-- ============================================================================
USE mysqlbot_test;

-- 递归 CTE 默认上限 1000，灌 20 万行要放开
SET SESSION cte_max_recursion_depth = 400000;

-- 无主键表灌到 ~200k 行 / 约 50MB：
--   ① 跨过 table_without_primary_key 的 1MB 门禁
--   ② 构成可观工作集，让 32MB 缓冲池产生真实的磁盘读（buffer_pool_hit_low）
--   ③ 作为全表扫描风暴的靶子
INSERT INTO nopk_big (ts, actor, action, payload)
WITH RECURSIVE seq(n) AS (
  SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 200000
)
SELECT NOW() - INTERVAL n SECOND,
       CONCAT('actor_', n % 500),
       'evt',
       CONCAT(REPEAT('x', 170), LPAD(n, 8, '0'))
FROM seq;

INSERT INTO myisam_tbl (id, cnt) VALUES (1, 10), (2, 20), (3, 30);

INSERT INTO dup_idx (user_id)
WITH RECURSIVE seq(n) AS (
  SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 5000
)
SELECT n % 100 FROM seq;

-- 20000 行同一取值 → 索引基数 1，但表远大于 10000 行门禁
INSERT INTO same_value (flag)
WITH RECURSIVE seq(n) AS (
  SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 20000
)
SELECT 1 FROM seq;

ANALYZE TABLE nopk_big, myisam_tbl, dup_idx, same_value, int_autoinc, lock_target;

SELECT '夹具数据已就绪' AS status,
       (SELECT COUNT(*) FROM nopk_big)   AS nopk_big_rows,
       (SELECT COUNT(*) FROM same_value) AS same_value_rows;
