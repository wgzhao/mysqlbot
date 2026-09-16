# 设计决策与踩过的坑

这份文档记录的是**为什么这样做**，以及每条结论背后的实测证据。规则本身会随版本更新，
这里的原则不会。

---

## 一、移植代价分层：pgbot → mysqlbot

pgbot 是 PostgreSQL 侧的同类工具（228 个 Go 文件 / 约 35k 行，61 篇发现文档，24 个采集 SQL）。
把它搬到 MySQL，代价明显分层：

| 层 | 处理方式 | 说明 |
|---|---|---|
| 渲染层（SARIF/JUnit/Prometheus） | **照搬** | 不依赖数据库方言 |
| JSON 契约、基线与 diff | **照搬** | 同上 |
| MCP server（stdio JSON-RPC） | **照搬** | 340 行纯标准库，无方言依赖 |
| AI 解释层设计 | **照搬** | "发现确定性算出，模型只解释" |
| 采集层 | **重写** | P_S + `sys` + `@@var` 与 pg_catalog 完全不同 |
| 发现规则 | **重写** | PG 的规则基本不能复用 |
| `advise`（假设索引验证） | **砍掉** | MySQL/MariaDB 都没有 hypopg，无法确认规划器会否采用 |

粗算：可照搬的部分约占 pgbot 非测试代码的 22%，成本集中在采集与规则两层。

---

## 二、六个实测踩到的坑

这些全部是**在 MySQL 8.4.11 上真跑出来的**，不是推测。

### 坑 1：`information_schema.GLOBAL_VARIABLES` 在 8.4 已被移除

```
ERROR 1146 (42S02): Unknown table 'GLOBAL_VARIABLES' in information_schema
```

`information_schema.GLOBAL_VARIABLES` / `SESSION_VARIABLES` 自 8.0.14 起被废弃，
**8.4 彻底移除**。任何直接查它们的规则在 8.4 上会整体失败。

**解决**：全部改用 `@@var` / `@@GLOBAL.var` 直读。这个形式：

- 5.7 → 9.x 全程可用，没有版本断档；
- 不需要任何 `SELECT` 权限，也不需要 `performance_schema` 表；
- 在 `performance_schema=OFF` 时依然可用（所以 `performance_schema_off` 这条规则本身
  不能去查 `performance_schema`）；
- 缺点：`SELECT` 语句必须有 `FROM`，要写 `FROM DUAL`。

**顺带发现**：`expire_logs_days` 在 8.4 也被移除了（`@@expire_logs_days` 报 1193）。
所以 binlog 保留策略拆成两条规则，用 `@since` / `@removed_in` 分段：
`binlog_retention_unbounded`（8.0+，看 `binlog_expire_logs_seconds`）与
`binlog_retention_unbounded_57`（5.7，看 `expire_logs_days`）。

### 坑 2：`sys` 视图是 `SQL SECURITY INVOKER`，`GRANT SELECT ON sys.*` 根本不够

这是本工具设计上最重要的一个转弯。实测：

```
mysql> SHOW GRANTS FOR 'mbot_reader'@'%';
GRANT SELECT, PROCESS, REPLICATION CLIENT ON *.* TO `mbot_reader`@`%`
GRANT SELECT ON `sys`.* TO `mbot_reader`@`%`

mysql> SELECT COUNT(*) FROM sys.innodb_lock_waits;
ERROR 1356 (HY000): View 'sys.innodb_lock_waits' references invalid table(s) or column(s)
                    or function(s) or definer/invoker of view lack rights to use them

mysql> SELECT sys.format_time(123456789);
ERROR 1370 (42000): execute command denied to user 'mbot_reader'@'%' for routine 'sys.format_time'
```

三条证据串起来：

1. `information_schema.VIEWS` 里 sys 视图的 `SECURITY_TYPE = INVOKER`
   （**不是** DEFINER）。所以视图底层引用的 `performance_schema` 表要用**调用者**的权限。
2. `SHOW GRANTS FOR 'mysql.sys'@'localhost'` 只有 `USAGE` + `sys.sys_config` 的 SELECT，
   **没有 EXECUTE**。而 `sys` 的函数（`format_time`、`format_statement`、`format_bytes`…）
   DEFINER 就是这个账号。
3. 于是最小权限账号一旦碰到带格式化的 sys 视图（如 `sys.statement_analysis`），
   就会因为缺 EXECUTE 而 1356。

对照实验：`sys.x$statement_analysis`（不经格式化的原始版）**可以**读——它只碰 P_S 表。

**决策**：**核心发现一律直读 `performance_schema`，不依赖 sys 的格式化视图。**

理由不止权限：`sys` 视图把延迟格式化成 `'1.23 s'` 这种**字符串**，按它排序会得到错误的名次
（本工具最早的 `full_table_scan_heavy` 就是这样，后来改成读
`events_statements_summary_by_digest` 的皮质秒原始值）。加上 sys 视图定义在 8.0 → 8.4
之间还会变，依赖它等于把版本漂移引进核心路径。

