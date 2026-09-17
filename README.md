<h1 align="center">mysqlbot</h1>

<p align="center">
  <strong>Read-only, deterministic MySQL health checks.</strong><br>
  42 SQL rules read the server's own statistics and catalog and print a findings-first
  report — plus an offline answer to "would these rules run on version X?"<br>
  No agent, no daemon, no write privilege anywhere in the path, and every rule is
  runnable by hand in your own client.
</p>

<p align="center">
  <img alt="MySQL 5.7–9.7" src="https://img.shields.io/badge/MySQL-5.7%E2%80%939.7-4479A1">
  <img alt="Python 3.9+" src="https://img.shields.io/badge/python-3.9%2B-3776AB">
  <img alt="No dependencies" src="https://img.shields.io/badge/dependencies-none-brightgreen">
  <img alt="No writes" src="https://img.shields.io/badge/writes-none-blue">
</p>

<p align="center">
  <a href="#quickstart">Quickstart</a> ·
  <a href="#install">Install</a> ·
  <a href="#setup--a-read-only-account">Setup</a> ·
  <a href="#commands-and-flags">Commands</a> ·
  <a href="#see-it">See it</a> ·
  <a href="#version-support">Version support</a> ·
  <a href="#the-json-contract">JSON contract</a> ·
  <a href="#ci-integration">CI</a> ·
  <a href="#troubleshooting">Troubleshooting</a>
</p>

<p align="center">
  <strong>English</strong> · <a href="README_CN.md">中文</a>
</p>

