-- @id: non_innodb_table
-- @title: 存在非 InnoDB 引擎的业务表
-- @severity: warn
-- @dimension: risk
-- @scope: schema
-- @object: table
-- @requires: schema_select
-- @exactness: catalog
-- @since: 5.7
-- @remediation: 转成 InnoDB：ALTER TABLE ... ENGINE=InnoDB。MyISAM 没有事务、没有崩溃恢复、只有表级锁，且不支持在线备份——大表上的表锁会直接变成业务故障。
-- @caveats: 系统库（mysql/sys 等）里的 MyISAM 表是 MySQL 自身的实现细节，已排除。老版本升级上来的库常见历史遗留 MyISAM 表，逐个评估迁移成本即可，不必一次性全转。
-- @ref: -
SELECT
  CASE WHEN t.bytes >= 1073741824 THEN 'critical' ELSE 'warn' END AS severity,
  t.TABLE_SCHEMA AS table_schema,
  t.TABLE_NAME   AS table_name,
  t.ENGINE       AS engine,
  t.TABLE_ROWS   AS estimated_rows,
  ROUND(t.bytes / 1024 / 1024, 1) AS size_mb
FROM (
  SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE, TABLE_ROWS,
         (IFNULL(DATA_LENGTH, 0) + IFNULL(INDEX_LENGTH, 0)) AS bytes
  FROM information_schema.TABLES
  WHERE TABLE_TYPE = 'BASE TABLE'
    AND ENGINE IS NOT NULL
    AND ENGINE <> 'InnoDB'
    AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')
) t
ORDER BY t.bytes DESC
