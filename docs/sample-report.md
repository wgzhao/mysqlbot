# mysqlbot 体检报告

> 📄 **这是一份样例报告**，由 `tests/run_tests.sh` 在**一次性沙箱实例**上生成 ——
> 实例里的库、表、配置、锁场景都是自测脚本故意种下的违规，不是真实环境的问题。
> 用途是展示输出的结构与信息密度（命中项、处置建议、误报说明、未覆盖项、能力位）。
>
> 重新生成：`tests/local_instance.sh start && tests/run_tests.sh`。

- 目标：`mysqlbot-selftest-fixture`  ·  MySQL 8.4.11（Homebrew）
- 账号：`mbot_reader@%`
- 生成时间：2026-09-16 14:26:44
- 结论：**CRITICAL** — 命中 17 / 干净 23 / 跳过 1 / 失败 0

## 命中项

| 严重度 | 规则 | 维度 | 对象 | 行数 | 说明 |
|---|---|---|---|---|---|
| CRIT | `tmp_table_disk_spill` | latency | setting:tmp_table_size | 1 | 临时表大量落盘 |
| WARN | `auto_increment_exhaustion` | risk | column | 1 | 自增主键接近类型上限 |
| WARN | `binlog_retention_unbounded` | capacity | setting:binlog_expire_logs_seconds | 1 | binlog 永不自动清理（存在撑满磁盘的风险） |
| WARN | `full_table_scan_heavy` | latency | statement | 3 | 存在大量不走索引的语句（全表扫描放大） |
| WARN | `innodb_file_per_table_off` | capacity | setting:innodb_file_per_table | 1 | 未使用独立表空间（innodb_file_per_table=OFF） |
| WARN | `long_query_time_high` | hygiene | setting:long_query_time | 1 | 慢查询阈值过高（会漏掉大部分值得看的语句） |
| WARN | `non_innodb_table` | risk | table | 1 | 存在非 InnoDB 引擎的业务表 |
| WARN | `slow_query_log_off` | hygiene | setting:slow_query_log | 1 | 慢查询日志未开启 |
| WARN | `stats_expiry_too_long` | hygiene | setting:information_schema_stats_expiry | 1 | 表统计信息使用缓存的过期值（information_schema_stats_expiry > 0） |
| WARN | `sync_binlog_not_1` | risk | setting:sync_binlog | 1 | binlog 未每次提交同步（sync_binlog 非 1） |
| WARN | `table_without_primary_key` | risk | table | 1 | InnoDB 表没有主键（也没有等效的唯一非空索引） |
| WARN | `trx_commit_not_durable` | risk | setting:innodb_flush_log_at_trx_commit | 1 | 提交不落盘（innodb_flush_log_at_trx_commit 非 1） |
| INFO | `redundant_index` | hygiene | index | 1 | 冗余索引（存在可覆盖它的其它索引） |
| INFO | `sql_require_primary_key_off` | hygiene | setting:sql_require_primary_key | 1 | 未强制新表必须有主键（sql_require_primary_key=OFF） |
| INFO | `stale_index_statistics` | latency | index | 1 | 索引统计信息失真（基数为 1 但表很大） |
| INFO | `statement_high_total_latency` | latency | statement | 2 | 累计耗时最高的语句（按 digest 排序） |
| INFO | `table_open_cache_miss` | latency | setting:table_open_cache | 1 | 表缓存未命中率偏高（反复打开表定义） |

### CRIT · tmp_table_disk_spill — 临时表大量落盘

**处置**：同时调大 tmp_table_size 与 max_heap_table_size（两者必须一致，否则以较小者为准）；然后定位产生大临时表的查询——通常是 GROUP BY / DISTINCT 命中了 TEXT/BLOB 列，或 ORDER BY 无法走索引。

**注意**：内部临时表分内存表与磁盘表，只有内存表超限才落盘。命中说明存在落盘，但落盘量小（绝对条数少）时不必处理，已用总临时表数 > 1000 做门禁。

| severity | disk_tmp_pct | created_tmp_disk_tables | created_tmp_tables | uptime_s | _fingerprint |
|---|---|---|---|---|---|
| critical | 99.1 | 9686 | 9770 | 847 | 969757b84b72 |

