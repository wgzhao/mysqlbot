-- @id: buffer_pool_undersized
-- @title: InnoDB 缓冲池小于数据总量
-- @severity: warn
-- @dimension: capacity
-- @scope: schema
-- @object: setting:innodb_buffer_pool_size
-- @requires: p_s,schema_select
-- @exactness: catalog
-- @since: 5.7
-- @remediation: 若为独占数据库实例，缓冲池通常可给到物理内存的 60%~75%；与 Web 服务混布时按实际内存余量分配。目标是把工作集装进内存，而不是把全部数据装进内存。
-- @caveats: 缓冲池小于数据总量本身不一定有问题——只要热数据能装下就行。本规则是"需要进一步确认"的信号，不是结论。数据量小于 1GB 时不应命中。
-- @ref: pgbot/work_mem_low
SELECT
  CASE WHEN raw.ratio < 0.5 THEN 'critical' ELSE 'warn' END AS severity,
  ROUND(raw.pool_bytes / 1024 / 1024 / 1024, 2) AS pool_gb,
  ROUND(raw.data_bytes / 1024 / 1024 / 1024, 2) AS innodb_data_gb,
  ROUND(raw.ratio, 3) AS pool_to_data_ratio
FROM (
  SELECT
    bp.pool_bytes                                          AS pool_bytes,
    d.data_bytes                                           AS data_bytes,
    (bp.pool_bytes / NULLIF(d.data_bytes, 0))               AS ratio
  FROM
    (SELECT CAST(VARIABLE_VALUE AS DECIMAL(30,0)) AS pool_bytes
       FROM performance_schema.global_variables
      WHERE VARIABLE_NAME = 'innodb_buffer_pool_size') bp
  CROSS JOIN
    (SELECT SUM(DATA_LENGTH + INDEX_LENGTH) AS data_bytes
       FROM information_schema.TABLES
      WHERE ENGINE = 'InnoDB'
        AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema', 'performance_schema', 'sys')) d
) raw
WHERE raw.data_bytes > 1073741824
  AND raw.ratio < 1.0