**保留的两个例外**：`sys.schema_redundant_indexes` 与 `sys.schema_unused_indexes`。
实测它们在"PROCESS + SELECT ON sys.*"下可读，且实现的是不值得自己重写的判定算法
（冗余键的前缀覆盖判断）。

同理，`blocking_chains` 从 `sys.innodb_lock_waits` 改为直读
`performance_schema.data_lock_waits` + `data_locks` + `information_schema.INNODB_TRX`，
改完之后**只需要 PROCESS 权限就能工作**，之前的 1356 问题消失。

### 坑 3：`information_schema_stats_expiry` 默认 86400，表统计可能是 24 小时前的

MySQL 8.0 引入该变量，默认值 86400 秒。含义是：从 `information_schema.TABLES` /
`STATISTICS` 读到的 `TABLE_ROWS`、`DATA_LENGTH`、`CARDINALITY` 等**统计值**，
允许返回最多 24 小时前的缓存快照，而不是去存储引擎现取。

后果分两层：

- **对监控是致命的**：所有"表多大、多少行、索引基数多少"的判断都可能基于过期数据。
  报出来的容量结论与倾斜结论直接是错的。
- **对业务影响小**：优化器走自己的统计信息路径，不读这个缓存。

**解决**：runner 在**每条规则的同一个连接里**先执行
`SET SESSION information_schema_stats_expiry = 0`，再执行规则 SQL。

这里有个实现约束值得记下来：会话前导语句**不能产生结果集**。因为 CLI 驱动在
`--batch` 模式下会把每个语句的结果集依次打印，多一个结果集就会让解析错位。
`SET` / `USE` 都满足这个条件。

### 坑 4：会话前导会掩盖掉"读会话值"的规则

自测时发现的真实 bug：`stats_expiry_too_long` 期望命中却报"干净"。
原因是规则写的是 `@@information_schema_stats_expiry`（读**会话**值），
而 runner 刚刚把会话值置成了 0 —— 规则被自己的前导语句屏蔽了。

**解决**：所有"实例配置类"规则一律读 `@@GLOBAL.`。同理 `long_query_time`（业务连接池
常自行 `SET SESSION`，会话值不能代表实例配置）。

这是个典型的**自测才能发现的问题**：单看代码完全合理，只有真跑一遍才会暴露。

### 坑 5：把运行时长门禁写进 SQL，会产出"假干净"

累计型指标（缓冲池命中率、未使用索引、临时表比例）在实例刚重启时毫无意义 ——
计数器刚清零。最初的实现把门禁写进了 SQL 的 `WHERE uptime_s > 3600`，后果是：
在一个刚重启的实例上跑，工具报"没有缓冲池问题"。**这是假干净**，比报错更危险。

**解决**：把门禁提升为规则头部的 `@min_uptime: 3600`，由 runner 判定并**显式跳过**：

```
未覆盖 7 条（不等于干净，按规则看原因）：
  - table_open_cache_miss: 实例运行时间不足：累计计数器需要 1.0 小时，当前仅 11 分钟
```

现在"看不到"和"没问题"在输出上被彻底分开。这条改动是整份报告可信度的关键。

### 坑 6：`information_schema` 是按权限静默过滤的

想让巡检账号看到表结构、索引、容量，就得给它那些 schema 的 `SELECT` —— 而那同时
给了它读取**数据**的能力。MySQL 没有 `pg_monitor` 那种"能看全库元信息但碰不到数据"
的角色。

更麻烦的是**失败方式是静默的**：权限不足时 `information_schema.TABLES` 返回**空集合**，
不是报错。于是"无主键表"这类规则会报"干净"，而实际上它什么都没看到。

**解决**：能力位 `schema_select`（从 `SHOW GRANTS` 解析是否有 `SELECT ... ON *.*`），
凡是需要看业务目录结构的规则都声明 `@requires: schema_select`，缺了就被跳过。
代价是"按 schema 逐个授权"的账号会被判为不具备该能力位（保守但不会误报）。

---

## 三、连接层的设计

### 为什么默认走 `mysql` 客户端而不是驱动