### WARN · auto_increment_exhaustion — 自增主键接近类型上限

**处置**：用 int（上限约 21 亿）做自增主键、且写入速率高的表，跑满只是时间问题，而耗尽之后所有 INSERT 会直接失败（error 1062/1467），属于典型"凌晨炸"的故障。到 70% 就该动手：改成 BIGINT UNSIGNED 需要重建表（ALTER TABLE ... MODIFY，配合 pt-online-schema-change 或 gh-ost 减少锁表时间）。

**注意**：已用"峰值超过类型上限的 50%"作为门槛，低于此不报，避免刷屏。判定依据是 information_schema.TABLES.AUTO_INCREMENT，它可能滞后于真实插入位置（缓存分配），因此百分比是估算。另外 AUTO_INCREMENT 会因为删除最大值、回滚、以及 InnoDB 8.0 之前的计数器不持久化而回退，不要在它上面做精确容量规划。

| severity | table_schema | table_name | column_name | column_type | current_auto_increment | type_max_value | used_pct | _fingerprint |
|---|---|---|---|---|---|---|---|---|
| warn | mysqlbot_test | int_autoinc | id | int | 1500000000 | 2147483647 | 69.85 | 68a664a2276d |

### WARN · binlog_retention_unbounded — binlog 永不自动清理（存在撑满磁盘的风险）

**处置**：log_bin=ON 但过期时间被显式设为 0，等于"永远不删 binlog"，写入量大的实例迟早把数据盘写满，而磁盘写满会连带 InnoDB 无法刷盘、实例整体不可写。设置 binlog_expire_logs_seconds 为一个与"最长可接受恢复点"匹配的值（默认 2592000 = 30 天）。设置过短会让从库断档后无法重连（需要的 binlog 已被删）——设之前先确认最长的主从延迟与备份窗口。

**注意**：MySQL 8.0 中 binlog_expire_logs_seconds 优先于已废弃的 expire_logs_days，前者非零时后者被忽略，所以本规则只看前者的值。8.0 之前的版本用 expire_logs_days，见 binlog_retention_unbounded_57。该规则不判断磁盘实际使用率：磁盘更大、写入更少的实例可能永远撑不满，此时把规则加入 skip 而不是改参数。

| severity | variable_name | current_seconds | suggested_value | log_bin | auto_purge | _fingerprint |
|---|---|---|---|---|---|---|
| warn | binlog_expire_logs_seconds | 0 | 2592000 (30 天) | 1 | 1 | 95e3d2c0046a |

### WARN · full_table_scan_heavy — 存在大量不走索引的语句（全表扫描放大）

**处置**：按 digest 拿到样本 SQL 后，重点看两件事：WHERE 列有没有索引、以及索引是否因为隐式类型转换（列是 varchar 却比数字）而失效。扫描行数极大而返回行数极小，是最典型的"缺索引"信号。

**注意**：直接读 events_statements_summary_by_digest 而不是 sys 视图，是为了拿到精确的数值列——sys 视图里的 *_latency 是格式化字符串，按它排序会得到错误的名次。digest 表在 P_S 启动后才有数据，刚重启的实例这里会是空的（此时报"干净"是假干净）。语句摘要受 performance_schema_digests_size 限制，超限语句会归到 digest='' 的汇总行，本规则已排除该行。

