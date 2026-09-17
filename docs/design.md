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

## 二、实测踩到的坑

坑 1~6 是最早实现时踩到的；坑 7~14 起因是在 Percona Server 8.0.43（生产实例）与
MySQL 8.0.25 上做版本验证时一次暴露出来的一整批；坑 15~19 出自 Percona Server 5.7.44
的验证——其中坑 15 是**工具自身的缺陷**，它的修复让后面那条（坑 17，我自己写错的）
当场现形。

它们的共同点是**静默**：不报错、不中断，只是结论错、门禁失效，或者把"没检查"
说成"没问题"。

这些全部是**在真实实例上真跑出来的**，不是推测：坑 1~6 出自 MySQL 8.4.11，
坑 7~14 出自 Percona Server 8.0.43（业务账号，脱敏）与 MySQL 8.0.25，
坑 15~19 出自 Percona Server 5.7.44。

> 坑 15~19 的共同教训是：**"声明"与"正文"之间没有校验，缺陷就会藏在
> 「跳过」这个桶里**。针对这一点的架构回应（信号登记表、离线版本推演、
> 变体覆盖空洞检测、预测↔实测对账）单独成篇，见
> **[`versioning.md`](versioning.md)**——它同时回答了"要不要按大版本切目录"这个问题。

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

**解决**：能力位 `schema_select`，凡是需要看业务目录结构的规则都声明
`@requires: schema_select`，缺了就被跳过。

能力位怎么算，2026-09-16 重写过一次，因为**第一版是错的**（见坑 10）：

1. 先逐行解析 `SHOW GRANTS`，得出全局权限集与"每个 schema 各自的权限"；
2. 再用 `SELECT DISTINCT TABLE_SCHEMA FROM information_schema.TABLES` **问服务器**
   要一份权威的可见库清单 —— `information_schema` 本来就按权限过滤，所以它返回的
   就是结构类规则**实际能覆盖**的范围。这一份比解析授权文本可靠（角色、代理用户、
   隐式可见性都能反映），也顺带支持了"按 schema 逐个授权"的 B-2 档。
3. 两份结果都写进报告的 `visible_schemas`，并在没有全局 SELECT 时附一条 note
   明说覆盖范围。**这条 note 必须跟着结论一起汇报**，否则用户会把"没报无主键表"
   读成"整实例都没有无主键表"，而实际上只扫了几个库。

### 坑 7：`--defaults-file` 必须是命令行上的**第一个**参数

```
mysql: [ERROR] unknown variable 'defaults-file=/tmp/x.cnf'.
```

`conn.py` 原本把它排在 `--batch` 之后，于是 mysql 客户端不再把它当"选项文件"，
而是当成一条系统变量赋值来解析。后果是：文档里宣称支持的 `--defaults-file`
（复用 `~/.my.cnf` / login-path）**在 8.4 上根本不能用**，而且错在连接层，
看起来像"账号或配置文件有问题"。

**解决**：`_base_cmd()` 里 `--defaults-file` 紧跟二进制名，其余选项都放在它后面。

顺带一提：这条也是在真实实例上才暴露的——本机自测走 socket，从不用它。

### 坑 8：`AUTO_INCREMENT` 是 BIGINT UNSIGNED，`100 *` 会溢出

```
ERROR 1690 (22003): BIGINT UNSIGNED value is out of range in
'(100 * if((`mysql`.`tbl`.`type` = 'VIEW'),NULL,internal_auto_increment(...)))'
```

`auto_increment_exhaustion` 原本写的是 `100 * t.AUTO_INCREMENT / max_val`。
只要库里**存在一张** `AUTO_INCREMENT > 1.8446744e17` 的表（雪花 ID 风格的 bigint
主键、或曾被人工跳号），`100 * AUTO_INCREMENT` 这个中间结果就超出 BIGINT UNSIGNED，
MySQL 直接抛 1690 —— 整条规则报错，而不是只影响那一张表。

触发实例：`biz_db.t_perf_pre`，AI ≈ 2.1e18（约 11%，
离上限还很远，本不该报警）。

**解决**：两边都 `CAST(... AS DECIMAL(30,0))` 再做算术。DECIMAL 不会溢出。
教训是通用的：**规则里对 `information_schema` 的数值列做算术前先 CAST**，
那些列的类型往往比看上去宽。

### 坑 9：`||` 不是字符串拼接

```sql
-- 期望 'ANALYZE TABLE `db`.`t`'，实际得到 0
'ANALYZE TABLE `' || s.TABLE_SCHEMA || '`.`' || s.TABLE_NAME || '`'
```