> **Status: beta.** The JSON contract is versioned (`"schema": "mysqlbot/report/v1"`) and
> breaking changes to it are treated as breaking changes to the tool. The human-readable
> table is **not** a stable interface — parse `-o json`, not the terminal output.
> Two honest caveats: the tool's own output vocabulary is **Chinese** today
> (i18n is on the [roadmap](#roadmap-and-non-goals)), and the long-form design docs are
> Chinese-only as well.

---

## Quickstart

```sh
git clone https://github.com/wgzhao/mysqlbot.git
cd mysqlbot

# 0. self-check: client, rules, connectivity, capability bits,
#    and the version-signal registry attested against the live instance
./bin/mbot doctor --host 127.0.0.1 -u root -p 'your-password'

# 1. the health report (human-readable table by default)
./bin/mbot check --host 127.0.0.1 -u mbot_reader -p 'your-password'
```

You do not have to pass the password on the command line. The `mysql` client's own
configuration works, and every connection setting has an environment variable:

```sh
export MYSQLBOT_HOST=127.0.0.1
export MYSQLBOT_USER=mbot_reader
export MYSQLBOT_PASSWORD='…'
./bin/mbot check

# or reuse the login path / ~/.my.cnf you already have:
./bin/mbot check --defaults-file ~/.my.cnf

# or a single DSN:
./bin/mbot check --dsn 'mysql://mbot_reader:…@127.0.0.1:3306/'
```

Credentials resolve in this order: explicit flags, then `MYSQLBOT_*` environment
variables (`MYSQLBOT_DSN` / `MYSQLBOT_HOST` / `MYSQLBOT_PORT` / `MYSQLBOT_USER` /
`MYSQLBOT_PASSWORD` / `MYSQLBOT_SOCKET`), then whatever the `mysql` client itself
would read. `MYSQL_PWD` is honoured as a fallback for the password.

```
🟡 WARN      命中 18   干净 16   跳过  8   失败  0   （共 42 条规则）
```

Read that line carefully — it is the whole design in miniature. `命中` (hit) is what
you act on, `干净` (clean) is what was actually verified, and `跳过` (skipped) is what
**could not be judged**, always with a reason. Skipped is not clean. `失败` (failed)
should be 0 — a non-zero failure count means a rule's SQL doesn't match the target
server, which is a bug in the tool, not an environment limitation.

## Why mysqlbot

| | |
|---|---|
| **Read-only by role, not by flag** | The boundary is the `GRANT` on the account you hand it. The tool chain contains no write path: it opens one `mysql` client connection and every rule is a `SELECT`. Remediation that *would* write (`DROP INDEX`, `KILL`, `SET GLOBAL`) is printed as a suggestion for a human to run — mysqlbot never executes it. |
| **Findings are computed, not generated** | 42 rules are 42 pure SQL statements; no model participates in judging. The `severity` column even lets SQL upgrade its own row — a lock wait past 300 s reports as `critical`. |
| **Degrade, never lie** | Missing privilege, wrong version, instance uptime too short → the rule is **explicitly skipped with a machine-readable reason** (`skip_kind`), never folded into "clean". The inverse also holds: a rule whose SQL doesn't match the target version is a **failure**, not a skip — otherwise a broken rule could disguise itself as an environment limitation. |
| **Nothing to deploy** | Stdlib-only Python 3.9+ plus the `mysql` client you already have. No daemon, no collector, no time-series database, no config file you must remember to keep. |
| **Version-aware as a contract, not a folder** | Rules declare `@since` / `@removed_in`; a signal registry cross-checks those declarations against the version-sensitive signals the SQL actually references. `mbot coverage --at 9.7` answers "would these run there?" **without connecting**. |
| **Verifiable by hand** | Every rule stands alone: paste it into `mysql` or DBeaver and compare. You are not asked to trust a black box. |

<details>
<summary><strong>How it differs from PMM, MySQL Enterprise Monitor, mysqltuner, innotop</strong></summary>

mysqlbot is a **point-in-time diagnostic you run**, not a monitoring platform you
operate. If you want dashboards, alerting, retention and multi-host rollups, run PMM or
MySQL Enterprise Monitor — mysqlbot does not replace them. Reach for mysqlbot when you
want an answer in seconds without deploying anything, when you're triaging a database
you don't own, when you need SQL-compatible findings you can hand to someone else, or
when a CI pipeline needs to fail a build on a database risk.

Compared with the classic one-shot scripts (`mysqltuner.pl`, `tuning-primer.sh`),
the differences that matter are: findings carry `severity` / `dimension` / `scope` /
`exactness` metadata instead of prose, every skip carries a structured reason, the same
data is available as a machine-readable contract, and rule-vs-version compatibility is
machine-checked rather than assumed.

</details>

## Requirements

- MySQL **5.7 – 9.7** (see [Version support](#version-support)); MariaDB is not verified.
- The `mysql` **client** on `PATH` (or `pip install pymysql` and `--driver pymysql`).
- Python 3.9+ — standard library only, nothing to install.
- A login account; a read-only one is enough — see
  [Setup](#setup--a-read-only-account). What the account is granted determines how many
  of the 42 rules can run, and the tool reports that difference instead of hiding it.
- `performance_schema=ON` for the ~17 rules that read it (`--requires p_s`).

## See it

**`mbot check`** — the default report: one headline line, then findings by severity with
the id, dimension, object, row count and a one-line explanation.

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

<sub>Excerpt of a real run — a throwaway instance with violations planted by
`tests/run_tests.sh` (4 of the 18 findings shown). Note the skipped block at the bottom:
six rules were gated on **uptime** (a fresh instance's cumulative counters mean nothing
yet) and two on **version**, each with its reason spelled out. That is the difference
between "not checked" and "clean".</sub>

**`mbot coverage --at 9.7`** — offline version simulation. No connection, no credentials:
this answers "which of my rules would run on that version, which are gated by design,
and which would **fail** because they reference a signal that version doesn't have".

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

`coverage --matrix` prints the whole grid at once:

```
$ ./bin/mbot coverage --matrix
  合计 5.7: ●38 ○4 ✗0   8.0: ●40 ○2 ✗0   8.4: ●40 ○2 ✗0   9.0: ●40 ○2 ✗0   9.7: ●40 ○2 ✗0
```

`●` runnable · `○` gated by version (by design) · `✗` version risk (would fail).

**`mbot doctor`** — connect-time self-check. Note the last line: the tool's own
version-signal registry is attested against the live server, so a registry that has gone
stale is caught rather than silently producing wrong conclusions.

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

**`mbot probe`** — capability bits only, i.e. "did I grant this account enough?".
This is the answer to the most common false alarm in MySQL health checking: a report
that looks clean because the account simply couldn't see the problem.

```sh
./bin/mbot probe --host 127.0.0.1 -u mbot_reader -p '…'
```

## Commands and flags

| Command | What it does |
|---|---|
| `check` | the health report (`-o table` default, or `json` / `markdown` / `sarif`) |
| `probe` | capability bits only — is the account granted enough? |
| `list` | the rules with their metadata, filtered the same way as `check` |
| `lint` | validate the rule contracts and version consistency — **no database needed**, safe in CI |
| `docs` | regenerate the rule catalogue (`docs/findings.md`) from the rule headers |
| `doctor` | self-check: client, rules dir, connectivity, capabilities, signal-registry attestation |
| `coverage` | offline version simulation: `--at 9.7`, or `--matrix` for the whole grid |

Key flags:

| Flag | |
|---|---|
| `-o, --output table\|json\|markdown\|sarif` | output format; `sarif` feeds GitHub Code Scanning |
| `--fail-on none\|info\|warn\|critical` | the severity that makes the exit code 1 (default `warn`) |
| `--only` / `--skip` | run / skip these rule ids (glob, repeatable) |
| `--dimension` / `--scope` / `--tag` / `--min-severity` | narrow the rule set |
| `--label` | the instance label shown in the report |
| `--timeout` | per-rule timeout in seconds |
| `--defaults-file` | hand a `[client]` config file to the `mysql` client (login-path, sockets, TLS) |
| `--driver auto\|cli\|pymysql` | `cli` by default; `pymysql` for typed/NULL-precise results in scripts |
| `--no-init` | skip the session prelude (see the caveat below) |
| `--ignore-min-uptime` | ignore the uptime gate — for rehearsals only; it makes cumulative counters lie |

Exit codes are a scriptable contract:

| Code | Meaning |
|---|---|
| `0` | ran clean, nothing at or above `--fail-on` |
| `1` | findings at or above `--fail-on` (including `coverage` reporting a version risk) |
| `2` | connection or execution failure |
| `3` | contract violation (e.g. `lint` found a rule that breaks its own declaration) |

## Install

```sh
git clone https://github.com/wgzhao/mysqlbot.git
cd mysqlbot
./bin/mbot doctor --host 127.0.0.1 -u root -p '…'
```

`bin/mbot` is a small launcher: it puts the repo root on `PYTHONPATH` and calls
`python -m mbot`. Set `MYSQLBOT_PYTHON` to pick a specific interpreter, or put the
launcher on your `PATH`:

```sh
export PATH="$PWD/bin:$PATH"     # then just: mbot check --host …
```

There is no package to install and nothing to uninstall — no state directory, no
daemon, no launch agent. The only optional dependency is `PyMySQL`, used lazily when
you ask for `--driver pymysql`.

## Setup — a read-only account

The read-only guarantee is **the account**, not a flag. `sql/readonly_account.sql`
creates one at either of two tiers:

- **Tier A — no access to application data at all**: `PROCESS` +
  `REPLICATION CLIENT` + `SELECT ON performance_schema.*` + `SELECT ON sys.*`.
  This is enough for 36 of the 42 rules.
- **Tier B — Tier A plus `SELECT` on your application schemas**: unlocks the six
  structure rules (tables without a primary key, redundant/unused indexes, oversized
  tables, …).

Two facts worth knowing before you write the grants yourself:

- **`PROCESS` does not buy you `performance_schema` reads.** In MySQL, `PROCESS` lets
  you see other sessions in `SHOW PROCESSLIST`, but `performance_schema.threads`,
  `data_locks`, `metadata_locks`, `events_statements_summary_by_digest` all return
  `ERROR 1142` without an explicit `SELECT ON performance_schema.*`. mysqlbot reports
  exactly which capability bit is missing instead of quietly producing partial results.
- **MySQL has no `pg_monitor`.** `information_schema` is filtered by privilege, so
  there is no "see all metadata, touch no data" role in the PostgreSQL sense. Tier A is
  the closest honest approximation: no application rows, at the cost of the six
  structure rules. The permission → rule mapping is written out in
  [`docs/compat-matrix.md`](docs/compat-matrix.md).

```sh
# review it, then run it yourself — mysqlbot never executes DDL/DCL
less sql/readonly_account.sql
```

### What it costs your database

One connection, one rule at a time, `SELECT` only. Rules run sequentially against a
single session, each under `--timeout`, and the whole run finishes in seconds on a
normal instance. Cumulative counters are read as-is (the report labels them
`cumulative`); anything that needs a growth rate over time is **not** guessed — the tool
reports the current value and says so. It is safe to run against a busy primary, and it
never leaves a transaction open.

The session prelude matters for correctness, not speed: since MySQL 8.0,
`information_schema` table statistics are cached for 24 hours
(`information_schema_stats_expiry=86400`), so every rule runs after
`SET SESSION information_schema_stats_expiry = 0`. Without it, table sizes, row counts
and index cardinalities can be a day stale and the capacity findings would be wrong.
`--no-init` disables the prelude; don't.

## Point mysqlbot at your database

Pass the connection the way your environment prefers — flags, a DSN, a socket, or the
`mysql` client's own config file:

```sh
./bin/mbot check --host db.example.com --port 3306 -u mbot_reader -p '…'
./bin/mbot check --dsn 'mysql://mbot_reader:…@db.example.com:3306/'
./bin/mbot check --socket /var/run/mysqld/mysqld.sock -u mbot_reader -p '…'
./bin/mbot check --defaults-file /etc/mysql/mysqlbot.cnf     # [client] section
```

Because the transport is the `mysql` client, everything it supports applies —
`--defaults-file` with login-paths, unix sockets, TLS, `[client]` groups. For a
database on a private network, the usual pattern is an SSH port-forward plus either
a `--host 127.0.0.1 --port <forwarded>` or a socket; mysqlbot has **no built-in SSH
tunnel** (that's on the roadmap).

## What it collects

All of it from SQL, in four dimensions:

| Dimension | Rules | Examples |
|---|---|---|
| `risk` | 16 | blocking lock chains, metadata-lock waits, idle-in-transaction, long-running transactions, tables without a primary key, non-durable commits, non-InnoDB tables |
| `latency` | 12 | buffer-pool hit ratio, temp tables spilling to disk, statements with the highest cumulative latency, full-table-scan-heavy digests, index-statistics skew, table-open-cache misses |
| `hygiene` | 7 | redundant and unused indexes, slow-query log off, `long_query_time` too high, `sql_require_primary_key` off, stale index statistics |
| `capacity` | 7 | oversized tables, connection headroom, binlog retention unbounded, `innodb_file_per_table` off, auto-increment exhaustion |

Each rule carries `severity` (`critical` 2 / `warn` 24 / `info` 16), `scope`
(`instance` / `workload` / `schema` / `cluster` / `history`) and an `exactness` label
so you know how much to trust the number:

| `exactness` | Meaning |
|---|---|
| `exact` | read directly (a variable, a version, a definition) |
| `catalog` | deterministic structure from the data dictionary |
| `cumulative` | a counter accumulated since instance start — resets on restart |
| `sampled` | relies on statistics sampling; needs enough uptime to be meaningful |
| `scraped` | a momentary value read from somewhere else |
| `unavailable` | not obtained this run |

The full catalogue — remediation, false-positive conditions and the SQL source of every
rule — is generated into [`docs/findings.md`](docs/findings.md) and a worked example
report lives in [`docs/sample-report.md`](docs/sample-report.md).

## The rule contract

A rule is one `.sql` file: a `-- @key: value` header, then the query.

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
-- @variant_of: blocking_chains     -- paired with the base rule; lint asserts the pair covers [5.7, +∞)
-- @min_uptime: 0
-- @remediation: …
-- @caveats: …
-- @safety: KILL <blocking_pid>
-- @safety_note: …
SELECT …   -- 0 rows = not hit; rows = hit; every row must carry a severity column
```

`./bin/mbot lint` enforces the contract:

- **metadata completeness** — controlled vocabularies (`dimension`, `scope`,
  `exactness`), `@safety` must come with `@safety_note`, the SQL must expose `severity`;
- **declaration vs body** — is `@since` wider than the version the referenced signals
  actually require (a cross-minor gap is an error, a same-line patch gap a warning), and
  does a hard reference to a bounded signal declare `@removed_in`;
- **variant coverage without holes** — a logical rule's variants must cover
  `[5.7, +∞)` with no gap. A hole would mean the rule *silently stops running* on some
  versions — not skipped, just absent.

Rules with executable remediation (`DROP INDEX`, `KILL`) are flagged separately in the
report, because a fix you can paste is also a fix you can paste wrongly.

## Version support

Rules declare their window; a signal registry (`mbot/signals.py`) cross-checks the
declaration against what the SQL actually references. Verified on real instances:

| Tier | Versions | Evidence |
|---|---|---|
| **Verified** | MySQL 5.7.44, Percona 8.0.43, MySQL 8.4.11, MySQL 9.7.2 | full run: **0 rule failures**; offline simulation matches observed behaviour exactly |
| Targeted re-check | MySQL 8.0.25 | fixed one early-8.0-specific skip |
| Simulated only | MySQL 9.0 | `coverage --at 9.0` (not an LTS, no instance on hand) |
| Not covered | 8.1–8.3, 9.1–9.6, MariaDB | no instance tested; `coverage` still answers the static question |

Collectors degrade rather than fail when a signal is absent:

| Signal situation | What happens |
|---|---|
| Variable removed in a newer version | read through a soft lookup (`MAX(CASE WHEN VARIABLE_NAME='…')`), which returns NULL and lets the rule degrade — this is why 8.4/9.x needed **no SQL changes** for the three removed variables |
| Same variable *required* by a rule (hard reference) | the rule fails loudly (`ERROR 1193`) rather than silently skipping — a wrong version window is a tool bug |
| Table/column absent | classified as `missing_object` and skipped with a reason, so the failure count stays meaningful |
| Version below `@since` | gated: `skip_kind=version`, reason printed |

`mbot coverage` is the cheap way to answer the question for a version you don't have:

```sh
./bin/mbot coverage --at 8.0.43     # precise: 8.0.43
./bin/mbot coverage --at 5.7        # = 5.7.999, i.e. "the 5.7 line as actually deployed"
./bin/mbot coverage --matrix
```

> `--at 5.7` resolves to **5.7.999**, not 5.7.0: in practice "running on 5.7" means
> 5.7.3x–5.7.44, and rounding down would mark rules that really do run as unavailable.
> A simulation that is more pessimistic than reality is still lying. Pin the patch
> level (`--at 5.7.0`) when you want the strict answer.

## The JSON contract

`-o json` is the interface to build on: a versioned document
(`"schema": "mysqlbot/report/v1"`) carrying the capabilities, every rule outcome, the
skip reasons and types, and the raw rows behind each finding — so a consumer never has
to parse the human table.

```sh
./bin/mbot check --host … -o json --out-file report.json
./bin/mbot check --host … -o json | jq '.outcomes[] | select(.skip_kind=="permission")'
```

Three properties make it worth scripting against:

- **`skip_kind` is structured**, not prose: `version` / `uptime` / `capability` /
  `permission` / `missing_object`. Assertions in CI can therefore tell "skipped because
  of version" from "skipped because the account lacked a grant". Matching on the Chinese
  reason string gets this wrong — an early version of the compatibility check classified
  `执行被拒（Table 'x' doesn't exist）` as a permission skip and reported a false all-clear.
- **Truncation is explicit.** Rules carry `LIMIT`s to avoid flooding a terminal; when a
  row count hits the cap the report shows `≥N` and the JSON sets `truncated: true`.
- **Every finding has a fingerprint** (`_fingerprint`), so a diff between two runs is
  possible without parsing prose.

## CI integration

`--fail-on` decouples the exit code from the default severity map, and `-o sarif` emits
[SARIF 2.1.0](https://sarifweb.azurewebsites.net/) for GitHub Code Scanning:

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

Two things to keep in mind when gating a build: `--fail-on` should usually be
`critical`, and skipped rules never affect the exit code — a pipeline that fails on
"skip rate went up" is not something the exit code can express, so parse `-o json`
if you want that. `lint` is the other CI-friendly command; it needs no database at all.

## Self-test

```sh
# 1. unit tests — no database, seconds
tests/unit.sh                    # = test_grants + test_classify + test_signals

# 2. end-to-end regression: plant violations, inspect with a read-only account, assert
tests/local_instance.sh start    # a throwaway instance under /tmp
tests/run_tests.sh
tests/local_instance.sh stop

# 3. cross-version compatibility on any real instance: assert "all 42 rules executed,
#    0 failures" and reconcile the offline simulation against reality
tests/live_compat.sh --defaults-file ~/.my.cnf --label '8.0.43'
```

Step 2 asserts three things: **no rule executed with an error**, all the planted
violations were caught, and the skipped set is printed out. Step 3 is what makes the
version table above meaningful — it fails if the registry has gone stale relative to
what the server actually reports.

The unit tests exist because of a specific class of bug: **"no error, wrong
conclusion"**. A grant-parsing mistake only makes the tool *claim* it has a capability;
a misclassified error turns a real defect into a "skip"; a stale registry makes the
simulation return a plausible but wrong answer. None of those show up end-to-end.

## Roadmap and non-goals

- **mysqlbot never writes.** It suggests index changes; it does not create them, and it
  does not kill sessions. There is no flag to enable that.
- **Host OS metrics** (CPU, disk IOPS, free memory) are not reachable over a SQL
  connection, so they are out of scope by construction.
- **No index-advice validation.** MySQL has no `hypopg` equivalent, so a suggested index
  can't be proven against the planner the way pgbot does on PostgreSQL.
- Next up: English output / i18n for the report vocabulary, thresholds via `mbot.toml`
  instead of editing SQL, baseline diffing, replication rules against a real replica,
  MariaDB verification, and replacing the `sys`-view-based index rules with our own
  analysis.

### Known limitations

Stated plainly, because a health report is only as good as its stated coverage:

- **The replication rules have never run against a real replica** — none of the instances
  used for verification was one.
- **The two blocking-chain rules are not cross-validated under real contention**
  (`blocking_chains` reads 8.0's `data_lock_waits`, `blocking_chains_57` reads 5.7's
  `INNODB_LOCK_WAITS`). What is verified: "no contention returns 0 rows", plus each rule
  hitting its own planted-contention scenario.
- **Structure rules only cover schemas the account can see.** This is why the report
  prints `visible_schemas`: "no table without a primary key" means nothing without
  "…in these databases".
- **`LIMIT` truncation is real.** A rule reporting 50 rows may be reporting the first 50
  of several hundred: the report writes `≥N` and the JSON sets `truncated: true`. Don't
  read "N rows" as the full count.

## Troubleshooting

<details>
<summary><strong>A rule was skipped — is that the same as clean?</strong></summary>

No, and the report never says so. Skips carry a `skip_kind`:
`version` (outside the rule's declared window — by design),
`uptime` (the instance hasn't been up long enough for a cumulative counter to mean
anything), `capability` / `permission` (the account can't see what this rule reads),
`missing_object` (a table or column that isn't there).
In the JSON, this is a field — so report it as coverage, not as health.

</details>

<details>
<summary><strong>Everything looks clean but the database is visibly slow</strong></summary>

Run `./bin/mbot probe` first. A report is only as wide as the account's privileges: with
Tier A grants, the six structure rules can't run, and without `SELECT ON
performance_schema.*` the statement-level latency rules are skipped entirely. The
headline line always prints the skip count for exactly this reason.

</details>

<details>
<summary><strong>"Access denied" reading <code>performance_schema</code>, even as a user with <code>PROCESS</code></strong></summary>

Expected. `PROCESS` is not a substitute for `SELECT ON performance_schema.*` —
`threads`, `data_locks`, `metadata_locks` and `events_statements_summary_by_digest` all
return 1142 without it. Grant the read, not the process privilege.

</details>

<details>
<summary><strong><code>SELECT ON sys.*</code> granted, but sys views still error (1356 / 1370)</strong></summary>

The `sys` views are `SQL SECURITY INVOKER` and call functions whose `DEFINER`
(`mysql.sys@localhost`) holds only `USAGE`, so a low-privilege account can't execute
them. mysqlbot reads `performance_schema` directly for this reason and does not depend
on the `sys` formatting views; the two index rules that still use `sys` are skipped with
a capability reason when the views aren't usable.

</details>

<details>
<summary><strong>A finding looks stale, or table sizes don't match reality</strong></summary>

Check that the session prelude is in place — every rule should run after `SET SESSION
information_schema_stats_expiry = 0`. Since MySQL 8.0, `information_schema` statistics
are cached for 24 hours by default, so table row counts, sizes and index cardinalities
can be a day old. `doctor` prints the prelude it will use, and `--no-init` is the only
way to disable it (don't).

</details>

<details>
<summary><strong>Why is the output in Chinese?</strong></summary>

The report vocabulary is Chinese today; the ids, JSON keys and enum values are English
and stable. Parsing `-o json` avoids the issue entirely, and i18n for the human-readable
labels is on the roadmap. `-o markdown` produces a report you can paste into a ticket
or a wiki.

</details>

<details>
<summary><strong>Does <code>@since: 5.7</code> mean every 5.7 patch level is tested?</strong></summary>

No. It means the signal exists from 5.7 and the rule has been executed on 5.7.44. Two
rules carry patch-level floors found by the registry (`metadata_lock_wait` needs
5.7.3 for `metadata_locks`, `replica_writable` needs 5.7.8 for `super_read_only`) —
those floors come from the documentation and unit tests, not from instances of that
exact patch level.

</details>

## Privacy

Nothing leaves your machine except the database connection you asked for. There is no
telemetry, no update check, and no network access of any kind in the codebase — no
model is called, no report is uploaded. The tool writes nothing to the target database
and nothing to the host except a report file if you pass `--out-file`. Connection
details are not persisted anywhere.

## Contributing

Issues and PRs are welcome. The invariants that are load-bearing, in order:

1. **Read-only.** No rule may write, and no remediation mySQLbot prints may be executed
   by mysqlbot itself.
2. **Deterministic findings.** A rule computes its own conclusion; nothing is inferred
   by a model.
3. **Degrade visibly.** Anything that can't be judged is skipped *with a structured
   reason* — never silently dropped, never reported as clean.

The development loop:

```sh
./tests/unit.sh                  # unit tests (no DB)
./bin/mbot lint                  # rule contracts + version consistency (no DB)
./bin/mbot docs --out-file docs/findings.md    # regenerate the catalogue
./bin/mbot coverage --matrix     # version grid must stay ✗0
tests/local_instance.sh start && tests/run_tests.sh && tests/local_instance.sh stop
```

When you add or change a rule, run `live_compat.sh` against **every version you claim
support for** — the version table is the deliverable, and a rule that works on 5.7 and
breaks on 8.4 is exactly the class of bug that end-to-end testing on one server can't
see. Adding a new version is a five-step process documented in
[`docs/versioning.md`](docs/versioning.md).

## Security

mysqlbot connects to databases with credentials you provide and reads statistics. To
report a vulnerability, please use GitHub's **private vulnerability reporting**
(Security → Report a vulnerability) rather than a public issue. Please don't paste
connection strings, real hostnames or production schema names into issues — the
project's own docs deliberately use neutral placeholders
(`app_db`, `biz_db`, `t1`, …) for the same reason.

## Layout

```
bin/mbot          launcher (puts the repo on PYTHONPATH, calls python -m mbot)
mbot/
├── rule.py       rule-header parsing, versions, controlled vocabularies
├── signals.py    version-sensitive signal registry + offline simulation + variant-coverage check
├── conn.py       connection layer (mysql client / PyMySQL) + error classification
├── probe.py      capability bits, instance facts, signal-registry attestation
├── runner.py     gates (version → uptime → capability) and structured skip_kind
├── report.py     table / json / markdown / sarif rendering
└── cli.py        check · probe · list · lint · doctor · docs · coverage
rules/            42 rules, one .sql file each
sql/              the read-only account script (two tiers)
tests/            unit tests, end-to-end regression, cross-version compatibility
docs/             design record, versioning, compatibility matrix, generated catalogue
```

## Further reading

The design record is Chinese-only for now — it is the actual engineering log, so it is
worth reading in the original if you can:

| Document | Contents |
|---|---|
| [`docs/design.md`](docs/design.md) | design decisions and the 20 traps hit on real instances (symptom → root cause → fix) |
| [`docs/versioning.md`](docs/versioning.md) | why version support is metadata, not folders; the five-step process for adding a version |
| [`docs/compat-matrix.md`](docs/compat-matrix.md) | per-version results, the version-sensitive signal table, the permission → rule map |
| [`docs/findings.md`](docs/findings.md) | the generated catalogue of all 42 rules, with remediation and caveats |
| [`docs/sample-report.md`](docs/sample-report.md) | a full example report from a sandbox instance |
| [`SKILL.md`](SKILL.md) | using mysqlbot as an agent skill |

## License

No license file has been added yet, which by default means all rights reserved. If you
want to reuse or redistribute this, open an issue and we'll settle on a license.
