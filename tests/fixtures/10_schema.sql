-- ============================================================================
--  自测夹具 1/3：植入结构性违规
--  ⚠️ 只允许在一次性实例上执行（会 DROP DATABASE mysqlbot_test）
-- ============================================================================

DROP DATABASE IF EXISTS mysqlbot_test;
CREATE DATABASE mysqlbot_test DEFAULT CHARACTER SET utf8mb4;
USE mysqlbot_test;

-- 1) 无主键 InnoDB 表
--    期望命中：table_without_primary_key（数据由 20_load.sql 灌到 1MB 以上）
CREATE TABLE nopk_big (
  ts      DATETIME,
  actor   VARCHAR(64),
  action  VARCHAR(32),
  payload VARCHAR(255)
) ENGINE=InnoDB;

-- 2) 非 InnoDB 表
--    期望命中：non_innodb_table
CREATE TABLE myisam_tbl (
  id  INT NOT NULL PRIMARY KEY,
  cnt INT
) ENGINE=MyISAM;

-- 3) 冗余索引：idx_user_dup 被 idx_user 完全覆盖
--    期望命中：redundant_index
CREATE TABLE dup_idx (
  id      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  user_id BIGINT UNSIGNED NOT NULL,
  KEY idx_user (user_id),
  KEY idx_user_dup (user_id)
) ENGINE=InnoDB;

-- 4) 自增主键逼近 INT 上限（1500000000 / 2147483647 ≈ 70%）
--    期望命中：auto_increment_exhaustion
CREATE TABLE int_autoinc (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  v  INT
) ENGINE=InnoDB;
ALTER TABLE int_autoinc AUTO_INCREMENT = 1500000000;

-- 5) 索引基数失真：20000 行全部同值，ANALYZE 后基数仍是 1
--    期望命中：stale_index_statistics
CREATE TABLE same_value (
  id   INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  flag TINYINT NOT NULL,
  KEY idx_flag (flag)
) ENGINE=InnoDB;

-- 6) 锁靶子表：供 blocking_chains / metadata_lock_wait / idle_in_transaction
CREATE TABLE lock_target (
  id INT NOT NULL PRIMARY KEY,
  v  INT NOT NULL
) ENGINE=InnoDB;
INSERT INTO lock_target (id, v) VALUES (1, 0);