`||` 在 MySQL 里是**逻辑或**，只有 `sql_mode` 含 `PIPES_AS_CONCAT` 时才是拼接。
默认 sql_mode 不含它（实测该实例：`STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION`），
于是整个表达式退化成 `0`/`1`。规则照样命中、报告照样出，只是**给用户的修复命令
变成了 `0`**。这是最典型的"静默错误"。

**解决**：一律用 `CONCAT(...)`；`lint` 可以考虑加一条"SQL 里禁止出现 `||`"的检查。

### 坑 10：`GRANT ALL PRIVILEGES` 的子串判断会把"某个库"当成"全库"

第一版能力位探测是这么写的：

```python
joined = " | ".join(grants).upper()
all_priv = "ALL PRIVILEGES" in joined          # ← 灾难
caps.flags["process"] = all_priv or "PROCESS" in joined
caps.flags["replication"] = all_priv or "REPLICATION (CLIENT|SLAVE)" in joined
```

一个只被授了 ``GRANT ALL PRIVILEGES ON `biz_db`.*`` 的**业务账号**，
就能让 `all_priv` 为真，于是 `process` / `replication` / `schema_select` / `super`
全部被误判为"有"。

后果是**能力门禁形同虚设**：规则不再被前置跳过，而是一路跑到执行期撞 `1142`，
报告里表现为一堆"执行被拒"的跳过（而不是清晰的"缺少能力位"），
而且顺序、原因、建议全都对不上。

**解决**：逐行解析 `GRANT <privs> ON <scope> TO <user>`，按 scope 区分全局
（`*.*`）与单库（`` `db`.* ``）；`ALL PRIVILEGES` 只在全局 scope 时才展开为"全都有"。
另有两个容易漏的细节：
- `ALL PRIVILEGES ON *.*` 是**一个**权限名，不会展开成 `PROCESS`/`SELECT`，
  漏了它 root 会被判成"什么权限都没有"；
- 列级授权 `GRANT SELECT (id, name) ON ...` 里的逗号会把权限列表切坏，
  必须**先剥掉括号再按逗号切**。

这条有专门的回归测试：`tests/test_grants.py`（纯字符串，不连库）。

### 坑 11：`performance_schema.threads` 拖死了两条最高价值的风险规则

`long_running_transaction` 与 `idle_in_transaction` 原本 `LEFT JOIN
performance_schema.threads` 只为取会话的 `USER` / `HOST` 两个**装饰性**字段。
但 `performance_schema.threads` 需要 `SELECT ON performance_schema.*`，
业务账号普遍没有 —— 于是一次 1142，整条规则被跳过。用两个 nice-to-have 字段
换来丢掉"长事务 / 空闲事务"这两条最该有的发现，这个交易非常亏。

**解决**：改用 `information_schema.PROCESSLIST`（`ID` ↔ `INNODB_TRX.trx_mysql_thread_id`）。
实测只要 `PROCESS` 就能看到**全部**会话，`@requires` 也从 `p_s,process` 降到 `process`。

更一般的教训：**规则里的 JOIN 只应该连"缺了会改变结论"的表**。
为了美化输出而引入一个高门槛依赖，等于给整条规则加了一道隐形门禁。

### 坑 12：`FROM DUAL LEFT JOIN ...` 是语法错误

想取一个"可能不存在"的系统变量（`binlog_expire_logs_auto_purge` 在 8.0.29 才引入，
8.0.25 上不存在），自然想到 `LEFT JOIN performance_schema.global_variables`——
但 MySQL 把 `DUAL` 特例化了，`DUAL` **不能作为 JOIN 的左表**，直接 1064。

**解决**：包一层派生表 `FROM (SELECT @@log_bin AS log_bin, ...) v LEFT JOIN ...`。
规则改完后，8.0.25（无该变量）与 8.0.43（有）都能正常求值。

### 坑 13：脚本里全角括号紧跟 `$VAR`

```bash
echo "== 启动（socket $SOCK, port $PORT）=="   # ← 这里
```

`set -u` 下报 `PORT\uff09: unbound variable`：在 C locale 里，bash 把紧跟 `$PORT`
的全角右括号的第一个字节当成了变量名的一部分。整个自测脚本直接起不来。

**解决**：`$VAR` 一律写成 `${VAR}`，或者别让全角标点紧贴变量展开。

### 坑 14：`--only 'a,b,c'` 的逗号写法原本不生效

CLI 用的是 `action="append"`，`--only 'a,b'` 会被当成**一个** pattern，
fnmatch 匹配不到任何规则 id，结果是「过滤后没有剩余规则」直接退出 2。
而 README 与 SKILL.md 里示范的恰恰就是这种写法——文档在骗人。

