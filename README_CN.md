<h1 align="center">mysqlbot</h1>

<p align="center">
  <strong>只读、确定性、无 agent 的 MySQL 体检探头。</strong><br>
  42 条 SQL 规则读取服务器自身的统计与数据字典，输出「结论优先」的体检报告 ——
  还能离线回答「这套规则放在某个版本上跑不跑得起来」。<br>
  不部署、不常驻、工具链里没有任何写路径，且每条规则都能脱离本工具手工执行验证。
</p>

<p align="center">
  <img alt="MySQL 5.7–9.7" src="https://img.shields.io/badge/MySQL-5.7%E2%80%939.7-4479A1">
  <img alt="Python 3.9+" src="https://img.shields.io/badge/python-3.9%2B-3776AB">
  <img alt="零依赖" src="https://img.shields.io/badge/dependencies-none-brightgreen">
  <img alt="不写库" src="https://img.shields.io/badge/writes-none-blue">
</p>

<p align="center">
  <a href="#快速开始">快速开始</a> ·
  <a href="#安装">安装</a> ·
  <a href="#只读账号">只读账号</a> ·
  <a href="#命令与参数">命令</a> ·
  <a href="#看一眼输出">看输出</a> ·
  <a href="#版本支持">版本支持</a> ·
  <a href="#json-契约">JSON 契约</a> ·
  <a href="#ci-集成">CI</a> ·
  <a href="#疑难排查">疑难排查</a>
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>中文</strong>
</p>

