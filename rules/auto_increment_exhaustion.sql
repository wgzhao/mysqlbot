-- @id: auto_increment_exhaustion
-- @title: 自增主键接近类型上限
-- @severity: info
-- @dimension: risk
-- @scope: schema
-- @object: column
-- @requires: schema_select
-- @exactness: catalog
-- @since: 5.7
-- @tags: schema,capacity
-- @remediation: 用 int（上限约 21 亿）做自增主键、且写入速率高的表，跑满只是时间问题，而耗尽之后所有 INSERT 会直接失败（error 1062/1467），属于典型"凌晨炸"的故障。到 70% 就该动手：改成 BIGINT UNSIGNED 需要重建表（ALTER TABLE ... MODIFY，配合 pt-online-schema-change 或 gh-ost 减少锁表时间）。
-- @caveats: 已用"峰值超过类型上限的 50%"作为门槛，低于此不报，避免刷屏。判定依据是 information_schema.TABLES.AUTO_INCREMENT，它可能滞后于真实插入位置（缓存分配），因此百分比是估算。另外 AUTO_INCREMENT 会因为删除最大值、回滚、以及 InnoDB 8.0 之前的计数器不持久化而回退，不要在它上面做精确容量规划。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  CASE WHEN x.used_pct >= 90 THEN 'critical' ELSE 'warn' END AS severity,
  x.TABLE_SCHEMA    AS table_schema,
  x.TABLE_NAME      AS table_name,
  x.COLUMN_NAME     AS column_name,
  x.COLUMN_TYPE     AS column_type,
  x.AUTO_INCREMENT  AS current_auto_increment,
  x.max_val         AS type_max_value,
  ROUND(x.used_pct, 2) AS used_pct
FROM (
  SELECT
    t.TABLE_SCHEMA,
    t.TABLE_NAME,
    c.COLUMN_NAME,
    c.COLUMN_TYPE,
    t.AUTO_INCREMENT,
    CASE
      WHEN c.DATA_TYPE = 'tinyint'   THEN IF(c.COLUMN_TYPE LIKE '%unsigned%', 255, 127)
      WHEN c.DATA_TYPE = 'smallint'  THEN IF(c.COLUMN_TYPE LIKE '%unsigned%', 65535, 32767)
      WHEN c.DATA_TYPE = 'mediumint' THEN IF(c.COLUMN_TYPE LIKE '%unsigned%', 16777215, 8388607)
      WHEN c.DATA_TYPE = 'int'       THEN IF(c.COLUMN_TYPE LIKE '%unsigned%', 4294967295, 2147483647)
      WHEN c.DATA_TYPE = 'bigint'    THEN IF(c.COLUMN_TYPE LIKE '%unsigned%', 18446744073709551615, 9223372036854775807)
    END AS max_val,
    100 * t.AUTO_INCREMENT /
      CASE
        WHEN c.DATA_TYPE = 'tinyint'   THEN IF(c.COLUMN_TYPE LIKE '%unsigned%', 255, 127)
        WHEN c.DATA_TYPE = 'smallint'  THEN IF(c.COLUMN_TYPE LIKE '%unsigned%', 65535, 32767)
        WHEN c.DATA_TYPE = 'mediumint' THEN IF(c.COLUMN_TYPE LIKE '%unsigned%', 16777215, 8388607)
        WHEN c.DATA_TYPE = 'int'       THEN IF(c.COLUMN_TYPE LIKE '%unsigned%', 4294967295, 2147483647)
        WHEN c.DATA_TYPE = 'bigint'    THEN IF(c.COLUMN_TYPE LIKE '%unsigned%', 18446744073709551615, 9223372036854775807)
      END AS used_pct
  FROM information_schema.TABLES t
  JOIN information_schema.COLUMNS c
    ON c.TABLE_SCHEMA = t.TABLE_SCHEMA
   AND c.TABLE_NAME   = t.TABLE_NAME
   AND c.EXTRA LIKE '%auto_increment%'
  WHERE t.TABLE_TYPE = 'BASE TABLE'
    AND t.AUTO_INCREMENT IS NOT NULL
    AND t.AUTO_INCREMENT > 1
    AND t.TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
) x
WHERE x.max_val IS NOT NULL
  AND x.used_pct >= 50
ORDER BY x.used_pct DESC
LIMIT 50