**解决**：`_normalize_patterns()` 把逗号/空格分隔的写法摊平，两种写法都认。

### 坑 15：把「版本不匹配」降级成「跳过」，等于自欺

`conn.py` 把 `1054`（列不存在）和 `1193`（变量不存在）跟 `1142`（权限不足）一起
归进"可降级"，两者都变成 `skipped`。于是 5.7 验证时报告显示"跳过 3 条"，
真相是"工具坏了 3 处"——`full_table_scan_heavy`、`statement_high_total_latency`、
`replication_stopped` 三条规则带着真实的版本不兼容缺陷，伪装成"环境限制"。

更糟的是它把自测里"0 条报错"这条**硬断言变成空话**：断言测的是 `error` 计数，
而缺陷全都藏进了 `skipped`。断言全绿，缺陷全在。

**解决**：分类判据从"严重程度"改成**"该由谁去修"**——换个账号/装上 `sys` 库能解决的
是环境的事（`skipped`）；SQL 写法与本版本对不上是工具的事（`error`）。
详见第三节「错误分类」。这条改动上线后**当场抓到了坑 17**。

### 坑 16：`QUERY_SAMPLE_TEXT` 是 8.0.22+ 才有的列

`full_table_scan_heavy` 与 `statement_high_total_latency` 用了
`COALESCE(d.QUERY_SAMPLE_TEXT, d.DIGEST_TEXT)`——本意是"优先取字面样本，退化到规范化文本"。
但 `COALESCE` 仍然要**解析**列引用，所以在没有该列的 5.7 上直接 1054，整条规则失效。

**解决**：直接用 `DIGEST_TEXT`——它从 5.7 起一直存在，跨三版通用。
代价是拿到的是参数被替换成 `?` 的规范化文本；对一个可能被转贴、进工单的报告来说，
不含字面值反而更合适。

### 坑 17：`replication_applier_status_by_worker` 的列名改过两次

想把 `replication_stopped` 做成三版通用的，先删掉 8.0 才有的
`APPLYING_TRANSACTION` / `APPLYING_TRANSACTION_RETRIES_COUNT`，换成 5.7 有的
`LAST_SEEN_TRANSACTION`。5.7 上跑得很干净，**8.4 自测当场报错**——
`LAST_SEEN_TRANSACTION` 是 5.7 独有，8.0 起就被 `LAST_APPLIED_TRANSACTION` 取代了。

实测三版的列集交集只有 7 个：`CHANNEL_NAME` / `WORKER_ID` / `THREAD_ID` /
`SERVICE_STATE` / `LAST_ERROR_NUMBER` / `LAST_ERROR_MESSAGE` / `LAST_ERROR_TIMESTAMP`。

**教训**：这次是工具自己把缺陷抓出来的（坑 15 修好之后）。若在坑 15 之前，
这条会在 8.0/8.4 上悄悄失效，而我还握着一份 5.7 的"干净"结果当证据。

### 坑 18：`metadata_lock_wait` 的 `@caveats` 在说谎

规则头部写着"5.7 无 `performance_schema.metadata_locks`，该规则在 5.7 上不可用"，
并据此声明 `@since: 8.0`。实测 **5.7.44 有这张表**（`metadata_locks` 自 5.7.3 起存在），
且规则用到的那 5 个列 `OBJECT_TYPE` / `OBJECT_SCHEMA` / `OBJECT_NAME` /
`LOCK_STATUS` / `OWNER_THREAD_ID` 5.7 全都有。

**解决**：`@since` 改成 5.7，规则在 5.7 上真跑起来了（本实例返回 0 行）。
文档里的"不可用"是推测，不是实测——这正是把"待验证清单"当结论写的代价。

### 坑 19：`LIMIT` 截断不可见，50 被读成"一共 50"

规则普遍带 `LIMIT n` 防刷屏。5.7 实例上 `unused_index` 报了 50 行，
而实际符合条件的有 **66** 个（`sys.schema_unused_indexes` 里 155 个，按
"非唯一 + 表 ≥10MB"过滤后 66 个）。报告里只有"50 行"，读者会当成全量。

**解决**：runner 解析规则**最外层**的 `LIMIT`（正则锚在结尾，子查询里的
`LIMIT` 不会误判），命中数达到它就在报告里标记"真实命中 **≥ N**"，
JSON 里出 `row_limit` + `truncated` 两个字段，终端里行数显示成 `≥50 行`。

### 坑 20：软查表缺变量是「哑失败」，推演对账看不见它

