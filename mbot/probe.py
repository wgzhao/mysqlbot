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
    ("p_s_mdl", "SELECT 1 FROM performance_schema.metadata_locks LIMIT 1", "元数据锁表不可读"),
    ("p_s_locks", "SELECT 1 FROM performance_schema.data_locks LIMIT 1", "data_locks 不可读（8.0+）"),
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
        joined = " | ".join(caps.grants).upper()
        all_priv = "ALL PRIVILEGES" in joined
        caps.flags["process"] = all_priv or bool(re.search(r"\bPROCESS\b", joined))
        caps.flags["replication"] = all_priv or bool(
            re.search(r"\bREPLICATION (CLIENT|SLAVE)\b", joined)
        )
        caps.flags["schema_select"] = all_priv or bool(re.search(r"SELECT[^|]*ON\s+\*\.\*", joined))
        caps.flags["global_select"] = caps.flags["schema_select"]
        caps.flags["super"] = all_priv or bool(re.search(r"\bSUPER\b", joined))
        caps.flags["audit_admin"] = bool(re.search(r"\bAUDIT_ADMIN\b", joined))
    except QueryError as exc:
        caps.notes.append(f"无法读取授权（{exc}），PROCESS/REPLICATION 能力按未知处理")
        for k in ("process", "replication", "schema_select", "global_select", "super"):
            caps.flags.setdefault(k, False)

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