> **状态：beta。** JSON 契约是带版本的（`"schema": "mysqlbot/report/v1"`），对它的破坏性
> 变更等同于对工具的破坏性变更。人读表格**不是**稳定接口 —— 要脚本化请解析 `-o json`。
> 两点如实说明：工具自身的输出文案目前是**中文**（i18n 在
> [路线](#路线与非目标)里），长篇设计文档也暂时只有中文。

---

## 快速开始

```sh
git clone https://github.com/wgzhao/mysqlbot.git
cd mysqlbot

# 0. 自检：客户端、规则目录、连通性、能力位，
#    并把版本信号登记表与真实实例核对一遍
./bin/mbot doctor --host 127.0.0.1 -u root -p '你的密码'

# 1. 体检（默认输出人读表格）
./bin/mbot check --host 127.0.0.1 -u mbot_reader -p '你的密码'
```

密码不必写在命令行上。`mysql` 客户端自己的配置文件可以直接复用，每一项连接设置也都有
环境变量：

```sh
export MYSQLBOT_HOST=127.0.0.1
export MYSQLBOT_USER=mbot_reader
export MYSQLBOT_PASSWORD='…'
./bin/mbot check

# 或者复用你已有的 login-path / ~/.my.cnf：
./bin/mbot check --defaults-file ~/.my.cnf

# 或者一条 DSN：
./bin/mbot check --dsn 'mysql://mbot_reader:…@127.0.0.1:3306/'
```

取用顺序是：显式参数 → `MYSQLBOT_*` 环境变量（`MYSQLBOT_DSN` / `MYSQLBOT_HOST` /
`MYSQLBOT_PORT` / `MYSQLBOT_USER` / `MYSQLBOT_PASSWORD` / `MYSQLBOT_SOCKET`）→
`mysql` 客户端本来会读的东西。密码额外兼容 `MYSQL_PWD`。

```
🟡 WARN      命中 18   干净 16   跳过  8   失败  0   （共 42 条规则）
```

这一行就是整个设计。`命中`是要处理的问题，`干净`是**真的验证过**的部分，而`跳过`是
**没法判断**的部分 —— 永远带原因。跳过不等于干净。`失败`应当是 0：一旦非 0，说明某条
规则的 SQL 与目标服务器对不上，那是工具的缺陷，不是"环境限制"。

## 为什么用 mysqlbot

| | |
|---|---|
| **只读是角色，不是开关** | 边界是你交给它的那个账号的 `GRANT`。工具链里没有写路径：只开一条 `mysql` 客户端连接，每条规则都是 `SELECT`。会写库的处置命令（`DROP INDEX`、`KILL`、`SET GLOBAL`）只作为**建议**打印出来由人执行 —— mysqlbot 自己绝不执行。 |
| **发现是算出来的，不是生成的** | 42 条规则就是 42 段纯 SQL，没有任何模型参与判断。`severity` 列甚至允许 SQL 动态升级自身严重度 —— 行锁等待跨过 300 秒就从 `warn` 变 `critical`。 |
| **降级而不说谎** | 缺权限、版本不符、实例运行时间不够 → **显式跳过并给出机器可读的原因**（`skip_kind`），绝不混进"干净"。反向同样成立：规则 SQL 与目标版本对不上是**失败**而不是跳过，否则规则坏掉时会伪装成"环境限制"混过去。 |
| **没有东西要部署** | 只用 Python 3.9+ 标准库，加上你本来就有的 `mysql` 客户端。没有守护进程、没有采集器、没有时序库、没有需要维护的配置文件。 |
| **版本兼容是契约，不是目录** | 规则用 `@since` / `@removed_in` 声明区间，一张信号登记表反过来核对该声明与 SQL 实际引用的版本敏感信号是否相符。`mbot coverage --at 9.7` **不连库**就能回答"这一版上跑不跑得起来"。 |
| **可以手工验证** | 每条规则都能单独执行：贴进 `mysql` 或 DBeaver 跑一遍对照即可。你不需要相信一个黑盒。 |

<details>
<summary><strong>与 PMM、MySQL Enterprise Monitor、mysqltuner、innotop 的区别</strong></summary>

mysqlbot 是**随手跑一次的诊断**，不是需要长期运营的监控平台。想要看板、告警、长期保留、
多实例汇总，请用 PMM 或 MySQL Enterprise Monitor —— mysqlbot 不替代它们。想要"不部署任何
东西、十秒内拿到答案"，triaging 一台不是自己负责的库，需要把结论交给别人，或者让 CI 因为
某个数据库风险而挂掉构建 —— 那时用 mysqlbot。

相比经典的 one-shot 脚本（`mysqltuner.pl`、`tuning-primer.sh`），实质差别在于：结论带上
`severity` / `dimension` / `scope` / `exactness` 元数据而不是散文；每一次跳过都带结构化原因；
同一份数据有机器可读的契约；以及"规则与版本是否相容"是**机器校验**的，不是假定。

</details>

## 环境要求

- MySQL **5.7 – 9.7**（见[版本支持](#版本支持)）；MariaDB 未验证。
- `PATH` 上有 `mysql` **客户端**（或 `pip install pymysql` 后用 `--driver pymysql`）。
- Python 3.9+ —— 只用标准库，没有依赖要装。
- 一个登录账号，只读账号就够 —— 见[只读账号](#只读账号)。账号被授了什么权限，决定了 42 条
  规则里能跑多少条，而工具会把这件事报告出来，而不是藏起来。
- `performance_schema=ON`（约 17 条规则读它）。

## 看一眼输出

**`mbot check`** —— 默认报告：一行总览，然后按严重度列出命中项，含规则 id、维度、对象、
行数与一句话说明。

```
$ ./bin/mbot check --socket … -u mbot_reader -p '…' --label sandbox-fixture
────────────────────────────────────────────────────────────────────────────────────────
mysqlbot · sandbox-fixture · MySQL 9.7.2 · user=mbot_reader@%
生成 2026-09-17 08:57:59
────────────────────────────────────────────────────────────────────────────────────────
🟡 WARN      命中 18   干净 16   跳过  8   失败  0   （共 42 条规则）
────────────────────────────────────────────────────────────────────────────────────────
        ⋮
[WARN] blocking_chains  (risk/workload, 1 行)
        存在行锁等待链（有事务在等另一事务持有的行锁）
        · severity=warn  locked_schema=mysqlbot_test  locked_table=lock_target  locked_index=PRIMARY  locked_type=RECORD  waiting_lock_mode=X,REC_NOT_GAP  waiting_lock_data=1  wait_seconds=78  waiting_pid=19  waiting_user=root  waiting_query=UPDATE lock_target SET v = v + 1 WHERE …  blocking_pid=18  blocking_user=root  blocking_trx_id=2199  suggested_kill=KILL 18;  _fingerprint=5f10b3dbdfa2
        ⚠ 含可执行语句: KILL <blocking_pid>
        ⋮
[WARN] idle_in_transaction  (risk/workload, 1 行)
        事务开着但没有语句在执行
        · severity=warn  trx_state=RUNNING  started_at=2026-09-17 08:56:37  open_seconds=82  thread_id=18  db_user=root  client_host=localhost  rows_locked=1  _fingerprint=9133507b602c
        ⋮
[WARN] table_without_primary_key  (risk/schema, 1 行)
        InnoDB 表没有主键（也没有等效的唯一非空索引）
        · severity=info  table_schema=mysqlbot_test  table_name=nopk_big  estimated_rows=197077  size_mb=47.6  _fingerprint=b3e9f2d9d66f
        ⋮
[INFO] redundant_index  (hygiene/schema, 1 行)
        冗余索引（存在可覆盖它的其它索引）
        · severity=info  table_schema=mysqlbot_test  table_name=dup_idx  redundant_index=idx_user_dup  redundant_columns=user_id  dominant_index=idx_user  dominant_columns=user_id  table_size_mb=0.5  suggested_drop=ALTER TABLE `mysqlbot_test`.`dup_idx` D…  _fingerprint=b13f600fc0b6
        ⚠ 含可执行语句: DROP INDEX
        ⋮
提示：-v 显示处置建议，-o json 输出完整契约，-o markdown 生成报告。
        ⋮
未覆盖 8 条（不等于干净，按规则看原因）：
  - binlog_retention_unbounded_57: MySQL >= 8.0 已移除该信号源
  - blocking_chains_57: MySQL >= 8.0 已移除该信号源
  - buffer_pool_hit_low: 实例运行时间不足：累计计数器需要 1.0 小时，当前仅 1 分钟（重启后计数器清零，此刻结论不可信）
  - sort_merge_passes: 实例运行时间不足：累计计数器需要 1.0 小时，当前仅 1 分钟（重启后计数器清零，此刻结论不可信）
  - table_open_cache_miss: 实例运行时间不足：累计计数器需要 1.0 小时，当前仅 1 分钟（重启后计数器清零，此刻结论不可信）
  - thread_cache_miss: 实例运行时间不足：累计计数器需要 1.0 小时，当前仅 1 分钟（重启后计数器清零，此刻结论不可信）
  - tmp_table_disk_spill: 实例运行时间不足：累计计数器需要 1.0 小时，当前仅 1 分钟（重启后计数器清零，此刻结论不可信）
  - unused_index: 实例运行时间不足：累计计数器需要 3.0 天，当前仅 1 分钟（重启后计数器清零，此刻结论不可信）
        ⋮
缺失能力位: sys_functions
⚠ 实例启动仅 111 秒，累计型指标（命中率等）暂不可信
```

<sub>真实运行节选 —— 一次性实例，违规由 `tests/run_tests.sh` 种下（18 条命中里展示 4 条）。
注意底部的「未覆盖」块：6 条因为是**运行时长**门禁（刚起的实例，累计型计数器还没有意义）、
2 条因为是**版本**门禁，每条都写明了原因。这就是"没检查"与"没问题"的区别。</sub>

**`mbot coverage --at 9.7`** —— 离线版本推演。不连库、不需要凭据：回答"我的规则在这一版上
哪些会跑、哪些是设计上就门禁掉的、哪些会**失败**（因为引用了该版本没有的信号）"。

```
$ ./bin/mbot coverage --at 9.7
目标版本 MySQL 9.7  —— 纯静态推演，未连接实例
支持下界 5.7 · 参与推演 42 条规则

  预计运行       40
  版本门禁跳过    2   （区间不符，设计如此）
  版本风险        0   （硬引用的信号在这一版不存在，执行会失败）

门禁跳过：
  binlog_retention_unbounded_57      MySQL >= 8.0 已移除该信号源
  blocking_chains_57                 MySQL >= 8.0 已移除该信号源

版本变体分组：binlog_retention_unbounded、blocking_chains
  binlog_retention_unbounded: binlog_retention_unbounded [8.0~∞)  |  binlog_retention_unbounded_57 [5.7~8.0)
  blocking_chains: blocking_chains [8.0~∞)  |  blocking_chains_57 [5.7~8.0)
```

`coverage --matrix` 一次打印整张网格：

```
$ ./bin/mbot coverage --matrix
  合计 5.7: ●38 ○4 ✗0   8.0: ●40 ○2 ✗0   8.4: ●40 ○2 ✗0   9.0: ●40 ○2 ✗0   9.7: ●40 ○2 ✗0
```

`●` 可运行 · `○` 版本门禁（设计如此） · `✗` 版本风险（跑会失败）。

**`mbot doctor`** —— 连库自检。注意最后一行：工具自带的版本信号登记表会与真实实例对账，
过期会被抓出来，而不是继续给出合理但错误的结论。

```
$ ./bin/mbot doctor --host 127.0.0.1 -u mbot_reader -p '…'
mysql 客户端 : /opt/homebrew/bin/mysql
规则目录     : ./rules 存在
规则         : 42 条，解析错误 0 个
连通性       : OK —— MySQL 9.7.2 / user=mbot_reader@%
能力位       : 14 开 / 3 关
              关闭的：audit_admin, super, sys_functions
可见 schema  : 1 个（mysqlbot_test）
会话前导     : ['SET SESSION information_schema_stats_expiry = 0']
信号登记表   : ✓ 21 个变量信号，实例存在 18 个，与登记区间吻合
```

**`mbot probe`** —— 只看能力位，也就是"这个账号给够权限了吗"。它同时回答了 MySQL 体检
里最常见的假警报：报告看着干净，只因为账号根本看不见问题。

```sh
./bin/mbot probe --host 127.0.0.1 -u mbot_reader -p '…'
```

## 命令与参数

| 命令 | 作用 |
|---|---|
| `check` | 体检报告（默认 `-o table`，可选 `json` / `markdown` / `sarif`） |
| `probe` | 只探能力位 —— 账号权限给够了吗 |
| `list` | 列出规则及其元数据，过滤参数与 `check` 一致 |
| `lint` | 校验规则契约与版本一致性 —— **不需要数据库**，可以直接进 CI |
| `docs` | 由规则头部重新生成规则目录（`docs/findings.md`） |
| `doctor` | 自检：客户端、规则目录、连通性、能力位、信号登记表对账 |
| `coverage` | 离线版本推演：`--at 9.7`，或 `--matrix` 出全网格 |

常用参数：

| 参数 | 说明 |
|---|---|
| `-o, --output table\|json\|markdown\|sarif` | 输出格式；`sarif` 接 GitHub Code Scanning |
| `--fail-on none\|info\|warn\|critical` | 命中达到该严重度时退出码为 1（默认 `warn`） |
| `--only` / `--skip` | 只跑 / 跳过这些规则 id（支持 glob，可重复） |
| `--dimension` / `--scope` / `--tag` / `--min-severity` | 缩小规则范围 |
| `--label` | 报告里显示的实例标签 |
| `--timeout` | 单条规则超时秒数 |
| `--defaults-file` | 把 `[client]` 配置文件交给 `mysql` 客户端（login-path、socket、TLS） |
| `--driver auto\|cli\|pymysql` | 默认 `cli`；`pymysql` 的类型与 NULL 更精确，适合脚本化集成 |
| `--no-init` | 不注入会话前导（见下面的坑） |
| `--ignore-min-uptime` | 忽略运行时长门禁 —— 仅用于演练，会让累计型指标失真 |

退出码是脚本化契约：

| 码 | 含义 |
|---|---|
| `0` | 跑完且没有达到 `--fail-on` 的命中 |
| `1` | 有达到 `--fail-on` 的命中（`coverage` 发现版本风险也算） |
| `2` | 连接或执行失败 |
| `3` | 契约不成立（例如 `lint` 发现某条规则违反了自己的声明） |

## 安装

```sh
git clone https://github.com/wgzhao/mysqlbot.git
cd mysqlbot
./bin/mbot doctor --host 127.0.0.1 -u root -p '…'
```

`bin/mbot` 是个小启动器：把仓库根加进 `PYTHONPATH`，再调用 `python -m mbot`。
可用 `MYSQLBOT_PYTHON` 指定解释器，或把它挂到 `PATH` 上：

```sh
export PATH="$PWD/bin:$PATH"     # 之后直接 mbot check --host …
```

没有需要安装的包，也就没有需要卸载的东西 —— 不建状态目录、不起守护进程、不装 launch agent。
唯一可选依赖是 `PyMySQL`，只在你要 `--driver pymysql` 时才惰性导入。

## 只读账号

只读保证靠的是**账号**，不是开关。`sql/readonly_account.sql` 提供两档授权：

- **A 档 —— 一行业务数据都读不到**：`PROCESS` + `REPLICATION CLIENT` +
  `SELECT ON performance_schema.*` + `SELECT ON sys.*`，覆盖 42 条里的 36 条。
- **B 档 —— A 档 + 业务 schema 的 `SELECT`**：解锁 6 条结构类规则（无主键表、冗余/未使用
  索引、超大表等）。

自己写授权之前，有两件事实值得先知道：

- **`PROCESS` 换不来 `performance_schema` 的读权限。** `PROCESS` 让 `SHOW PROCESSLIST`
  能看到别的会话，但 `performance_schema.threads`、`data_locks`、`metadata_locks`、
  `events_statements_summary_by_digest` 在没有显式 `SELECT ON performance_schema.*` 时
  统统返回 `ERROR 1142`。mysqlbot 会直接指出缺哪个能力位，而不是悄悄给出残缺的结论。
- **MySQL 没有 `pg_monitor`。** `information_schema` 是按权限过滤的，所以不存在 PostgreSQL
  那样的"能看全库元信息、碰不到数据"的角色。A 档是最接近的诚实取舍：不碰业务数据，代价是
  那 6 条结构规则。权限到规则的完整对应关系写在
  [`docs/compat-matrix.md`](docs/compat-matrix.md) 里。

```sh
# 先看，再自己执行 —— mysqlbot 不执行任何 DDL/DCL
less sql/readonly_account.sql
```

### 对数据库的开销

一条连接、一次一条规则、只有 `SELECT`。规则在同一个会话里顺序执行，逐条受 `--timeout` 约束，
正常实例上整轮几秒结束。累计型计数器按原样读取（报告里标 `cumulative`）；任何需要"增长率"的
东西**都不猜** —— 工具给出当前值并说明这一点。对繁忙的主库跑到安全，且不会留下未结束的事务。

会话前导是为了**正确性**而不是速度：自 MySQL 8.0 起 `information_schema` 的表统计默认缓存
24 小时（`information_schema_stats_expiry=86400`），所以每条规则都在
`SET SESSION information_schema_stats_expiry = 0` 之后执行。少了它，表大小、行数、索引基数
可能是一天前的值，容量类结论就是错的。`--no-init` 能关掉它 —— 别关。

## 指向你的数据库

按你的环境挑一种连接方式 —— 参数、DSN、socket，或者 `mysql` 客户端自己的配置文件：

```sh
./bin/mbot check --host db.example.com --port 3306 -u mbot_reader -p '…'
./bin/mbot check --dsn 'mysql://mbot_reader:…@db.example.com:3306/'
./bin/mbot check --socket /var/run/mysqld/mysqld.sock -u mbot_reader -p '…'
./bin/mbot check --defaults-file /etc/mysql/mysqlbot.cnf     # [client] 段
```

因为传输走的是 `mysql` 客户端，它支持的东西都能用 —— 带 login-path 的 `--defaults-file`、
unix socket、TLS、`[client]` 分组。库在内网时，常见做法是 SSH 端口转发后给
`--host 127.0.0.1 --port <转发端口>`，或者直接用 socket；mysqlbot **没有内置 SSH 隧道**
（在路线里）。

## 采集什么

全部来自 SQL，分四个维度：

| 维度 | 条数 | 代表规则 |
|---|---|---|
| `risk` | 16 | 行锁等待链、元数据锁等待、长事务与 idle-in-transaction、无主键表、提交不落盘、非 InnoDB 表 |
| `latency` | 12 | 缓冲池命中率、临时表落盘、累计耗时最高的语句、全表扫描放大、索引统计失真、表缓存未命中 |
| `hygiene` | 7 | 冗余索引、未使用索引、慢查询日志未开、`long_query_time` 过高、`sql_require_primary_key` 未开、索引统计过期 |
| `capacity` | 7 | 超大表、连接余量、binlog 永不清理、`innodb_file_per_table` 关闭、自增主键接近上限 |

每条规则带 `severity`（`critical` 2 / `warn` 24 / `info` 16）、`scope`
（`instance` / `workload` / `schema` / `cluster` / `history`），以及一个 `exactness`
标签，用来告诉你这个数字能信到什么程度：

| `exactness` | 含义 |
|---|---|
| `exact` | 直接读出的事实（变量、版本、定义） |
| `catalog` | 来自数据字典的确定结构 |
| `cumulative` | 自实例启动累计的计数器，重启清零 |
| `sampled` | 依赖统计采样，需要足够运行时长才可信 |
| `scraped` | 从某处抓取的瞬时值 |
| `unavailable` | 本次未能获取 |

完整目录（每条规则的处置建议、误报条件与 SQL 源码）由规则头部生成到
[`docs/findings.md`](docs/findings.md)，一份完整的样例报告在
[`docs/sample-report.md`](docs/sample-report.md)。

## 规则契约

一条规则 = 一个 `.sql` 文件：`-- @key: value` 头部，之后是查询。

```sql
-- @id: blocking_chains_57
-- @title: 存在行锁等待链（5.7 路径）
-- @severity: warn
-- @dimension: risk
-- @scope: instance
-- @requires: p_s_locks
-- @exactness: catalog
-- @since: 5.7
-- @removed_in: 8.0
-- @variant_of: blocking_chains     -- 与基础规则成对，lint 断言两者无缝覆盖 [5.7, +∞)
-- @min_uptime: 0
-- @remediation: …
-- @caveats: …
-- @safety: KILL <blocking_pid>
-- @safety_note: …
SELECT …   -- 返回 0 行 = 未命中；返回行 = 命中；每行必须含 severity 列
```

`./bin/mbot lint` 强制校验三类事情：

- **元数据完整性** —— 受控词表（`dimension`、`scope`、`exactness`）、`@safety` 必须配
  `@safety_note`、SQL 必须出现 `severity`；
- **声明与正文是否一致** —— `@since` 是否比正文实际引用的信号所需的版本更宽（跨次版本是
  错误，同线补丁级是提示），以及硬引用了有上界的信号是否声明了 `@removed_in`；
- **变体覆盖无空洞** —— 一个逻辑规则的变体集合必须无缝覆盖 `[5.7, +∞)`。有空洞意味着规则
  在某些版本上**静静地不跑** —— 连"跳过"都不会出现。

带可执行处置的规则（`DROP INDEX`、`KILL`）在报告里会被单独标注，因为一条能直接粘贴的修复
命令，也是一条能粘错的命令。

## 版本支持

规则声明自己的可用区间，一张信号登记表（`mbot/signals.py`）反过来核对声明与 SQL 实际引用的
信号。已在真实实例上验证：

| 层级 | 版本 | 依据 |
|---|---|---|
| **已实测** | MySQL 5.7.44、Percona 8.0.43、MySQL 8.4.11、MySQL 9.7.2 | 完整一轮：**0 条规则执行失败**；离线推演与实测行为完全吻合 |
| 针对性复验 | MySQL 8.0.25 | 修掉一个 8.0 早期版本特有的跳过 |
| 仅推演 | MySQL 9.0 | `coverage --at 9.0`（非 LTS，手上没有实例） |
| 未覆盖 | 8.1–8.3、9.1–9.6、MariaDB | 没有测过的实例；`coverage` 仍能回答静态问题 |

信号缺失时是**降级**而不是失败：

| 信号情形 | 行为 |
|---|---|
| 变量在新版本被移除 | 用软查表读（`MAX(CASE WHEN VARIABLE_NAME='…')`），返回 NULL 让规则自己退化 —— 这就是 8.4/9.x 上那三个被移除的变量**不需要改一行 SQL** 的原因 |
| 规则**硬引用**某变量 | 该变量缺失时规则直接报错（`ERROR 1193`）而不是悄悄跳过 —— 版本区间写错是工具缺陷 |
| 表/列不存在 | 归类为 `missing_object` 并带原因跳过，失败计数因此仍然有意义 |
| 版本低于 `@since` | 门禁：`skip_kind=version`，并打印原因 |

手上没有某个版本时，`mbot coverage` 是最省事的回答方式：

```sh
./bin/mbot coverage --at 8.0.43     # 精确：8.0.43
./bin/mbot coverage --at 5.7        # = 5.7.999，即"实际部署中的 5.7 线"
./bin/mbot coverage --matrix
```

> `--at 5.7` 会补成 **5.7.999**，不是 5.7.0：现实里"跑在 5.7 上"指的是 5.7.3x–5.7.44，
> 往下取整会把真能跑的规则判成不可用。**推演比现实悲观，也是在说谎。** 要严格判定就写全
> 补丁号（`--at 5.7.0`）。

## JSON 契约

`-o json` 是拿来对接的接口：一份带版本的文档（`"schema": "mysqlbot/report/v1"`），含能力位、
每条规则的结果、跳过原因与类型，以及每个命中项背后的原始行 —— 消费方不必去解析人读表格。

```sh
./bin/mbot check --host … -o json --out-file report.json
./bin/mbot check --host … -o json | jq '.outcomes[] | select(.skip_kind=="permission")'
```

三个让它值得脚本化的性质：

- **`skip_kind` 是结构化的**，不是散文：`version` / `uptime` / `capability` / `permission` /
  `missing_object`。因此 CI 断言可以区分"因为版本而跳过"和"因为账号缺授权而跳过"。匹配中文
  reason 会判错 —— 兼容性对账的第一版就把 `执行被拒（Table 'x' doesn't exist）` 归进了
  "权限跳过"，给出一个假的"全部一致"。
- **截断是显式的。** 规则都带 `LIMIT` 以免刷屏；行数触顶时报告写 `≥N`，JSON 里置
  `truncated: true`。
- **每个命中项有指纹**（`_fingerprint`），因此两次运行之间的 diff 不必解析散文。

## CI 集成

`--fail-on` 让退出码与默认严重度映射解耦，`-o sarif` 输出
[SARIF 2.1.0](https://sarifweb.azurewebsites.net/) 供 GitHub Code Scanning 使用：

```bash
./bin/mbot check --host "$DB_HOST" -u mbot_reader -p "$DB_PASSWORD" \
  --fail-on critical -o sarif --out-file mbot.sarif
```

```yaml
- name: mysqlbot
  run: ./bin/mbot check --host ${{ secrets.DB_HOST }} -u mbot_reader \
         -p "${{ secrets.DB_PASSWORD }}" --fail-on critical -o sarif --out-file mbot.sarif
- uses: github/codeql-action/upload-sarif@v3
  with:
    sarif_file: mbot.sarif
```

两点提醒：`--fail-on` 一般设成 `critical`；跳过的规则不影响退出码，所以"跳过率变高"这类
判断退出码表达不了，要的话去解析 `-o json`。另一个适合进 CI 的命令是 `lint` —— 它完全不需要
数据库。

## 自测

```sh
# ① 单测 —— 不连库，秒级
tests/unit.sh                    # = test_grants + test_classify + test_signals

# ② 端到端回归：种违规 → 只读账号巡检 → 硬断言
tests/local_instance.sh start    # /tmp 下起一个一次性实例
tests/run_tests.sh
tests/local_instance.sh stop

# ③ 跨版本兼容性：对任意真实实例断言「42 条规则全部执行成功、0 条报错」
#    并做「离线推演 ↔ 实测」对账
tests/live_compat.sh --defaults-file ~/.my.cnf --label '8.0.43'
```

②断言三件事：**没有规则执行报错**、植入的违规全部命中、跳过项摊开列出。
③是让上面那张版本表有意义的依据 —— 登记表如果相对服务器实际行为过期了，它会直接失败。

单测的存在是为了一类特定的缺陷：**"不报错但结论错"**。授权解析错只会让工具*声称*自己有能力；
错误分类错会让真缺陷伪装成"跳过"；登记表过期会让推演给出合理但错误的答案。这些端到端都抓不到。

## 路线与非目标

- **mysqlbot 永不写库。** 它建议索引改动，但不创建；也不 kill 会话。没有开关能打开这件事。
- **主机层指标**（CPU、磁盘 IOPS、空闲内存）无法通过 SQL 连接获取，因此结构上就不在范围内。
- **不做索引建议验证。** MySQL 没有 hypopg 等价物，所以无法像 pgbot 在 PostgreSQL 上那样
  让规划器证明某个建议索引会被采用。
- 接下来：输出文案的英文/i18n、用 `mbot.toml` 覆盖阈值而不改 SQL、基线对比（保存上次 JSON
  并 diff）、在真实从库上验证复制类规则、MariaDB 实测、把依赖 `sys` 视图的索引规则改自研。

### 已知边界

如实列出，因为一份体检报告的可信度不会超过它所声明的覆盖范围：

- **复制类规则从未在真实从库上跑过** —— 用于验证的实例都不是从库。
- **两条锁等待规则未在真实争用下做交叉比对**（`blocking_chains` 读 8.0 的 `data_lock_waits`，
  `blocking_chains_57` 读 5.7 的 `INNODB_LOCK_WAITS`）。已验证的是"无争用返回 0 行"，以及
  各自在**植入**的争用场景下命中。
- **结构类规则只覆盖账号能看见的 schema。** 报告因此会打印 `visible_schemas`：只说
  "没有无主键的表"而不说"是在哪几个库里"，等于什么都没说。
- **`LIMIT` 截断是真实存在的。** 报 50 行的规则可能只是几百行里的前 50 行：报告写 `≥N`，
  JSON 里置 `truncated: true`。别把"N 行"当全量读。

## 疑难排查

<details>
<summary><strong>某条规则被跳过了 —— 这和"干净"是一回事吗？</strong></summary>

不是，报告也从不会这么说。跳过都带 `skip_kind`：
`version`（在该规则声明的区间之外，设计如此）、
`uptime`（实例运行时间还不足以让累计型计数器有意义）、
`capability` / `permission`（账号看不到这条规则要读的东西）、
`missing_object`（表或列不存在）。
在 JSON 里它是字段 —— 所以请把跳过当作**覆盖范围**汇报，而不是当作健康度。

</details>

<details>
<summary><strong>报告全干净，但库明显变慢了</strong></summary>

先跑 `./bin/mbot probe`。报告的视野宽度就是账号权限的宽度：A 档授权下那 6 条结构规则跑不了；
没有 `SELECT ON performance_schema.*` 时，语句级延迟规则会被整片跳过。总览行永远打印跳过数，
正是为了这个。

</details>

<details>
<summary><strong>明明有 <code>PROCESS</code>，读 <code>performance_schema</code> 还是 Access denied</strong></summary>

预期之内。`PROCESS` 不能替代 `SELECT ON performance_schema.*` —— `threads`、`data_locks`、
`metadata_locks`、`events_statements_summary_by_digest` 没有它一律返回 1142。
要授的是读权限，不是 process 权限。

</details>

<details>
<summary><strong>授了 <code>SELECT ON sys.*</code>，sys 视图仍报 1356 / 1370</strong></summary>

`sys` 视图是 `SQL SECURITY INVOKER`，并且会调用一些函数，其 `DEFINER`
（`mysql.sys@localhost`）只有 `USAGE` —— 低权限账号执行不了。mysqlbot 因此直接读
`performance_schema`，不依赖 `sys` 的格式化视图；仍然使用 `sys` 的那两条索引规则，在视图不可用
时会带能力位原因跳过。

</details>

<details>
<summary><strong>结论看起来是旧的，或者表大小不对</strong></summary>

确认会话前导进来了 —— 每条规则都应当在 `SET SESSION information_schema_stats_expiry = 0`
之后执行。自 MySQL 8.0 起 `information_schema` 统计默认缓存 24 小时，表行数、大小与索引基数
可能是一天前的值。`doctor` 会把将要使用的会话前导打印出来；`--no-init` 是唯一关掉它的方式
（别关）。

</details>

<details>
<summary><strong>为什么输出是中文？</strong></summary>

报告文案目前是中文；规则 id、JSON 键名与枚举值是英文且稳定。解析 `-o json` 完全绕开这个
问题，人读标签的 i18n 在路线里。`-o markdown` 生成的报告可以直接贴进工单或 wiki。

</details>

<details>
<summary><strong><code>@since: 5.7</code> 表示每个 5.7 补丁版本都测过吗？</strong></summary>

不是。它表示信号自 5.7 起存在，且该规则已在 5.7.44 上实测执行通过。有两条规则的补丁级下界
是登记表发现的（`metadata_lock_wait` 需要 5.7.3 的 `metadata_locks`、`replica_writable`
需要 5.7.8 的 `super_read_only`）—— 那些下界来自官方文档与单测，不是来自那个补丁版本的实例。

</details>

## 隐私

除了你指定的那条数据库连接，没有任何东西离开你的机器。没有遥测、没有更新检查，代码里也没有
任何形式的网络访问 —— 不调用模型，不上传报告。工具不往目标库写任何东西，除了 `--out-file`
指定的报告文件之外也不在主机上落盘。连接信息不会被持久化到任何地方。

## 贡献

欢迎 issue 与 PR。最重要的三条不变量，按优先级：

1. **只读。** 任何规则都不得写库，任何 mysqlbot 打印出来的处置命令都不得由 mysqlbot 自己执行。
2. **结论确定性。** 规则自己算出结论，不由模型推断。
3. **降级必须可见。** 判断不了的东西要**带结构化原因**跳过 —— 绝不静默丢弃，绝不报成干净。

开发回路：

```sh
./tests/unit.sh                  # 单测（不连库）
./bin/mbot lint                  # 规则契约与版本一致性（不连库）
./bin/mbot docs --out-file docs/findings.md    # 重新生成规则目录
./bin/mbot coverage --matrix     # 版本网格必须保持 ✗0
tests/local_instance.sh start && tests/run_tests.sh && tests/local_instance.sh stop
```

新增或修改规则后，请对**你声称支持的每一个版本**跑一次 `live_compat.sh` —— 那张版本表才是
交付物，而"在 5.7 上通过、在 8.4 上炸"正是只在单台服务器上做端到端测试看不见的一类缺陷。
新增一个版本的流程是五步，写在 [`docs/versioning.md`](docs/versioning.md) 里。

## 安全

mysqlbot 会用你提供的凭据连接数据库并读取统计信息。报告漏洞请使用 GitHub 的
**private vulnerability reporting**（Security → Report a vulnerability），不要开公开 issue。
也请不要把连接串、真实主机名或生产库表名贴进 issue —— 项目自身的文档刻意使用中性占位名
（`app_db`、`biz_db`、`t1` …），正是出于同样的考虑。

## 目录结构

```
bin/mbot          启动器（把仓库根加进 PYTHONPATH，调用 python -m mbot）
mbot/
├── rule.py       规则头部解析、版本与受控词表
├── signals.py    版本敏感信号登记表 + 离线推演 + 变体覆盖检查
├── conn.py       连接层（mysql 客户端 / PyMySQL）+ 错误分类
├── probe.py      能力位探测、实例事实、信号登记表 attestation
├── runner.py     门禁编排（版本 → 运行时长 → 能力位）+ 结构化 skip_kind
├── report.py     table / json / markdown / sarif 四种渲染
└── cli.py        check · probe · list · lint · doctor · docs · coverage
rules/            42 条规则，每条一个 .sql 文件
sql/              只读账号脚本（两档授权）
tests/            单测、端到端回归、跨版本兼容性
docs/             设计记录、版本兼容架构、验证矩阵、生成的规则目录
```

## 延伸阅读

| 文档 | 内容 |
|---|---|
| [`docs/design.md`](docs/design.md) | 设计决策与在真实实例上踩过的 20 个坑（症状 → 根因 → 解决） |
| [`docs/versioning.md`](docs/versioning.md) | 为什么版本兼容是元数据而不是目录；新增版本的五个步骤 |
| [`docs/compat-matrix.md`](docs/compat-matrix.md) | 逐版本结果、版本敏感信号对照表、权限到规则的映射 |
| [`docs/findings.md`](docs/findings.md) | 全部 42 条规则的生成目录，含处置建议与误报条件 |
| [`docs/sample-report.md`](docs/sample-report.md) | 沙箱实例上的完整样例报告 |
| [`SKILL.md`](SKILL.md) | 把 mysqlbot 当作 agent skill 使用 |

## 许可证

尚未添加许可证文件，按默认即"保留所有权利"。如果你需要复用或分发，请开 issue 一起定一个。
