-- @id: innodb_file_per_table_off
-- @title: 未使用独立表空间（innodb_file_per_table=OFF）
-- @severity: warn
-- @dimension: capacity
-- @scope: instance
-- @object: setting:innodb_file_per_table
-- @requires: -
-- @exactness: exact
-- @since: 5.7
-- @tags: innodb,capacity
-- @remediation: 改为 ON（动态生效，只影响之后新建/重建的表）。关闭时所有 InnoDB 表共用 ibdata1：**DROP TABLE 不会把空间还给操作系统**——删掉 500GB 的表，磁盘占用一点不减，只能靠导出重建整个实例来回收。打开后每表一个 .ibd 文件，DROP/TRUNCATE 即可释放，且支持单表压缩与单表传输。
-- @caveats: 改成 ON 之后，已有的表**仍留在 ibdata1 里**，需要 ALTER TABLE ... ENGINE=InnoDB（或 pt-online-schema-change）逐表重建才会迁出。这个重建过程对大实例是重活，要分批做并监控磁盘余量。另外 ibdata1 不会自动缩小，通常需要重建实例才能真正回收。
-- @ref: -
--
-- 规则契约：返回 0 行为未命中；返回行即命中，每行必须含 severity 列。
SELECT
  'warn'                    AS severity,
  'innodb_file_per_table'   AS variable_name,
  @@innodb_file_per_table   AS current_value,
  'ON'                      AS suggested_value,
  '已有表需 ALTER TABLE ... ENGINE=InnoDB 才会迁出 ibdata1' AS note
FROM DUAL
WHERE @@innodb_file_per_table = 0
