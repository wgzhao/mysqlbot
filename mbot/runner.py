"""编排：探测能力 → 逐条门禁 → 执行 → 收集结论。

三条纪律：
  1. 版本不满足、能力位缺失 → skipped 并写明原因，绝不静默当"干净"
  2. 规则返回行但缺 severity 列 → 契约违规，记 error（不是 hit）
  3. 任何单条规则的失败都不中断整轮巡检
"""

from __future__ import annotations

import hashlib
import re
import time
from dataclasses import dataclass
from pathlib import Path

from .conn import QueryError
from .probe import Capabilities
from .report import CLEAN, ERROR, HIT, SKIPPED, Outcome
from .rule import SEVERITY_ORDER, Rule, version_ge


@dataclass
class RunOptions:
    only: list[str] | None = None
    skip: list[str] | None = None
    dimensions: list[str] | None = None
    scopes: list[str] | None = None
    tags: list[str] | None = None
    min_severity: str = "info"
    init_sql: list[str] | None = None
    no_init: bool = False
    ignore_min_uptime: bool = False
    deadline_s: float = 0.0  # 单条规则软超时（0 = 用连接层默认）


def fmt_duration(seconds: float) -> str:
    s = int(seconds)
    if s < 60:
        return f"{s} 秒"
    if s < 3600:
        return f"{s // 60} 分钟"
    if s < 86400:
        return f"{s / 3600:.1f} 小时"
    return f"{s / 86400:.1f} 天"


def default_init_sql(caps: Capabilities) -> list[str]:
    """会话前导语句，与规则 SQL 在同一连接内执行。

    必须只含「不产生结果集」的语句——CLI 驱动在 batch 模式下会把每个语句的
    结果集依次打印，多一个结果集就会让解析错位。SET/USE 都满足。
    """
    stmts: list[str] = []
    # 关键：information_schema.TABLES 的行数/大小默认缓存 24 小时
    # （information_schema_stats_expiry=86400）。不关掉它，所有基于表大小的
    # 发现读到的都是过期值——这是最隐蔽也最致命的一个坑。
    if caps.version and version_ge(caps.version, (8, 0)) and not caps.is_mariadb:
        stmts.append("SET SESSION information_schema_stats_expiry = 0")
    return stmts


def _normalize_patterns(patterns: list[str] | None) -> list[str]:
    """把 `--only a,b` 这种逗号/空格分隔的写法摊平成独立 pattern。

    CLI 用的是 action="append"，`--only 'a,b'` 会被当成**一个** pattern，
    fnmatch 匹配不到任何规则 id，结果就是"过滤后没有剩余规则"——而 README/SKILL
    里恰恰是这么示范的。所以在这里统一摊平，两种写法都认。
    """
    if not patterns:
        return []
    out: list[str] = []
    for p in patterns:
        out.extend(part for part in re.split(r"[,\s]+", p.strip()) if part)
    return out


def _match_name(name: str, patterns: list[str] | None) -> bool:
    pats = _normalize_patterns(patterns)
    if not pats:
        return False
    from fnmatch import fnmatch

    return any(fnmatch(name, p) for p in pats)


def select_rules(rules: list[Rule], opt: RunOptions) -> list[Rule]:
    out = []
    for r in rules:
        if opt.only and not _match_name(r.id, opt.only):
            continue
        if _match_name(r.id, opt.skip):
            continue
        if opt.dimensions and r.dimension not in opt.dimensions:
            continue
        if opt.scopes and r.scope not in opt.scopes:
            continue
        if opt.tags and not (set(opt.tags) & set(r.tags)):
            continue
        if SEVERITY_ORDER.get(r.severity, 0) < SEVERITY_ORDER.get(opt.min_severity, 0):
            continue
        out.append(r)
    return out


def gate(rule: Rule, caps: Capabilities, ignore_min_uptime: bool = False) -> str | None:
    """返回 None 表示可以通过；否则返回跳过原因。

    运行时长门禁放在这里而不是写进 SQL：累计型计数器（命中率、未使用索引、
    tmp 表比例）在实例刚重启时数值毫无意义，但"因此不报"必须是**显式的跳过**，
    不能表现为"没有发现问题"——那是假干净。
    """
    if not rule.supports_version(caps.version):
        if rule.since_tuple and not version_ge(caps.version, rule.since_tuple):
            return f"需要 MySQL >= {rule.since}"
        if rule.removed_tuple:
            return f"MySQL >= {rule.removed_in} 已移除该信号源"
    if rule.min_uptime and not ignore_min_uptime:
        uptime = caps.fact("uptime_s")
        if uptime is None:
            return f"无法读取实例运行时长，而本规则需要运行满 {fmt_duration(rule.min_uptime)} 才能判定"
        if uptime < rule.min_uptime:
            return (
                f"实例运行时间不足：累计计数器需要 {fmt_duration(rule.min_uptime)}，"
                f"当前仅 {fmt_duration(uptime)}（重启后计数器清零，此刻结论不可信）"
            )
    missing = caps.missing(rule.requires)
    if missing:
        detail = "；".join(caps.reasons.get(m, "") for m in missing if caps.reasons.get(m))
        return f"缺少能力位 {', '.join(missing)}" + (f"（{detail}）" if detail else "")
    return None