「硬引用 vs 软查表」这个区分（坑 15 的延伸）解决了很多问题，但它留下一个**无人看守的角落**：

- **硬引用**缺变量 → `ERROR 1193` → 规则变成 `error` → `live_compat.sh` 的推演对账
  立刻能看见（`missing_object` / `实际失败但未预测到`）。
- **软查表**缺变量 → `MAX(CASE WHEN VARIABLE_NAME='x') ...)` 返回 **NULL** →
  规则**既不报错也不跳过**，可能静静地给出错误结论。

也就是说：登记表把版本契约变成了可机检的，但"登记表本身是否过期"这件事，
**只对硬引用有回路**。软引用的那半是哑的。

> 这是机制上的缺口，**尚未造成过误报**（2026-09-16 在 9.7.2 上验证时才发现它存在）。
> 记在这里是因为它属于"不会报错但可能结论错"的那一类——
> 也就是本项目从头到尾在防的那一类。

**解决**：把对账扩到"信号清单"这一层，而不是只看规则的执行结果。
`mbot/probe.py` 新增 `attest_variable_signals()`：连库时把 `signals.py` 里登记的
**21 个变量信号**逐条与实例核对（存在性 + 区间预测），不一致就在 `doctor` 里报 ✗
并让自检返回失败，同时写进报告的 `notes`。

只核对**变量**，不核对表名与列名——后者一律是硬引用（缺了报 1146/1054），
已被 `error` 计数兜住；少做一类无用功，也就少一类假阳性。
MariaDB 与早于 5.7 的版本**显式跳过并写明原因**，不假装核对过。

反向验证（拿 5.7.44 去判定一台 9.7.2 实例）能抓到 8 条，例如：

```
✗ expire_logs_days：登记为 5.7 ~ 8.4（区间内），实例上却不存在
✗ binlog_expire_logs_seconds：登记为 8.0 ~ 至今（区间外），实例上却仍存在
```

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

这是让"降级而不报错"能落地的关键。MySQL 错误码被分成**两类**，而分类的判据
不是"严重程度"，是**"该由谁去修"**：

- **可降级**（→ 规则状态 `skipped`）：`1142` SELECT 被拒、`1227` 缺 PROCESS、
  `1146/1109` 表不存在、`1305` sys 函数没装、`3167`。
  这些指向的是**整个对象不存在或没权限**——换个账号、装上 `sys` 库就能解决，
  是环境的事，不是工具的事。
- **不可降级**（→ 规则状态 `error`，自测里是硬失败）：`1054` 列不存在、
  `1193` 未知系统变量、`1231` 变量设不了、`1064` 语法错误。
  这些指向的是**某个列/变量在本版本不存在**——也就是"规则的 SQL 写法与目标版本
  对不上"。它永远不该靠降级掩盖，正确做法是在规则头部补 `@since`/`@removed_in`
  门禁，让规则在版本不匹配时**主动**声明"本版本不适用"。

这个区分在 2026-09-16 的 5.7 验证里是决定性的。原先 `1054` 和 `1193` 被归进了
"可降级"（见坑 15），后果是 5.7 上三条规则带着真实的版本不兼容缺陷，伪装成
"环境限制导致的跳过"——报告显示"跳过 3 条"，而真相是"工具坏了 3 处"。
更糟的是它把自测里"0 条报错"这条硬断言变成了空话：断言测的是 `error` 计数，
而缺陷全都藏进了 `skipped`。

改对之后立刻见效：我刚把 `replication_stopped` 里 5.7 独有的 `LAST_SEEN_TRANSACTION`
留下、删掉 8.0 的 `APPLYING_TRANSACTION`，以为这样就通用了——8.4 自测**当场报错**，
因为它同样不认识 `LAST_SEEN_TRANSACTION`（8.0 起已移除）。没有这道断言，这条规则会
在 8.0/8.4 上悄悄失效，而我手上已经有 5.7 的"干净"结果当证据。

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
多个问题；坑 15 修好之后又抓到了坑 17。

它有一个**覆盖不到的盲区**：断言跑在本机 8.4 上，所以只有"8.4 的 SQL 不兼容"能被抓到。
5.7/8.0 侧的问题（如坑 16 的 `QUERY_SAMPLE_TEXT`）只有连到那两个版本的真实实例上才会现形。
补上这块的是第二个装置：

```bash
tests/live_compat.sh --defaults-file /path/to.cnf --label '5.7.44'
```