1. 零依赖 —— DBA 机器上一定有客户端，不一定有 Python 驱动；
2. 天然支持 socket、SSL、`~/.my.cnf`、login-path、SSH 隧道；
3. `--batch` 模式会把 `\t` `\n` `\` `\0` 转义成字面量，字段可以安全地按 `\t` 切分。

代价：真正的 `NULL` 与字符串 `'NULL'` 都打印为 `NULL`，无法区分。本工具输出的列都是
标识符/数值/布尔判断，不涉及这个歧义，已在代码注释里写明。需要精确类型时用
`--driver pymysql`。

### 错误分类

这是让"降级而不报错"能落地的关键。MySQL 错误码被分成两类：

- **可降级**（→ 规则状态 `skipped`）：`1142` SELECT 被拒、`1227` 缺 PROCESS、
  `1146/1109` 表不存在、`1054` 列不存在、`1193` 未知系统变量、`1231`、
  `1305`、`3167`。
- **不可降级**（→ 规则状态 `error`）：语法错误等。

于是"账号权限不够"和"SQL 与版本不匹配"表现为**两种不同的状态**，用户能一眼分清
是"该给权限"还是"工具要修"。`error` 状态在自测里是硬失败。

### 其他实用细节

- `current_user` 在 MySQL 8.4 是保留字，不能做列别名（实测报语法错误），
  已改用 `connected_as`。
- `SELECT ... WHERE ...` 不带 `FROM` 是语法错误，需要 `FROM DUAL`。
- `--batch` 模式在**结果集为空时不打印表头**，所以"0 行"在输出上表现为完全空的 stdout。
  解析层据此返回空结果集，runner 判定为 `clean`。

---

## 四、自测装置

规则库最大的风险不是"报错"，而是**静默失效**——规则写错了但恰好返回 0 行，
于是永远报"干净"。单测规则文件本身抓不到这类问题。

所以 `tests/` 的设计是**端到端**的：

1. 起一个一次性实例（32MB 缓冲池、P_S consumer 全开、MDL instrument 打开）；
2. 种下**确定会违规**的东西：无主键的 20 万行表、MyISAM 表、冗余索引、
   `AUTO_INCREMENT=15 亿` 的 INT 主键、2 万行同值索引、8 个错误配置项、
   1356 条语句风暴、三个持锁后台会话（空闲事务 / 行锁等待 / 元数据锁等待）；
3. 用**只读账号**（不是 root）跑一轮完整巡检；
4. 断言：**0 条规则执行报错** + 17 条植入违规全部命中。

断言"0 条报错"这一条，专抓坑 1 那类"SQL 与版本不匹配"。它在真实开发过程中抓到了
`information_schema.GLOBAL_VARIABLES` 被移除、`unknown column r.connections` 别名笔误等
多个问题。

时间轴上的一个细节：`idle_in_transaction` 需要事务空闲 ≥ 60 秒，`blocking_chains` 需要
行锁等待 ≥ 10 秒，所以持锁会话的保持时长与巡检时点都要留足（默认保持 100 秒、
巡检前等 70 秒）。会话 A 的"空转"必须发生在**客户端侧**（shell 里 sleep），
不能在 SQL 里 `SELECT SLEEP()` —— 后者会让 `TRX_QUERY` 非空，就不是"空闲事务"了。

另外两个必须记住的约束：

- **持锁会话与巡检账号必须是不同用户**。`idle_in_transaction` 与 `metadata_lock_wait`
  会过滤掉"自己账号"的会话（否则工具把自己也算进去）。
- **`cleanup` 不能 `pkill -f "$SOCK"`**。mysqld 自己的命令行里就含 `--socket=$SOCK`，
  那样会把测试实例一起杀掉（本工具最早的自测脚本就有这个 bug，已改为按 PID 回收）。

---

## 五、明确不做的事

- **不给索引建议的收益承诺**。pgbot 用 hypopg 造假设索引、让规划器确认成本真的下降
  才敢报。MySQL 没有等价能力，替代方案（`OPTIMIZER_TRACE` 里被否决的候选、
  `EXPLAIN FORMAT=JSON` 的成本数）都不等价。本工具只说"这条语句没走索引、扫了 N 行"。
- **不用 LLM 做判断**。规则是确定的，模型最多用来解释结论——把判断权交给概率模型，
  会让同一份数据两次跑出不同结论。
- **不引入 `SHOW` 类语句作为规则源**。`SHOW REPLICA STATUS` 之类能提供 select 拿不到的
  信息（复制延迟），但它们不是可组合的 SELECT，会破坏"一条规则 = 一段可独立执行 SQL"
  这个性质。需要时应该设计一个受控的规则模式，而不是让工具去解析 SHOW 的列。
  （这也是复制延迟规则暂时缺失的原因，见 `README.md` 的路线。）

---

## 六、未验证的部分（如实列出）

- **只有 MySQL 8.4.11 上实测过**。规则里 `@since: 5.7` 表示信号源在 5.7 存在，
  但未在真实 5.7/8.0 上跑过回归。
- **MariaDB 未实测**。代码里有 `is_mariadb` 分支与提示，但没跑过。
- **`blocking_chains` 只覆盖 8.0+**（5.7 用 `information_schema.INNODB_LOCK_WAITS`，
  字段结构不同）。
- **复制类规则未测**（没有从库环境），只能验证"在非复制实例上返回 0 行、不报错"。
- **`replication_stopped` 在 SERVICE_STATE='OFF' 时报 warn**，人工 STOP REPLICA
  的维护窗口里会产生告警——这是有意的（提醒别忘了拉起来），但需要使用者知情。
