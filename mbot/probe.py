"""能力探测：先问清楚「这台实例、这个账号，到底能看到什么」，再决定跑哪些规则。

pgbot 靠 pg_monitor 一个角色就解决了可见性；MySQL 没有等价物——权限是按对象、
按 schema 过滤的，而且 5.7/8.0/8.4/9.x 的视图结构还在漂移。所以这里把能力显式
探成一组布尔位，规则用 @requires 声明依赖，缺了就记 unavailable 并说明原因，
而不是抛异常或者静默给出"干净"的假结论。
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

from .conn import QueryError

# 能力位 -> 探测用的探针 SQL。写成 SELECT 1 ... LIMIT 1 是为了在无权限时
# 立刻拿到 1142/1146，而不是等全表扫。
_PROBES: list[tuple[str, str, str]] = [
    ("p_s", "SELECT 1 FROM performance_schema.global_status LIMIT 1", "performance_schema 不可读"),
    (
        "p_s_statements",
        "SELECT 1 FROM performance_schema.events_statements_summary_by_digest LIMIT 1",
        "语句摘要表不可读（缺少 performance_schema 权限或 consumer 未开启）",
    ),
    (
        "p_s_waits",
        "SELECT 1 FROM performance_schema.table_io_waits_summary_by_index_usage LIMIT 1",
        "索引 IO 统计不可读",
    ),
    ("p_s_mdl", "SELECT 1 FROM performance_schema.metadata_locks LIMIT 1", "元数据锁表不可读（5.7.3+ 才有此表）"),
    # 5.7 根本没有 data_locks 这个表（锁信息在 information_schema.INNODB_LOCKS），
    # 所以这条在 5.7 上必然是关的——那是版本差异，不是权限问题。措辞要能同时说清两者，
    # 否则在 5.7 上会被误读成"去补 performance_schema 权限就能开"。
    (
        "p_s_locks",
        "SELECT 1 FROM performance_schema.data_locks LIMIT 1",
        "data_locks 不可读（5.7 无此表，走 information_schema.INNODB_LOCKS；"
        "8.0+ 需显式 GRANT SELECT ON performance_schema.*）",
    ),
    ("p_s_memory", "SELECT 1 FROM performance_schema.memory_summary_global_by_event_name LIMIT 1", "内存统计不可读"),
]

_SYS_PROBES = [
    # ⚠️ sys 里的视图是 **SQL SECURITY INVOKER**，不是 DEFINER。这意味着
    # "GRANT SELECT ON sys.*" 并不足以让低权限账号查询它们——视图底层引用的
    # performance_schema 表、以及它调用的 sys 函数，都要调用者自己有权。
    # 更麻烦的是 sys 的函数（format_time / format_statement / format_bytes 等）
    # DEFINER 是 mysql.sys@localhost，而该账号只有 USAGE，所以调用者必须额外拿到
    # EXECUTE —— 这是绝大多数 DBA 不愿意给的权限。
    #
    # 结论：**把 sys 当作"可选的锦上添花"，核心发现一律直读 performance_schema。**
    # 下面这两个视图经实测在"PROCESS + SELECT ON sys.*"下可读，且实现的是不好
    # 自己写的算法（冗余键判定），所以保留依赖；任何依赖 sys 格式化视图
    # （statement_analysis 之类）的规则一律不写。
    ("sys", "sys.schema_redundant_indexes"),
    ("sys_indexes", "sys.schema_unused_indexes"),
]

# 判定 sys 函数能否调用（能则说明账号额外拿到了 EXECUTE，属于加分项而非必需）
_SYS_ROUTINE_PROBE = ("sys_functions", "SELECT sys.format_time(1)")

# 规则可能依赖的实例事实（会随能力位一起返回，供规则门禁与报告使用）
_FACT_VARIABLES = [
    "performance_schema",
    "innodb_buffer_pool_size",
    "information_schema_stats_expiry",
    "long_query_time",
    "slow_query_log",
    "log_bin",
    "binlog_expire_logs_seconds",
    "expire_logs_days",
    "max_connections",
    "thread_cache_size",
    "table_open_cache",
    "tmp_table_size",
    "max_heap_table_size",
    "innodb_log_file_size",
    "innodb_redo_log_capacity",
    "innodb_flush_log_at_trx_commit",
    "sync_binlog",
    "innodb_file_per_table",
    "transaction_isolation",
    "lower_case_table_names",
    "sql_require_primary_key",
    "read_only",
    "server_id",
    "default_storage_engine",
]

_FACT_STATUS = ["Uptime", "Threads_connected", "Threads_running", "Max_used_connections", "Open_tables"]


@dataclass
class Capabilities:
    version_str: str = ""
    version: tuple[int, ...] = ()
    version_comment: str = ""
    innodb_version: str = ""
    current_user: str = ""
    flags: dict[str, bool] = field(default_factory=dict)
    reasons: dict[str, str] = field(default_factory=dict)
    facts: dict[str, Any] = field(default_factory=dict)
    grants: list[str] = field(default_factory=list)
    # 账号在 information_schema 里实际能看到的 schema（结构类规则的覆盖范围）
    schemas: list[str] = field(default_factory=list)
    # signals.py 的**变量**信号登记表 vs 实例实测存在性（见 attest_variable_signals）
    signal_registered: int = 0
    signal_present: int = 0
    signal_mismatch: list[str] = field(default_factory=list)
    signal_skip: str = ""
    notes: list[str] = field(default_factory=list)

    @property
    def is_mariadb(self) -> bool:
        return "mariadb" in (self.version_comment or "").lower()

    @property
    def is_percona(self) -> bool:
        return "percona" in (self.version_comment or "").lower()

    def has(self, name: str) -> bool:
        return bool(self.flags.get(name))

    def missing(self, requires: list[str]) -> list[str]:
        return [r for r in requires if not self.has(r)]

    def fact(self, name: str, default: Any = None) -> Any:
        return self.facts.get(name, default)


def _numeric(text: str) -> float | None:
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def _looks_like_bytes(value: str) -> int | None:
    """把 '134217728' 或 '128M' 归一成字节数。"""
    if value is None:
        return None
    s = str(value).strip()
    m = re.match(r"^(\d+)\s*([KMGTP])?$", s, re.IGNORECASE)
    if not m:
        return None
    n = int(m.group(1))
    unit = (m.group(2) or "").upper()
    return n * {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4, "P": 1024**5}[unit]


# GRANT <privs> ON <scope> TO <user>，scope 形如 `*.*` / `` `db`.* `` / `` `db`.`tbl` ``
_RE_GRANT = re.compile(r"^\s*GRANT\s+(?P<privs>.+?)\s+ON\s+(?P<scope>\S+)\s+TO\s", re.I)


def _split_privs(text: str) -> set[str]:
    """'SELECT, INSERT, PROCESS' -> {'SELECT','INSERT','PROCESS'}。

    必须先剥掉列级授权的括号再按逗号切：`SELECT (id, name)` 里的逗号会把
    'SELECT (id' / 'name)' 切成两个假权限名。列级列表不会嵌套，所以一次
    非贪婪匹配就够。
    """
    text = re.sub(r"\([^()]*\)", "", text)
    out: set[str] = set()
    for item in text.split(","):
        item = item.strip().upper()
        if item:
            out.add(item)
    return out


def _parse_grants(lines: list[str]) -> tuple[set[str], dict[str, set[str]]]:
    """把 SHOW GRANTS 的每行拆成 (全局权限集, {schema: 该库权限集})。

    【坑·已在真实实例上踩到】绝不能对整段授权文本做 `"ALL PRIVILEGES" in text`
    这类子串判断。一个只被授了 ``GRANT ALL PRIVILEGES ON `biz_db`.*`` 的业务
    账号，会让 `all_priv` 变真，于是 process / replication / schema_select / super
    全部被误判为"有"；后果是能力门禁形同虚设，规则一路跑到底才在执行期撞 1142，
    报告里表现为一堆"执行被拒"的跳过，而不是清晰的"缺少能力位"。必须逐行解析 scope。
    """
    global_privs: set[str] = set()
    schema_privs: dict[str, set[str]] = {}
    for line in lines:
        m = _RE_GRANT.match(line)
        if not m:
            continue
        privs = _split_privs(m.group("privs"))
        scope = m.group("scope").strip().strip("`")
        if scope == "*.*":
            global_privs |= privs
        elif scope.endswith(".*"):
            schema_privs.setdefault(scope[:-2].strip("`"), set()).update(privs)
        # `` `db`.`tbl` `` 这种表级授权不构成 schema 级可见性，忽略
    return global_privs, schema_privs


# 各版本表达"能读复制状态"的权限名：5.7/8.0 是 REPLICATION CLIENT，
# MariaDB 10.5.9+ 拆成了 BINLOG MONITOR + SLAVE MONITOR。
_REPLICATION_PRIVS = {"REPLICATION CLIENT", "REPLICATION SLAVE", "BINLOG MONITOR", "SLAVE MONITOR"}


def _apply_grants(caps: Capabilities) -> None:
    global_privs, schema_privs = _parse_grants(caps.grants)
    # `ALL PRIVILEGES ON *.*` 是**一个**权限名，不会展开成 PROCESS/SELECT 之类的
    # 具体名字，所以要单独识别；漏了它，root 账号会被判成"什么权限都没有"。
    all_global = "ALL PRIVILEGES" in global_privs

    def has(priv: str) -> bool:
        return all_global or priv in global_privs

    caps.flags["process"] = has("PROCESS")
    caps.flags["replication"] = all_global or bool(_REPLICATION_PRIVS & global_privs)
    caps.flags["super"] = has("SUPER")
    caps.flags["audit_admin"] = has("AUDIT_ADMIN")
    caps.flags["global_select"] = has("SELECT")

    readable = sorted(
        db
        for db, privs in schema_privs.items()
        if "SELECT" in privs or "ALL PRIVILEGES" in privs
    )
    # 这是**从授权文本推出来**的清单，只作为兜底（probe() 会用
    # information_schema 问服务器要权威答案）。
    caps.schemas = readable
    # 结构类规则读 information_schema，而 I_S 是**按权限过滤**的——只要有任意一个
    # schema 可读，规则就能对这些库生效（不可见的库 I_S 自己会滤掉，不需要我们排除）。
    caps.flags["schema_select"] = has("SELECT") or bool(readable)


def _note_schema_coverage(caps: Capabilities) -> None:
    """把"结构类规则实际覆盖哪些库"写成一条 note。

    没有全局 SELECT 时必须显式说明覆盖范围——否则用户会以为"没报无主键表"
    就是"整个实例都没有无主键表"，而实际上只扫了被授权的几个库。
    """
    if caps.flags.get("global_select") or not caps.schemas:
        return
    shown = "、".join(caps.schemas[:8]) + ("…" if len(caps.schemas) > 8 else "")
    caps.notes.append(
        f"账号只对 {len(caps.schemas)} 个 schema 有 SELECT（{shown}）："
        "结构类规则的覆盖范围就是这些库，其余库在 information_schema 里不可见、不会被检查"
    )


def attest_variable_signals(conn, version: tuple[int, ...]) -> tuple[int, int, list[str], str]:
    """把 ``signals.py`` 登记的**变量**信号，与实例上真实存在的变量对一遍。

    返回 ``(登记数, 实例存在数, 不一致说明, 跳过原因)``。

    ## 为什么只对变量做这件事

    变量是唯一存在「**软查表**」用法的信号源：

    .. code-block:: sql

        -- 硬引用：变量不存在 → ERROR 1193，整条规则崩，error 计数会抓到
        SELECT @@innodb_redo_log_capacity

        -- 软查表：变量不存在 → 那行不存在 → MAX() 返回 NULL，规则自己兜住
        SELECT MAX(CASE WHEN VARIABLE_NAME = 'innodb_redo_log_capacity'
                        THEN VARIABLE_VALUE END)

    硬引用失败是**响的**，live_compat 的推演对账能看见；软查表失败是**哑的** ——
    规则不报错、不跳过，可能静静地给出错误结论（正是铁律 3 要防的那一类）。
    表名与列名则一律是硬引用（缺了报 1146 / 1054），由 error 计数兜住，
    所以不需要在这一步里重复核对。

    这个方法的价值在于：登记表是人写的、会过期，而它唯一的权威来源就是
    「真实实例上到底有没有这个变量」。跑一次就相当于让实例替我们复查登记表。
    """
    from . import signals as sg

    sigs = [s for s in sg._ORDER if s.kind == "variable"]
    if not sigs:
        return 0, 0, [], ""
    names = sorted({s.name for s in sigs})
    try:
        r = conn.query(
            "SELECT VARIABLE_NAME FROM performance_schema.global_variables"
            f" WHERE VARIABLE_NAME IN ({','.join(repr(n) for n in names)})"
        )
    except QueryError as exc:
        return len(names), 0, [], f"读不到 performance_schema.global_variables（{exc}）"
    present = {row[0] for row in r.rows if row and row[0]}

    bad: list[str] = []
    for s in sorted(sigs, key=lambda x: x.name):
        want, got = s.available_in(version), s.name in present
        if want == got:
            continue
        if got:
            bad.append(f"{s.name}：登记为 {s.range_text()}（区间外），实例上却仍存在")
        else:
            bad.append(f"{s.name}：登记为 {s.range_text()}（区间内），实例上却不存在")
    return len(names), len(present), bad, ""


def probe(conn) -> Capabilities:
    """对已连接的实例做一次能力探测。任何单项失败都只记原因，不中断。"""
    srv = getattr(conn, "server", {}) or {}
    caps = Capabilities(
        version_str=srv.get("version", ""),
        version_comment=srv.get("version_comment", ""),
        innodb_version=srv.get("innodb_version", ""),
        current_user=srv.get("current_user", ""),
    )
    from .rule import parse_version

    caps.version = parse_version(caps.version_str)

    # 1) 固定过程的能力位
    for name, sql, reason in _PROBES:
        try:
            conn.query(sql)
            caps.flags[name] = True
        except QueryError as exc:
            if exc.degradable:
                caps.flags[name] = False
                caps.reasons[name] = reason
            else:
                caps.flags[name] = False
                caps.reasons[name] = f"{reason}（{exc}）"

    # P_S 关掉时所有 P_S 派生能力一起置否，理由统一
    if not caps.has("p_s"):
        for name, _, _ in _PROBES:
            caps.flags[name] = False
            caps.reasons.setdefault(name, "performance_schema 未启用或不可读")

    for name, tbl in _SYS_PROBES:
        try:
            conn.query(f"SELECT 1 FROM {tbl} LIMIT 1")
            caps.flags[name] = True
        except QueryError as exc:
            caps.flags[name] = False
            caps.reasons[name] = f"{tbl} 不可用：{exc}"

    name, sql = _SYS_ROUTINE_PROBE
    try:
        conn.query(sql)
        caps.flags[name] = True
    except QueryError as exc:
        caps.flags[name] = False
        caps.reasons[name] = (
            f"sys 函数不可调用（{exc}）——sys 视图是 SQL SECURITY INVOKER，"
            "且其函数 DEFINER mysql.sys 只有 USAGE，需额外 EXECUTE 授权；本工具不依赖它"
        )

    # 2) 授权解析：PROCESS / REPLICATION CLIENT / 全局 SELECT 无法靠试查询判定，
    #    information_schema 是按权限静默过滤的——没权限时看到的是空集合而不是报错。
    try:
        grants = conn.query("SHOW GRANTS FOR CURRENT_USER()")
        caps.grants = [" ".join(str(c) for c in row if c) for row in grants.rows]
        _apply_grants(caps)
    except QueryError as exc:
        caps.notes.append(f"无法读取授权（{exc}），PROCESS/REPLICATION 能力按未知处理")
        for k in ("process", "replication", "schema_select", "global_select", "super"):
            caps.flags.setdefault(k, False)

    # 2b) 用服务器自己的回答覆盖"从授权文本推出来的"可见库清单。
    #     information_schema 是按权限过滤的，所以 TABLES 里出现的 schema 就是
    #     结构类规则**实际覆盖**的范围。这比解析授权文本权威：角色、代理用户、
    #     以及某些版本里 PROCESS 带来的额外元信息可见性，都能被如实反映。
    try:
        r = conn.query(
            "SELECT DISTINCT TABLE_SCHEMA AS db FROM information_schema.TABLES"
            " WHERE TABLE_TYPE = 'BASE TABLE'"
            "   AND TABLE_SCHEMA NOT IN ('mysql', 'information_schema',"
            "                            'performance_schema', 'sys')"
            " ORDER BY db"
        )
        visible = [row[0] for row in r.rows if row and row[0]]
        if visible:
            caps.schemas = visible
            caps.flags["schema_select"] = True
        elif not caps.flags.get("global_select"):
            caps.schemas = []
            caps.flags["schema_select"] = False
    except QueryError as exc:
        # 枚举失败不致命：退回授权文本推出的清单，并把不确定性说出来
        caps.notes.append(f"无法枚举可见 schema（{exc}），结构类规则的覆盖范围可能不完整")

    _note_schema_coverage(caps)

    # 3) 事实变量
    facts: dict[str, Any] = {}
    try:
        r = conn.query(
            "SELECT s.VARIABLE_NAME AS name, s.VARIABLE_VALUE AS value"
            " FROM performance_schema.global_status s"
            f" WHERE s.VARIABLE_NAME IN ({','.join(repr(v) for v in _FACT_STATUS)})"
        )
        for row in r.dicts():
            facts[row["name"]] = row["value"]
    except QueryError:
        pass

    try:
        names = ",".join(repr(v) for v in _FACT_VARIABLES)
        r = conn.query(f"SHOW VARIABLES WHERE Variable_name IN ({names})")
        for row in r.dicts():
            key = next(iter(row.values()))
            val = row.get("Value")
            facts[key] = val
    except QueryError:
        pass

    # SHOW VARIABLES 在部分版本里列名不是 Value，兜底再走一遍 variables 表
    if not facts:
        try:
            r = conn.query(
                "SELECT VARIABLE_NAME, VARIABLE_VALUE FROM performance_schema.global_variables"
            )
            for row in r.rows:
                if row[0] in _FACT_VARIABLES:
                    facts[row[0]] = row[1]
        except QueryError:
            pass

    for k, v in list(facts.items()):
        b = _looks_like_bytes(v)
        if b is not None and k.endswith(("_size", "_capacity", "_cache", "expire_logs_seconds")):
            facts[k + "_bytes"] = b
    if "Uptime" in facts:
        facts["uptime_s"] = int(_numeric(facts["Uptime"]) or 0)

    caps.facts = facts

    # 3b) 变量信号登记表 vs 实例实测 —— 见 attest_variable_signals 的 docstring。
    #     MariaDB 的变量集与 MySQL 不同，登记表未覆盖它，硬核对只会全是假阳性。
    from . import signals as sg

    if caps.is_mariadb:
        caps.signal_skip = "MariaDB 的变量集与 MySQL 不同，登记表不适用于它"
    elif caps.version and caps.version < parse_version(sg.SUPPORTED_FROM):
        caps.signal_skip = f"版本 {caps.version_str} 早于支持下界 {sg.SUPPORTED_FROM}"
    else:
        n_reg, n_pres, bad_sig, sig_skip = attest_variable_signals(conn, caps.version)
        caps.signal_registered, caps.signal_present = n_reg, n_pres
        caps.signal_mismatch, caps.signal_skip = bad_sig, sig_skip
        if bad_sig:
            caps.notes.append(
                f"信号登记表与实例不一致（{len(bad_sig)} 条）：{'；'.join(bad_sig)}"
                " —— mbot/signals.py 已过期，版本推演结果不可信（见 docs/versioning.md）"
            )

    # 4) 版本相关的能力修正
    if caps.is_mariadb:
        caps.notes.append("检测到 MariaDB：部分 performance_schema 视图与权限名不同，规则可能降级")
        caps.flags["mariadb"] = True
    if caps.version and caps.version < (5, 7):
        caps.notes.append(f"MySQL {caps.version_str} 早于 5.7，本规则库未覆盖")
    if caps.version >= (8, 4):
        caps.flags["mysql84"] = True
    if caps.innodb_version:
        caps.flags["innodb"] = True
    else:
        try:
            conn.query("SELECT 1 FROM information_schema.ENGINES WHERE ENGINE='InnoDB' AND SUPPORT<>'NO'")
            caps.flags["innodb"] = True
        except QueryError:
            caps.flags["innodb"] = False

    # 5) 采样类规则的可用性：实例刚起来时累计计数器不可信
    if caps.fact("uptime_s") is not None and caps.fact("uptime_s") < 3600:
        caps.notes.append(f"实例启动仅 {caps.fact('uptime_s')} 秒，累计型指标（命中率等）暂不可信")

    return caps
