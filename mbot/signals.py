"""版本敏感信号登记表 —— 把「通用 + 特定」落在元数据层，而不是目录层。

## 为什么需要这一层

规则文件本来只有两样东西能表达版本兼容性：

  - ``@since`` / ``@removed_in``：整条规则的可用区间（粗粒度，靠人写）
  - SQL 正文：真正碰到的信号源（细粒度，但**没有人检查**）

两者之间没有任何校验。于是同一个事故会反复发生：

  一条规则写着 ``@since: 5.7``，正文里却引用了 8.0.22 才有的列 ——
  在 5.7 上执行时抛 1054。修好之前，这个错误还会被错误分类降级成
  「跳过」，报告里显示的是一句听上去很合理的"环境限制"。

本模块补上第三样：**信号 → 可用版本区间** 的登记表，
让「这条规则声明了什么」和「它实际碰了什么」可以被机器比对。

## 硬引用 vs 软查表 —— 这个区分是整个设计的关键

同一个信号，两种用法，后果完全不同：

.. code-block:: sql

    -- 硬引用：变量不存在 → ERROR 1193，整条规则崩
    SELECT @@binlog_expire_logs_auto_purge

    -- 软查表：变量不存在 → 那行不存在 → MAX() 返回 NULL，规则自己兜住
    SELECT MAX(CASE WHEN VARIABLE_NAME = 'binlog_expire_logs_auto_purge'
                    THEN VARIABLE_VALUE END)
    FROM performance_schema.global_variables

所以"某条规则的 ``@since`` 该写几"不能只看它碰了哪些信号，
还要看它是**怎么碰**的。:func:`scan` 返回的 :class:`Usage` 带 ``hard`` 标记，
只有 ``hard=True`` 的引用才构成版本不兼容。

## 版本区间的依据

``since`` / ``removed_in`` 的取值来自 `docs/compat-matrix.md` 第二节的实测表
（在 Percona 5.7.44 / 8.0.43 与 MySQL 8.4.11 上逐个 ``SELECT @@var`` /
``SHOW COLUMNS`` 核对过），8.4/9.x 的移除项来自 Oracle 官方移除清单。
新增信号时请一并更新那张表——**登记表与实测表必须同源**。
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Iterable

from .rule import Rule, parse_version, version_ge

# 我们声明支持的版本下界。区间上界当前是开放的（无上限）。
SUPPORTED_FROM = "5.7"

# 用于 `coverage --matrix` 的默认版本网格。
# 8.0 已 EOL、9.7 是当前 LTS —— 这两个事实决定了下面这一行该长什么样。
DEFAULT_GRID = ("5.7", "8.0", "8.4", "9.0", "9.7")


@dataclass(frozen=True)
class Signal:
    """一个版本敏感的**信号源**（表 / 列 / 系统变量）。

    ``hard_re`` 是"直接引用"的正则，命中即构成版本依赖；
    ``soft_re`` 是"软查表"的正则，命中只意味着规则能优雅退化，**不构成**依赖。
    """

    name: str
    kind: str  # table | column | variable | view
    obj: str  # 完整对象路径，仅用于报告
    hard_re: str
    soft_re: str = ""
    since: str = ""
    removed_in: str = ""
    note: str = ""

    # 编译结果不放字段里（frozen dataclass 存 _re.Pattern 会让 repr/比较变味）
    _hard = None
    _soft = None

    @property
    def since_tuple(self) -> tuple[int, ...]:
        return parse_version(self.since)

    @property
    def removed_tuple(self) -> tuple[int, ...]:
        return parse_version(self.removed_in)

    @property
    def hard(self) -> re.Pattern:
        if self._hard is None:
            object.__setattr__(self, "_hard", re.compile(self.hard_re, re.IGNORECASE))
        return self._hard

    @property
    def soft(self) -> re.Pattern | None:
        if self.soft_re and self._soft is None:
            object.__setattr__(self, "_soft", re.compile(self.soft_re, re.IGNORECASE))
        return self._soft or None

    def available_in(self, ver: tuple[int, ...]) -> bool:
        if not ver:
            return True
        if self.since_tuple and not version_ge(ver, self.since_tuple):
            return False
        if self.removed_tuple and version_ge(ver, self.removed_tuple):
            return False
        return True

    def range_text(self) -> str:
        lo = self.since or SUPPORTED_FROM
        return f"{lo} ~ {self.removed_in}" if self.removed_in else f"{lo} ~ 至今"

    def why_unavailable(self, ver: tuple[int, ...]) -> str:
        if self.since_tuple and not version_ge(ver, self.since_tuple):
            return f"{self.obj} 需要 {self.since}+"
        if self.removed_tuple and version_ge(ver, self.removed_tuple):
            return f"{self.obj} 在 {self.removed_in} 已移除"
        return f"{self.obj} 在 {'.'.join(map(str, ver))} 不可用"


def _var(name: str, since: str = "5.7", removed_in: str = "", note: str = "", soft: bool = True) -> Signal:
    """系统变量：硬引用=``@@name``，软查表=``'name'`` 字面量。"""
    return Signal(
        name=name,
        kind="variable",
        obj=f"variable:{name}",
        hard_re=rf"@@\s*(?:GLOBAL\.|SESSION\.)?{re.escape(name)}\b",
        soft_re=rf"'{re.escape(name)}'" if soft else "",
        since=since,
        removed_in=removed_in,
        note=note,
    )


def _tbl(schema: str, table: str, since: str = "5.7", removed_in: str = "", note: str = "", kind: str = "table") -> Signal:
    return Signal(
        name=f"{schema}.{table}" if schema != "sys" else f"sys.{table}",
        kind=kind,
        obj=f"{schema}.{table}",
        hard_re=rf"\b(?:{re.escape(schema)}\s*\.\s*)?{re.escape(table)}\b",
        since=since,
        removed_in=removed_in,
        note=note,
    )


def _col(table: str, column: str, since: str, removed_in: str = "", note: str = "") -> Signal:
    return Signal(
        name=f"{table}.{column}",
        kind="column",
        obj=f"{table}.{column}",
        hard_re=rf"\b{re.escape(column)}\b",
        since=since,
        removed_in=removed_in,
        note=note,
    )


# =============================================================================
# 登记表本体
#
# 只登记两类信号：
#   1. 版本区间**有限**的（since 不是 5.7，或 removed_in 非空）—— 会决定门禁
#   2. 版本无界、但被多版本共用的 —— 登记它们是为了算出规则的"最低版本"
#      （否则「声明过窄」这条 lint 检查会误报）
# =============================================================================
_ORDER: list[Signal] = [
    # ---- 系统变量：binlog 保留策略（三版用了三套表达，最容易踩坑的一组）----
    _var("expire_logs_days", since="5.7", removed_in="8.4",
         note="8.0.43 上仍在（值为 0），8.4 起移除；只有 _57 变体硬引用它"),
    _var("binlog_expire_logs_seconds", since="8.0",
         note="8.0 引入，优先于 expire_logs_days"),
    _var("binlog_expire_logs_auto_purge", since="8.0.29",
         note="8.0.0~8.0.28 不存在；直引 @@ 会报 1193"),
    # ---- 系统变量：redo 容量（8.0.30 前后换了表达）----
    _var("innodb_log_file_size", since="5.7", removed_in="8.4",
         note="8.0.30 起废弃，8.4 移除；推荐改读 innodb_redo_log_capacity"),
    _var("innodb_log_files_in_group", since="5.7", removed_in="8.4",
         note="同上"),
    _var("innodb_redo_log_capacity", since="8.0.30",
         note="8.0.30 引入；5.7~8.0.29 只能走 log_file_size × log_files_in_group"),
    # ---- 系统变量：8.0 才有的信息架构相关 ----
    _var("information_schema_stats_expiry", since="8.0",
         note="8.0 引入；工具会用 SET SESSION 把它置 0 来绕过统计缓存"),
    _var("sql_require_primary_key", since="8.0.13", note=""),
    # ---- 系统变量：跨版本无界（登记是为了算最低版本）----
    _var("log_bin"), _var("log_bin_basename"), _var("server_id"), _var("read_only"),
    _var("slow_query_log"), _var("long_query_time"), _var("log_output"),
    _var("sync_binlog"), _var("innodb_flush_log_at_trx_commit"),
    _var("innodb_file_per_table"), _var("performance_schema"),
    _var("innodb_buffer_pool_size"), _var("super_read_only", since="5.7.8", note="5.7.8 引入"),
    # ---- 表：锁（5.7 与 8.0 是两套完全不同的表）----
    _tbl("information_schema", "INNODB_LOCK_WAITS", since="5.7", removed_in="8.0",
         note="8.0 移除，改用 performance_schema.data_lock_waits"),
    _tbl("information_schema", "INNODB_LOCKS", since="5.7", removed_in="8.0", note="同上"),
    _tbl("performance_schema", "data_locks", since="8.0"),
    _tbl("performance_schema", "data_lock_waits", since="8.0"),
    _tbl("performance_schema", "metadata_locks", since="5.7.3",
         note="实测 5.7.44 就有这张表——此前规则的 @caveats 声称 5.7 没有，是错的"),
    # ---- 表：跨版本无界 ----
    _tbl("performance_schema", "global_status"), _tbl("performance_schema", "global_variables"),
    _tbl("performance_schema", "threads"),
    _tbl("performance_schema", "events_statements_summary_by_digest", kind="table"),
    _tbl("performance_schema", "replication_applier_status_by_worker"),
    _tbl("performance_schema", "replication_applier_status"),
    _tbl("performance_schema", "replication_connection_status"),
    _tbl("information_schema", "INNODB_TRX"), _tbl("information_schema", "INNODB_METRICS",
         note="需要 innodb_monitor_enable，属能力位而非版本问题"),
    _tbl("information_schema", "PROCESSLIST"), _tbl("information_schema", "TABLES"),
    _tbl("information_schema", "COLUMNS"), _tbl("information_schema", "STATISTICS"),
    _tbl("information_schema", "TABLE_CONSTRAINTS"),
    _tbl("sys", "schema_redundant_indexes", kind="view", note="需要 sys 上的 SELECT 权限"),
    _tbl("sys", "schema_unused_indexes", kind="view", note="同上"),
    # ---- 列：语句摘要表的样本列（8.0.22 前后不同）----
    _col("events_statements_summary_by_digest", "QUERY_SAMPLE_TEXT", since="8.0.22",
         note="5.7 上引用会 1054 —— 这就是那两个静默缺陷的根因"),
    _col("events_statements_summary_by_digest", "DIGEST_TEXT", since="5.7",
         note="5.7 起一直存在，跨版本的稳妥选择"),
    # ---- 列：复制 applier 表（5.7 与 8.0 列集交集只有 7 列）----
    _col("replication_applier_status_by_worker", "LAST_SEEN_TRANSACTION", since="5.7", removed_in="8.0",
         note="8.0 起换成 LAST_APPLIED_TRANSACTION"),
    _col("replication_applier_status_by_worker", "LAST_APPLIED_TRANSACTION", since="8.0"),
    _col("replication_applier_status_by_worker", "APPLYING_TRANSACTION", since="8.0"),
    _col("replication_applier_status_by_worker", "APPLYING_TRANSACTION_RETRIES_COUNT", since="8.0"),
    # ---- 列：跨版本无界 ----
    _col("INNODB_TRX", "TRX_WAIT_STARTED", since="5.7"),
]

SIGNALS: dict[str, Signal] = {s.name: s for s in _ORDER}


@dataclass
class Usage:
    """规则正文对某个信号的一次引用。"""

    signal: Signal
    hard: bool
    soft: bool

    def __str__(self) -> str:
        return f"{self.signal.name}{'' if self.hard else '(soft)'}"


def scan(rule: Rule | str) -> list[Usage]:
    """扫描规则正文，返回它引用的全部**已登记**信号。

    只扫 SQL 正文——规则解析器已经把头部注释剥进 ``raw_header``，
    所以 ``QUERY_SAMPLE_TEXT`` 出现在 ``@caveats`` 里（解释"为什么不用它"）
    不会被误判成引用。
    """
    sql = rule.sql if isinstance(rule, Rule) else str(rule)
    out: list[Usage] = []
    for sig in SIGNALS.values():
        hard = bool(sig.hard.search(sql))
        soft = bool(sig.soft.search(sql)) if sig.soft else False
        if hard or soft:
            out.append(Usage(sig, hard=hard, soft=soft))
    return sorted(out, key=lambda u: u.signal.name)


def min_version(usages: Iterable[Usage]) -> str:
    """规则正文**硬引用**所要求的最低版本。软引用不参与。

    返回 "" 表示正文没有硬引用任何有下界的信号（即与支持下界同寿）。
    """
    lo = ()
    for u in usages:
        if not u.hard or not u.signal.since_tuple:
            continue
        if not lo or version_ge(u.signal.since_tuple, lo):
            lo = u.signal.since_tuple
    return ".".join(map(str, lo)) if lo else ""


def hard_upper_bounds(usages: Iterable[Usage]) -> list[Signal]:
    """规则硬引用的、有 ``removed_in`` 上界的信号。

    这些规则**必须**声明自己的 ``@removed_in``，否则在移除版本上会失败。
    """
    return sorted(
        {u.signal for u in usages if u.hard and u.signal.removed_tuple},
        key=lambda s: s.name,
    )


# =============================================================================
# 判定：规则在目标版本上的命运
# =============================================================================
RUNNABLE = "runnable"  # 版本与信号都满足（运行时仍可能因权限而跳过）
GATED = "gated"  # 被 @since / @removed_in 门禁挡住 —— 设计如此
AT_RISK = "at_risk"  # 硬引用的信号在目标版本不存在 —— 执行会失败
UNREGISTERED = "unregistered"  # 正文引用了未登记的信号，无法判定


def resolve_target(version: str) -> tuple[int, ...]:
    """把用户给的版本串解析成**用于对比目标实例**的元组。

    只写大版本（``"5.7"``）时，补成该线的**最新补丁**而不是 ``.0``。
    因为"这库跑在 5.7 上"在现实里指的是 5.7.3x~5.7.44，不是 2015 年的 5.7.0：
    若补 0，一条 ``@since: 5.7.3`` 的规则会被判成"在 5.7 上不可用"，
    而它在真实的 5.7.44 上跑得好好的 —— 推演结果会比现实更悲观，也就是在说谎。

    要严格按某个补丁判定，把版本写全：``--at 5.7.0``。

    注意本函数**只用于目标实例版本**；规则与信号之间的版本比较仍用
    :func:`mbot.rule.parse_version`，那里补 0 才是对的。
    """
    parts = parse_version(version)
    if len(parts) == 1:
        return parts + (999, 999)
    if len(parts) == 2:
        return parts + (999,)
    return parts


@dataclass
class Verdict:
    rule: Rule
    status: str
    reason: str = ""
    offending: list[str] = field(default_factory=list)

    @property
    def runs(self) -> bool:
        return self.status == RUNNABLE


def verdict_for(rule: Rule, version: str | tuple[int, ...]) -> Verdict:
    """离线判定一条规则在目标版本上的状态。**不连库。**"""
    ver = resolve_target(version) if isinstance(version, str) else version
    if not rule.supports_version(ver):
        if rule.since_tuple and not version_ge(ver, rule.since_tuple):
            return Verdict(rule, GATED, f"需要 MySQL >= {rule.since}")
        return Verdict(rule, GATED, f"MySQL >= {rule.removed_in} 已移除该信号源")

    usages = scan(rule)
    bad = [u for u in usages if u.hard and not u.signal.available_in(ver)]
    if bad:
        return Verdict(
            rule,
            AT_RISK,
            "；".join(u.signal.why_unavailable(ver) for u in bad),
            [u.signal.obj for u in bad],
        )
    return Verdict(rule, RUNNABLE)


def coverage(rules: list[Rule], version: str) -> tuple[list[Verdict], dict[str, int]]:
    """整个规则库在某个版本上的推演结果 + 汇总计数。"""
    verdicts = [verdict_for(r, version) for r in rules]
    tally: dict[str, int] = {RUNNABLE: 0, GATED: 0, AT_RISK: 0}
    for v in verdicts:
        tally[v.status] = tally.get(v.status, 0) + 1
    return verdicts, tally


# =============================================================================
# 变体：同一条逻辑规则的多个版本实现
# =============================================================================
def variant_base(rule: Rule) -> str:
    """逻辑规则名。显式 ``@variant_of`` 优先，否则从 ``_57`` 这类后缀推断。

    推断只是为了让存量规则不必立刻改头；显式声明才是长期形态——
    它让 lint 能断言"变体集合无缝覆盖声明区间"，而不是靠命名巧合。
    """
    explicit = (rule.variant_of or rule.raw_header.get("variant_of", "")).strip()
    if explicit and explicit not in ("-", "none", "无"):
        return explicit
    m = re.match(r"^(.*)_(\d{2,3})$", rule.id)
    return m.group(1) if m else rule.id


def _norm(v: tuple[int, ...]) -> tuple[int, int, int]:
    """把版本元组补成 3 段，避免 (8,4) 与 (8,4,0) 比较时长度不一致带来的意外。"""
    v = tuple(v) + (0, 0, 0)
    return (v[0], v[1], v[2])


def _fmt(v: tuple[int, ...]) -> str:
    parts = list(_norm(v))
    while len(parts) > 2 and parts[-1] == 0:
        parts.pop()
    return ".".join(map(str, parts))


def variant_gaps(rules: list[Rule], support_from: str = SUPPORTED_FROM) -> list[str]:
    """检查每条逻辑规则的变体集合是否无缝覆盖 [support_from, +∞)。

    这是"按版本切目录"想解决、但其实解决不了的那个问题：
    覆盖区间一旦出现空洞，规则会在那个版本上**静静地不跑** ——
    而目录结构上看不出任何异常（两个目录都"有东西"）。
    在平铺命名 + 显式区间下，这个洞是可以算出来的。
    """
    groups: dict[str, list[Rule]] = {}
    for r in rules:
        groups.setdefault(variant_base(r), []).append(r)

    lo = parse_version(support_from)
    problems: list[str] = []
    for base, members in sorted(groups.items()):
        if len(members) == 1:
            continue  # 单实现：区间由它自己的 @since/@removed_in 负责，交给方向一/二
        # 每个成员的覆盖区间 [start, end)，end 为 None 表示到无穷
        spans: list[tuple[tuple[int, int, int], tuple[int, int, int] | None, str]] = []
        for m in members:
            spans.append((_norm(m.since_tuple or lo), _norm(m.removed_tuple) if m.removed_tuple else None, m.id))
        spans.sort(key=lambda s: (s[0], s[1] or (10**6, 0, 0)))

        cursor = _norm(lo)
        open_end = False
        for start, end, rid in spans:
            if start > cursor:
                problems.append(f"{base}: {_fmt(cursor)} ~ {_fmt(start)} 区间无变体覆盖")
            if end is None:
                open_end = True
                break
            if end > cursor:
                cursor = end
        if not open_end:
            problems.append(f"{base}: {_fmt(cursor)} 之后无变体覆盖")
    return problems


# =============================================================================
# lint：声明与正文的一致性
# =============================================================================
def check_rule(rule: Rule, support_from: str = SUPPORTED_FROM) -> tuple[list[str], list[str]]:
    """比对「声明」与「正文」。返回 (错误, 提示)。

    错误 = 会真的跑挂或留下覆盖空洞；
    提示 = 声明比实际需要的严（可以放宽，但不影响正确性）。
    """
    errors: list[str] = []
    hints: list[str] = []
    usages = scan(rule)
    if not usages and not rule.since and not rule.removed_in:
        return errors, hints

    lo = parse_version(support_from)
    needed = min_version(usages)
    declared = rule.since_tuple or lo

    # --- 方向一：声明过宽 —— 正文要求的版本高于 @since ---
    # 这是最危险的一类：规则会在旧版本上执行并失败，而 @since 声称它没事。
    if needed and not version_ge(declared, parse_version(needed)):
        offenders = sorted({
            u.signal.obj
            for u in usages
            if u.hard and u.signal.since_tuple and not version_ge(declared, u.signal.since_tuple)
        })
        msg = (
            f"{rule.path.name}: @since {rule.since or SUPPORT_FROM} 过宽 —— "
            f"正文硬引用了 {'、'.join(offenders)}（需要 {needed}+）。"
        )
        # 严重性分两层：差异只落在补丁级（同一条 5.7 线内，如 @since 5.7 vs
        # 信号需要 5.7.3）→ 声明精度问题，生产上没人装 5.7.0~5.7.2，报成错误
        # 只会淹没真问题；跨了次版本线（@since 5.7 vs 需要 8.0.22）→ 真的缺陷。
        if _norm(declared)[:2] == _norm(parse_version(needed))[:2]:
            hints.append(msg + f"差异只在补丁级，严格对齐可把 @since 写成 {needed}。")
        else:
            errors.append(
                msg + f"在 {rule.since or SUPPORT_FROM} ~ {needed} 区间执行会报错，"
                "应改 @since 或改用软查表写法。"
            )

    # --- 方向二：硬引用有上界的信号，却没声明 @removed_in ---
    uppers = hard_upper_bounds(usages)
    if uppers and not rule.removed_tuple:
        errors.append(
            f"{rule.path.name}: 硬引用了 {'、'.join(s.obj + f'（{s.removed_in} 起移除）' for s in uppers)}，"
            "但没有声明 @removed_in —— 会在移除版本上失败。"
        )
    elif uppers and rule.removed_tuple:
        # 声明的上界不该**晚于**信号的上界。
        # 注意必须是严格大于：@removed_in 与 signal.removed_in 的语义相同
        # （都是"该版本起不可用"），所以两者相等是完美对齐，不是问题。
        rule_end = _norm(rule.removed_tuple)
        for s in uppers:
            if rule_end > _norm(s.removed_tuple):
                errors.append(
                    f"{rule.path.name}: @removed_in {rule.removed_in} 晚于信号的上界 —— "
                    f"{s.obj} 在 {s.removed_in} 就没了，"
                    f"{_fmt(s.removed_tuple)} ~ {rule.removed_in} 区间会执行失败。"
                )

    # --- 方向三：声明过窄 —— 正文只用到 5.7 就有的东西，却把 @since 写得很高 ---
    # 只提示不报错：有可能规则是因为"语义上只在 8.0 成立"而声明 8.0，
    # 那类理由信号表看不出来，得人来判断。
    if rule.since_tuple and not version_ge(rule.since_tuple, lo) is False:
        pass
    if rule.since_tuple and version_ge(rule.since_tuple, parse_version(needed or SUPPORTED_FROM)):
        if needed and version_ge(rule.since_tuple, parse_version(needed)) and rule.since_tuple != parse_version(needed):
            hints.append(
                f"{rule.path.name}: @since {rule.since} 比正文要求（{needed}）更严 —— "
                "如果只是因为信号不可用才这么写，可以放宽；"
                "若是语义原因（判定逻辑只在 8.0 成立），忽略本提示。"
            )

    # --- 方向四：正文引用了未登记的信号 ---
    unreg = unregistered(rule)
    if unreg:
        hints.append(
            f"{rule.path.name}: 引用了未登记的对象 {'、'.join(unreg)} —— "
            "无法判定版本兼容性，请登记到 mbot/signals.py 的 _ORDER。"
        )
    return errors, hints


# 已登记的 schema 前缀；未登记的引用会被 check_rule 报为"无法判定"。
_KNOWN_PREFIXES = ("performance_schema.", "information_schema.", "sys.", "mysql.")


def unregistered(rule: Rule) -> list[str]:
    """正文里引用的、登记表覆盖不到的库限定对象名。"""
    known = {s.name.lower() for s in SIGNALS.values()}
    known |= {s.obj.lower() for s in SIGNALS.values()}
    found: set[str] = set()
    for m in re.finditer(r"\b([a-z_]+)\s*\.\s*([a-zA-Z_][a-zA-Z0-9_]*)", rule.sql):
        schema, obj = m.group(1).lower(), m.group(2)
        if f"{schema}.{obj}".lower() in known or obj.lower() in known:
            continue
        # 只报真正的系统库；业务库的表（如 app_db.xxx）不归信号表管
        if f"{schema}." in _KNOWN_PREFIXES and not schema.startswith(("cs_", "db_")):
            if schema in ("performance_schema", "information_schema", "sys", "mysql"):
                found.add(f"{schema}.{obj}")
    return sorted(found)