def _effective_severity(rule: Rule, rows: list[dict]) -> str:
    """规则声明的是下限；SQL 里可以用 severity 列升级（例如 CASE WHEN 阈值 THEN 'critical'）。"""
    best = rule.severity
    for row in rows:
        v = str(row.get("severity") or "").strip().lower()
        if v in SEVERITY_ORDER and SEVERITY_ORDER[v] > SEVERITY_ORDER.get(best, 0):
            best = v
    return best


def _fingerprint(rule_id: str, row: dict) -> str:
    ident = {k: v for k, v in row.items() if k in ("table_schema", "table_name", "index_name", "object", "thread_id", "pid")}
    if not ident:
        ident = {k: v for k, v in list(row.items())[:3]}
    blob = f"{rule_id}|" + "|".join(f"{k}={v}" for k, v in sorted(ident.items()))
    return hashlib.sha1(blob.encode("utf-8", "replace")).hexdigest()[:12]


# 只认**结尾**的 LIMIT，即规则最外层那个。子查询里的 LIMIT 不在结尾，不会误判。
_OUTER_LIMIT_RE = re.compile(r"\bLIMIT\s+(\d+)\s*$", re.IGNORECASE)


def _outer_limit(sql: str) -> int | None:
    """取规则最外层的 LIMIT 值。

    用途是识别**截断**：规则为了不刷屏普遍带 `LIMIT 10/50`，当返回行数正好等于
    该值时，"命中 N 行"的真实含义是"至少 N 行"。报告不标注就会被读成"一共就这些"。
    """
    m = _OUTER_LIMIT_RE.search(sql.strip().rstrip(";").strip())
    return int(m.group(1)) if m else None


def run_rule(rule: Rule, conn, caps: Capabilities, opt: RunOptions, preamble: list[str]) -> Outcome:
    started = time.perf_counter()
    sql = rule.sql
    if preamble:
        sql = ";\n".join(preamble) + ";\n" + sql
    try:
        result = conn.query(sql)
    except QueryError as exc:
        elapsed = (time.perf_counter() - started) * 1000
        if exc.degradable:
            return Outcome(rule, SKIPPED, rule.severity, f"执行被拒（{exc}）", elapsed_ms=elapsed)
        if exc.kind == "version_mismatch":
            return Outcome(
                rule,
                ERROR,
                rule.severity,
                f"SQL 与目标版本不匹配：{exc}。"
                "规则的列/变量在目标版本不存在——正确做法是在头部用 "
                "@since/@removed_in 声明适用范围，而不是靠降级掩盖。",
                elapsed_ms=elapsed,
            )
        return Outcome(rule, ERROR, rule.severity, str(exc), elapsed_ms=elapsed)

    elapsed = (time.perf_counter() - started) * 1000
    cols = result.columns
    if not cols:
        return Outcome(rule, CLEAN, rule.severity, "无结果集", elapsed_ms=elapsed)
    if "severity" not in cols:
        return Outcome(
            rule,
            ERROR,
            rule.severity,
            f"契约违规：结果集缺少 severity 列（实际列 {cols}）",
            elapsed_ms=elapsed,
        )

    rows = result.dicts()
    if not rows:
        return Outcome(rule, CLEAN, rule.severity, "", columns=cols, elapsed_ms=elapsed)

    for row in rows:
        row["_fingerprint"] = _fingerprint(rule.id, row)
    return Outcome(
        rule,
        HIT,
        _effective_severity(rule, rows),
        "",
        columns=cols + ["_fingerprint"],
        rows=rows,
        elapsed_ms=elapsed,
        row_limit=_outer_limit(sql),
    )


def run_all(rules: list[Rule], conn, caps: Capabilities, opt: RunOptions) -> list[Outcome]:
    preamble: list[str] = []
    if not opt.no_init:
        preamble = default_init_sql(caps) + list(opt.init_sql or [])

    outcomes: list[Outcome] = []
    for rule in rules:
        reason = gate(rule, caps, opt.ignore_min_uptime)
        if reason:
            outcomes.append(Outcome(rule, SKIPPED, rule.severity, reason))
            continue
        outcomes.append(run_rule(rule, conn, caps, opt, preamble))
    return outcomes


def load_rules_dir(path: Path) -> tuple[list[Rule], list[str]]:
    from .rule import load_rules

    return load_rules(path)