它只做一件事：在**指定的真实实例**上跑完 42 条规则，断言 `error == 0`，
并把跳过项逐条列出。只读（工具本身只发 SELECT / SET SESSION），
所以可以直接对生产实例跑。每个版本各配一份凭据文件，就是一条跨版本回归线
（本机想同时测多个大版本时，用 `MYSQLD_BIN` + `MYSQLBOT_TEST_HOME` + `MYSQLBOT_TEST_PORT`
另起一次性实例即可，见 `README.md` 的自测一节）。

单测部分（不连库）：

```bash
python3 tests/test_grants.py      # 授权解析 / 能力位判定
python3 tests/test_classify.py    # 错误分类 / LIMIT 截断判定
```

`test_grants.py` 守的是坑 10 那类"能力位算错但不报错"的问题——这类 bug 端到端测试也抓不到，
因为规则会命中、报告会出，只是**门禁失效了**。用例覆盖真实抓取的业务账号授权、
`ALL PRIVILEGES ON *.*`、A 档只读账号、空账号、MariaDB 权限名、列级授权、
表级授权七种形态。

`test_classify.py` 守的是坑 15 和坑 19：前者断言 `1054`/`1193` **不可**降级、
`1142`/`1146` 可降级；后者断言外层 `LIMIT` 解析正确、且子查询里的 `LIMIT` 不会被误认。

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

- **MySQL 9.7.2 / MySQL 8.4.11 / Percona 8.0.43 / Percona 5.7.44 四个版本上都跑过完整巡检，
  均为 0 条执行错误。** 8.4 与 9.7 是本机一次性实例上的端到端回归（含 17 条植入违规的
  硬断言），8.0.43 与 5.7.44 是真实实例上的兼容性检查。详见 `docs/compat-matrix.md`。
- **版本维度上仍有空白**：8.4 只测过 8.4.11、9.x 只测过 9.7.2、8.0 测过 8.0.43 与 8.0.25，
  5.7 只测过 5.7.44 一个点。规则头部声明的 `@since: 5.7` 表示"信号源在 5.7 存在，
  且已在 5.7.44 上实测执行通过"，**不代表 5.7.0~5.7.43 都测过**。
  5.7 早期版本（< 5.7.3）没有 `performance_schema.metadata_locks`——这个补丁级下界
  现在写成了 `@since: 5.7.3`，并由信号登记表 + `lint` 的方向一检查管住。
- **`9.0` 仍未实测**（非 LTS，没有实例）。`9.7.2` 已实测：42 条 0 报错、17 条硬断言全中、
  推演对账吻合，且**规则一行未改**——9.1 重设计过的
  `performance_schema.data_locks` / `data_lock_waits` 实测列集未变。
- **5.7 那次是用 root 账号跑的**，所以能力位几乎全开（15/16）——它验证的是
  "SQL 与版本是否兼容"，**不是**"最小权限账号下能跑几条"。权限维度的实测结论
  来自 8.0.43 的业务账号。
- **MariaDB 未实测**。代码里有 `is_mariadb` 分支、权限名映射（`BINLOG MONITOR` /
  `SLAVE MONITOR`）与单测，但没连过真实 MariaDB。
- **锁等待链是两套 SQL**：8.0+ 走 `performance_schema.data_lock_waits`
  （`blocking_chains`），5.7 走 `information_schema.INNODB_LOCK_WAITS`
  （`blocking_chains_57`），用 `@since`/`@removed_in` 互斥。两条都只在
  "没有争用时返回 0 行"这一侧验证过——**没有在真实争用下比对过两套 SQL 的结果是否等价**。
- **复制类规则未在真实从库上测**：5.7 与 8.0.43 两个实例都不是从库
  （复制表全空），8.4 一次性实例也不是。只能验证"在非复制实例上返回 0 行、不报错"，
  以及正确因缺 `REPLICATION CLIENT` 而跳过。`replication_io_error` 用到的列
  已逐版本核对过，但**没在真的复制链路上跑过**。
- **`replication_stopped` 在 SERVICE_STATE='OFF' 时报 warn**，人工 STOP REPLICA
  的维护窗口里会产生告警——这是有意的（提醒别忘了拉起来），但需要使用者知情。
- **`redundant_index` / `unused_index` 依赖 `sys` 视图**，业务账号通常没有 `sys` 的 SELECT；
  这两个库的判定算法（左前缀冗余、索引零使用）目前没有自研替代实现。
- **`blocking_chains_57` 的 `locked_schema` / `locked_table` 由 `LOCK_TABLE` 切分得到**，
  库名或表名里含点号时会切错（5.7 的 `INNODB_LOCKS` 没有分列的 schema/table 字段）。
  已在 `@caveats` 里写明。