| severity | db | exec_count | no_index_used | no_index_pct | rows_examined_avg | rows_sent_avg | rows_examined_total | query_sample | digest | _fingerprint |
|---|---|---|---|---|---|---|---|---|---|---|
| warn | mysqlbot_test | 600 | 600 | 100.0 | 200000 | 1 | 120000000 | SELECT COUNT(*) FROM nopk_big WHERE payload LIKE '%zzz%' | f41199c4867a3e1198c691e50080dd669307fff0f6edaeb00c4187ac682… | 39d4219d9b6f |
| warn | mysqlbot_test | 24 | 24 | 100.0 | 200001 | 1 | 4800024 | SELECT payload FROM nopk_big ORDER BY payload LIMIT 1 | f8916caf00d4658251365c314474c0a33480216fae4fea45b1dd095a33e… | 3958de33fb4c |
| warn | mysqlbot_test | 4800 | 4800 | 100.0 | 300 | 300 | 1440000 | SELECT k, COUNT(*) AS c FROM (SELECT payload AS k FROM nopk… | 0ed8d24c97eb83f26a0d2e27bfbbef439f0644548a61b2670bb58df776d… | ffa23000a987 |

### WARN · innodb_file_per_table_off — 未使用独立表空间（innodb_file_per_table=OFF）

**处置**：改为 ON（动态生效，只影响之后新建/重建的表）。关闭时所有 InnoDB 表共用 ibdata1：**DROP TABLE 不会把空间还给操作系统**——删掉 500GB 的表，磁盘占用一点不减，只能靠导出重建整个实例来回收。打开后每表一个 .ibd 文件，DROP/TRUNCATE 即可释放，且支持单表压缩与单表传输。

**注意**：改成 ON 之后，已有的表**仍留在 ibdata1 里**，需要 ALTER TABLE ... ENGINE=InnoDB（或 pt-online-schema-change）逐表重建才会迁出。这个重建过程对大实例是重活，要分批做并监控磁盘余量。另外 ibdata1 不会自动缩小，通常需要重建实例才能真正回收。

| severity | variable_name | current_value | suggested_value | note | _fingerprint |
|---|---|---|---|---|---|
| warn | innodb_file_per_table | 0 | ON | 已有表需 ALTER TABLE ... ENGINE=InnoDB 才会迁出 ibdata1 | 31b1ad4b6987 |

### WARN · long_query_time_high — 慢查询阈值过高（会漏掉大部分值得看的语句）

**处置**：把 long_query_time 降到 1 秒甚至 0.5 秒。默认 10 秒意味着"低于 10 秒的语句一律不记录"，而 OLTP 场景里真正的问题往往是几千条 0.5~2 秒的语句累积成的。配合 pt-query-digest 或 mysqldumpslow 做聚合，不要直接读原始慢日志。

**注意**：读的是 @@GLOBAL 而不是会话值——业务连接池常常自行 SET SESSION long_query_time，会话值不能代表实例配置。阈值调低会显著增加日志量，请同时规划日志轮转（logrotate），否则慢日志本身会成为磁盘隐患。分析型/报表型实例用 10 秒甚至更长是合理的，这类实例请把本规则加入 skip。

| severity | variable_name | current_seconds | suggested_seconds | slow_query_log | _fingerprint |
|---|---|---|---|---|---|
| warn | long_query_time | 10.000000 | 1 | 0 | 881311eb3f69 |

### WARN · non_innodb_table — 存在非 InnoDB 引擎的业务表

**处置**：转成 InnoDB：ALTER TABLE ... ENGINE=InnoDB。MyISAM 没有事务、没有崩溃恢复、只有表级锁，且不支持在线备份——大表上的表锁会直接变成业务故障。

**注意**：系统库（mysql/sys 等）里的 MyISAM 表是 MySQL 自身的实现细节，已排除。老版本升级上来的库常见历史遗留 MyISAM 表，逐个评估迁移成本即可，不必一次性全转。

| severity | table_schema | table_name | engine | estimated_rows | size_mb | _fingerprint |
|---|---|---|---|---|---|---|
| warn | mysqlbot_test | myisam_tbl | MyISAM | 3 | 0.0 | fa97cc80f978 |

### WARN · slow_query_log_off — 慢查询日志未开启

**处置**：打开 slow_query_log（动态生效），并把 log_output 设为 FILE 或 TABLE。慢日志是事后定位"昨晚那波卡顿是谁造成的"唯一可靠的证据来源——P_S 的语句摘要只看得到统计聚合，看不到具体时刻和具体值。生产环境建议同时配上 log_slow_admin_statements 与 log_slow_extra 以补全元信息。

**注意**：P_S 的 events_statements_summary_by_digest 能在一定程度上替代慢日志（本工具的其他规则就依赖它），所以"慢日志关闭"不等于"完全瞎"；但对需要精确复现单次问题的场景，慢日志不可替代。容器化部署时常把日志写到不受采集的路径，若已开启但从未被采集，本规则不会发现——它只检查开关。

| severity | variable_name | current_value | suggested_value | long_query_time | log_output | _fingerprint |
|---|---|---|---|---|---|---|
| warn | slow_query_log | 0 | ON | 10.000000 | FILE | 90b26c015cb3 |

### WARN · stats_expiry_too_long — 表统计信息使用缓存的过期值（information_schema_stats_expiry > 0）

**处置**：设为 0（动态生效，全局与会话均可）。这个参数从 8.0 引入、默认 86400 秒，含义是：从 information_schema.TABLES / STATISTICS 读到的 TABLE_ROWS、DATA_LENGTH、CARDINALITY 等统计值，允许返回最多 24 小时前的缓存快照，而不是去存储引擎现取。后果有两层——**对监控是致命的**：任何"表多大、多少行、索引基数多少"的判断都可能基于一天前的数据，报出来的容量与倾斜结论直接是错的；**对业务影响较小**：优化器走的是自己的统计信息路径，不读这个缓存。

**注意**：读的是 @@GLOBAL——本工具的巡检会话会把该变量强制置 0，若读会话值就会永远看不到这个问题。设成 0 之后，每次查询 information_schema 的统计列都会触发一次存储引擎采样，在表非常多（上万张）的实例上会带来可感知的开销；此时折中方案是设一个短周期（如 60 秒）而不是 0。本工具在跑规则前会在会话里强制置 0，所以 mysqlbot 自己的结论不受影响——这条规则针对的是"你手工查 information_schema 时会被它骗到"。

| severity | variable_name | current_seconds | current_hours | suggested_seconds | mitigation | _fingerprint |
|---|---|---|---|---|---|---|
| warn | information_schema_stats_expiry | 86400 | 24.0 | 0 | mysqlbot 巡检时会话级强制置 0 | f1c4aad57609 |

### WARN · sync_binlog_not_1 — binlog 未每次提交同步（sync_binlog 非 1）

**处置**：设回 1（每次提交 fsync binlog）。非 1 的取值在主机断电时会丢失已提交但未落盘的事务——对主库意味着数据丢失，对从库意味着接到的 binlog 比预期少，而在 MGR 或半同步复制下还可能造成成员间数据分歧。

**注意**：该参数只在 log_bin=ON 时有意义，因此本规则内联判断了 log_bin。大批量导入时临时设成 0 是常见提速手段，但必须记得改回来——本规则会一直报到你改回来为止，这正是它存在的价值。MySQL 8.0 默认即为 1。用 @@变量 直读，避免依赖 8.4 已移除的 information_schema.GLOBAL_VARIABLES。

| severity | variable_name | current_value | suggested_value | log_bin | _fingerprint |
|---|---|---|---|---|---|
| warn | sync_binlog | 0 | 1 | 1 | 64684a6ff2d5 |

### WARN · table_without_primary_key — InnoDB 表没有主键（也没有等效的唯一非空索引）

**处置**：补一个自增或业务主键。无主键的 InnoDB 表会隐式生成 6 字节 rowid，且该 rowid 全局共享同一个计数器——高并发插入时这个计数器会成为热点，同时影响复制性能与表空间回收。

**注意**：已排除"存在唯一且所有列都非空"的索引——那种表实际上有聚簇索引，不影响性能。这是 MySQL 特有的坑，PostgreSQL 没有等价问题。信息来自 information_schema，若监控账号无 schema 读权限则看不到任何行（会误报为"干净"，见 probe 的 schema_visibility 能力位）。

| severity | table_schema | table_name | estimated_rows | size_mb | _fingerprint |
|---|---|---|---|---|---|
| info | mysqlbot_test | nopk_big | 197077 | 47.6 | b3e9f2d9d66f |

### WARN · trx_commit_not_durable — 提交不落盘（innodb_flush_log_at_trx_commit 非 1）

**处置**：值 1 表示每次提交都写 redo 并 fsync，是唯一能保证"提交即持久"的设置。值 2 只写到 OS 缓存，MySQL 进程崩溃不丢数据但操作系统/断电会丢；值 0 连 OS 缓存都不保证，任何崩溃都可能丢最近 1 秒的已提交事务，而且**返回给客户端的 commit 成功是假的**。金融/交易类库必须设为 1；只为压测提速而设 0/2 的实例，请确认它不被当作可靠存储使用。

**注意**：这是明确的取舍而非缺陷：大批量导入、离线分析库、可重建的数据仓库常常刻意用 0/2 换取写入吞吐。判定前先确认这台实例承载的业务是否允许丢数据——本规则不做这个判断，只把事实摆出来。顺序上有依赖：若 sync_binlog 也非 1，则复制环境下的数据丢失窗口会进一步放大。

| severity | variable_name | current_value | suggested_value | risk_description | _fingerprint |
|---|---|---|---|---|---|
| warn | innodb_flush_log_at_trx_commit | 2 | 1 | 每次提交写 OS 缓存、每秒 fsync：操作系统崩溃或断电可能丢失最近约 1 秒的已提交事务 | 64bf92df1bb2 |

### INFO · redundant_index — 冗余索引（存在可覆盖它的其它索引）

**处置**：sys.schema_redundant_indexes 已经算出"被哪个索引完全覆盖"，按 dominant_index_name 保留、把 redundant_index_name 删掉即可。删除后写入会变快（少一次索引维护）、占用空间会下降。大表 DROP INDEX 是 online DDL，但仍需短暂 MDL，放到低峰期执行。

**注意**：冗余不等于可以无脑删：如果冗余索引是某个外键唯一可用的索引，DROP 会被 InnoDB 拒绝（error 1553）；如果它是唯一索引而 dominant 是普通索引，删掉会丢唯一约束——本规则已排除"冗余索引是唯一索引"的情况。另一个常见误判来源是只服务于特定查询的短前缀索引，删之前先确认没有语句依赖它的排序。

| severity | table_schema | table_name | redundant_index | redundant_columns | dominant_index | dominant_columns | table_size_mb | suggested_drop | _fingerprint |
|---|---|---|---|---|---|---|---|---|---|
| info | mysqlbot_test | dup_idx | idx_user_dup | user_id | idx_user | user_id | 0.5 | ALTER TABLE `mysqlbot_test`.`dup_idx` DROP INDEX `idx_user_… | b13f600fc0b6 |

> ⚠️ 本项证据含可执行语句：`DROP INDEX`。证据列 suggested_drop 是 sys 自动生成的可执行 DROP INDEX 语句。执行前请确认该索引不是外键依赖项，并在低峰期操作。

### INFO · sql_require_primary_key_off — 未强制新表必须有主键（sql_require_primary_key=OFF）

**处置**：打开 sql_require_primary_key=ON（可动态设置），让"创建无主键表"这一动作直接失败。MySQL 8.0.13 引入该参数，是防止无主键表继续产生的最省事手段。注意：开启后，对已存在的无主键表做 ADD COLUMN 等需要重建表的 DDL 也会被拒绝，需要先补主键。

**注意**：在 MySQL 8.0.13 之前以及 MariaDB 上不存在该变量——版本门禁已用 @since 声明，避免在那些版本上因"未知系统变量"而失败。仅有存量无主键表的实例请配合 table_without_primary_key 规则一起看：那条查存量，这条防增量。

| severity | variable_name | current_value | suggested_value | _fingerprint |
|---|---|---|---|---|
| info | sql_require_primary_key | 0 | ON | c9f4d0634a58 |

### INFO · stale_index_statistics — 索引统计信息失真（基数为 1 但表很大）

**处置**：基数为 1 意味着优化器认为该索引所有值都相同，会直接放弃它转而全表扫描。执行 ANALYZE TABLE 重新采样。若 ANALYZE 后基数仍然很低，说明数据分布确实倾斜，或该列被函数包住（例如存的是 JSON 片段），此时应考虑改用生成列 + 索引。

**注意**：读的是 information_schema.STATISTICS.CARDINALITY，它本身来自缓存——MySQL 8.0 默认 information_schema_stats_expiry=86400 秒，本工具已在会话里把它设为 0 保证读到实时值；用别的客户端手工跑这条规则时请自己先设置。刚建的表、刚做完大批量导入的表出现低基数是暂时的，不要立刻下结论。CARDINALITY 为 NULL 表示统计信息从未生成过，本规则已把它排除，避免与"未统计"混淆。

| severity | table_schema | table_name | index_name | leading_column | cardinality | estimated_rows | suggested_fix | _fingerprint |
|---|---|---|---|---|---|---|---|---|
| info | mysqlbot_test | same_value | idx_flag | flag | 1 | 20185 | 0 | 613581687c09 |

### INFO · statement_high_total_latency — 累计耗时最高的语句（按 digest 排序）

**处置**：这是"总时间"榜而不是"单次"榜：一条 5ms 的语句跑 100 万次，比一条 3s 的语句跑 10 次更值得先优化。先确认它是否高频且可以缓存/合并，再看执行计划能否降低单次成本。

**注意**：SUM_TIMER_WAIT 单位是皮秒。已过滤系统 schema 与 digest 为空的汇总行。P_S 只保留受 performance_schema_digests_size 限制的 top 语句，超出的会汇总到 digest='' 行——所以这里看到的是"P_S 认为的 top"，不是绝对 top。CPU 时间列需要 performance_schema 的 CPU 计时 consumer。

| severity | db | total_seconds | avg_ms | max_seconds | exec_count | rows_examined_total | tmp_disk_tables | sort_merge_passes | query_sample | digest | _fingerprint |
|---|---|---|---|---|---|---|---|---|---|---|---|
| info | mysqlbot_test | 69.74 | 116.24 | 0.172 | 600 | 120000000 | 0 | 0 | SELECT COUNT(*) FROM nopk_big WHERE payload LIKE '%zzz%' | f41199c4867a3e1198c691e50080dd669307fff0f6edaeb00c4187ac682… | 94675adb5f5a |
| info | mysqlbot_test | 15.01 | 3.13 | 0.111 | 4800 | 1440000 | 9600 | 0 | SELECT k, COUNT(*) AS c FROM (SELECT payload AS k FROM nopk… | 0ed8d24c97eb83f26a0d2e27bfbbef439f0644548a61b2670bb58df776d… | 9a4ff204a929 |

### INFO · table_open_cache_miss — 表缓存未命中率偏高（反复打开表定义）

**处置**：先看 table_open_cache 与 Open_tables 的差距：若 Open_tables 长期贴近 table_open_cache，把 table_open_cache 提高（单个连接句柄的表缓存上限由 table_open_cache 决定，句柄占用总量还受 table_open_cache_instances 影响）。若 misses 高但 Open_tables 远小于上限，说明工作集本身比缓存大，优先确认是否有大量一次性表（临时表、按月分表）在轮转。

**注意**：累计计数器，实例重启后清零，故用运行时长门禁（@min_uptime: 1 小时）显式跳过而不是报干净；另有"命中+未命中 > 1 万次"门禁以排除低流量实例。此指标只反映"表定义是否需要重新打开"，不是磁盘 IO 指标——命中率低会带来元数据锁竞争，但不会直接体现为慢查询。

| severity | miss_pct | cache_hits | cache_misses | cache_overflows | uptime_s | _fingerprint |
|---|---|---|---|---|---|---|
| info | 5.61 | 14040 | 834 | 0 | 847 | 257473c3d20b |

## 未覆盖（这不等于干净）

| 规则 | 状态 | 原因 |
|---|---|---|
| `binlog_retention_unbounded_57` | skipped | MySQL >= 8.0 已移除该信号源 |

## 能力位

| 能力 | 状态 | 说明 |
|---|---|---|
| `audit_admin` | ❌ |  |
| `global_select` | ✅ |  |
| `innodb` | ✅ |  |
| `mysql84` | ✅ |  |
| `p_s` | ✅ |  |
| `p_s_locks` | ✅ |  |
| `p_s_mdl` | ✅ |  |
| `p_s_memory` | ✅ |  |
| `p_s_statements` | ✅ |  |
| `p_s_waits` | ✅ |  |
| `process` | ✅ |  |
| `replication` | ✅ |  |
| `schema_select` | ✅ |  |
| `super` | ❌ |  |
| `sys` | ✅ |  |
| `sys_functions` | ❌ | sys 函数不可调用（execute command denied to user 'mbot_reader'@'%'… |
| `sys_indexes` | ✅ |  |

- 实例启动仅 847 秒，累计型指标（命中率等）暂不可信
