"""报告渲染。输出是契约，不是日志。

四种形态：
  table    —— 终端人读（默认）
  json     —— 机器消费，含能力位、跳过原因、每条命中的原始行
  markdown —— 贴进工单/文档
  sarif    —— 接 CI 与 GitHub Code Scanning
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from typing import Any

from .rule import SEVERITY_LABEL, SEVERITY_ORDER, Rule

# 状态
HIT = "hit"
CLEAN = "clean"
SKIPPED = "skipped"
ERROR = "error"


@dataclass
class Outcome:
    rule: Rule
    status: str
    severity: str = "info"
    reason: str = ""
    columns: list[str] = field(default_factory=list)
    rows: list[dict] = field(default_factory=list)
    elapsed_ms: float = 0.0
    # 规则 SQL 最外层的 LIMIT。命中行数正好等于它时，说明结果**可能被截断**：
    # 报告里的"N 行"其实是"至少 N 行"。不标出来就会把 50 条读成"一共 50 条"。
    row_limit: int | None = None

    @property
    def hit(self) -> bool:
        return self.status == HIT

    @property
    def truncated(self) -> bool:
        return (
            self.status == HIT
            and self.row_limit is not None
            and len(self.rows) >= self.row_limit
        )


def summarize(outcomes: list[Outcome]) -> dict[str, int]:
    counts = {"hit": 0, "clean": 0, "skipped": 0, "error": 0}
    for o in outcomes:
        counts[o.status] = counts.get(o.status, 0) + 1
    for sev in SEVERITY_ORDER:
        counts[sev] = sum(1 for o in outcomes if o.status == HIT and o.severity == sev)
    return counts


def overall_severity(outcomes: list[Outcome]) -> str:
    hit = [o for o in outcomes if o.status == HIT]
    if not hit:
        return "clean"
    return max((o.severity for o in hit), key=lambda s: SEVERITY_ORDER.get(s, 0))


# ---------------------------------------------------------------- JSON


def to_json(payload: dict) -> str:
    return json.dumps(payload, ensure_ascii=False, indent=2, default=_json_default)


def _json_default(obj: Any):
    if hasattr(obj, "isoformat"):
        return obj.isoformat()
    if isinstance(obj, (bytes, bytearray)):
        return obj.decode("utf-8", "replace")
    if isinstance(obj, set):
        return sorted(obj)
    return str(obj)


def build_payload(caps, outcomes: list[Outcome], meta: dict) -> dict:
    counts = summarize(outcomes)
    rules_block = []
    for o in outcomes:
        entry = {
            "rule": o.rule.id,
            "title": o.rule.title,
            "status": o.status,
            "severity": o.severity if o.status == HIT else o.rule.severity,
            "dimension": o.rule.dimension,
            "scope": o.rule.scope,
            "object": o.rule.obj,
            "exactness": o.rule.exactness,
            "row_count": len(o.rows),
            "elapsed_ms": round(o.elapsed_ms, 1),
        }
        if o.reason:
            entry["reason"] = o.reason
        if o.status == HIT:
            entry["remediation"] = o.rule.remediation
            entry["caveats"] = o.rule.caveats
            entry["ref"] = o.rule.ref
            if o.rule.safety:
                entry["safety"] = o.rule.safety
                entry["safety_note"] = o.rule.safety_note
            entry["rows"] = o.rows
            # 截断可见性：row_count == row_limit 时真实数量是"至少这么多"。
            if o.row_limit is not None:
                entry["row_limit"] = o.row_limit
                entry["truncated"] = o.truncated
        rules_block.append(entry)

    return {
        "schema": "mysqlbot/report/v1",
        "tool": "mysqlbot",
        "version": meta.get("tool_version", ""),
        "generated_at": meta.get("generated_at", ""),
        "target": {
            "version": caps.version_str,
            "version_comment": caps.version_comment,
            "edition": "MariaDB" if caps.is_mariadb else ("Percona" if caps.is_percona else "MySQL"),
            "current_user": caps.current_user,
            "host": meta.get("host_label", ""),
        },
        "capabilities": {
            "flags": caps.flags,
            "missing_reasons": caps.reasons,
            "notes": caps.notes,
            "facts": caps.facts,
            "grants": caps.grants,
            "visible_schemas": caps.schemas,
        },
        "summary": {
            "overall": overall_severity(outcomes),
            "hit": counts["hit"],
            "clean": counts["clean"],
            "skipped": counts["skipped"],
            "error": counts["error"],
            "by_severity": {k: counts.get(k, 0) for k in SEVERITY_ORDER},
        },
        "rules": rules_block,
    }


# ---------------------------------------------------------------- Markdown


def _fmt_cell(v: Any, width: int = 60) -> str:
    if v is None:
        return "-"
    s = str(v).replace("\n", " ").replace("|", "\\|")
    return s if len(s) <= width else s[: width - 1] + "…"


def to_markdown(caps, outcomes: list[Outcome], meta: dict) -> str:
    counts = summarize(outcomes)
    hits = [o for o in outcomes if o.status == HIT]
    out: list[str] = []
    out.append("# mysqlbot 体检报告")
    out.append("")
    out.append(f"- 目标：`{meta.get('host_label', '')}`  ·  MySQL {caps.version_str}"
               f"（{caps.version_comment or 'n/a'}）")
    out.append(f"- 账号：`{caps.current_user}`")
    out.append(f"- 生成时间：{meta.get('generated_at', '')}")
    out.append(f"- 结论：**{overall_severity(outcomes).upper()}** — 命中 {counts['hit']}"
               f" / 干净 {counts['clean']} / 跳过 {counts['skipped']} / 失败 {counts['error']}")
    out.append("")

    if hits:
        out.append("## 命中项")
        out.append("")
        out.append("| 严重度 | 规则 | 维度 | 对象 | 行数 | 说明 |")
        out.append("|---|---|---|---|---|---|")
        for o in sorted(hits, key=lambda x: -SEVERITY_ORDER.get(x.severity, 0)):
            out.append(
                f"| {SEVERITY_LABEL.get(o.severity, o.severity)} | `{o.rule.id}` | {o.rule.dimension}"
                f" | {o.rule.obj} | {len(o.rows)} | {_fmt_cell(o.rule.title)} |"
            )
        out.append("")
        truncated = [o for o in hits if o.truncated]
        if truncated:
            out.append(
                "> ⚠️ 以下规则的结果**被 SQL 的 LIMIT 截断**，行数是下限而非全量："
                + "、".join(f"`{o.rule.id}`（≥{len(o.rows)}）" for o in truncated)
            )
            out.append("")
        for o in sorted(hits, key=lambda x: -SEVERITY_ORDER.get(x.severity, 0)):
            out.append(f"### {SEVERITY_LABEL.get(o.severity, o.severity)} · {o.rule.id} — {o.rule.title}")
            out.append("")
            if o.rule.remediation:
                out.append(f"**处置**：{o.rule.remediation}")
                out.append("")
            if o.rule.caveats:
                out.append(f"**注意**：{o.rule.caveats}")
                out.append("")
            cols = o.columns
            shown = o.rows[:20]
            out.append("| " + " | ".join(cols) + " |")
            out.append("|" + "---|" * len(cols))
            for row in shown:
                out.append("| " + " | ".join(_fmt_cell(row.get(c)) for c in cols) + " |")
            if len(o.rows) > len(shown):
                out.append("")
                out.append(f"_另有 {len(o.rows) - len(shown)} 行未列出_")
            if o.truncated:
                out.append("")
                out.append(
                    f"_本规则 SQL 带 `LIMIT {o.row_limit}`，命中数已达上限——"
                    f"真实命中 **≥ {len(o.rows)}** 条，不是 {len(o.rows)} 条。_"
                )
            if o.rule.safety:
                out.append("")
                out.append(f"> ⚠️ 本项证据含可执行语句：`{o.rule.safety}`。{o.rule.safety_note}")
            out.append("")

    skipped = [o for o in outcomes if o.status == SKIPPED]
    errored = [o for o in outcomes if o.status == ERROR]
    if skipped or errored:
        out.append("## 未覆盖（这不等于干净）")
        out.append("")
        out.append("| 规则 | 状态 | 原因 |")
        out.append("|---|---|---|")
        for o in skipped + errored:
            out.append(f"| `{o.rule.id}` | {o.status} | {_fmt_cell(o.reason)} |")
        out.append("")

    out.append("## 能力位")
    out.append("")
    out.append("| 能力 | 状态 | 说明 |")
    out.append("|---|---|---|")
    for k in sorted(caps.flags):
        ok = caps.flags[k]
        out.append(f"| `{k}` | {'✅' if ok else '❌'} | {_fmt_cell(caps.reasons.get(k, ''))} |")
    out.append("")
    if caps.schemas:
        out.append(f"**扫描覆盖的 schema（{len(caps.schemas)} 个）**："
                   + "、".join(f"`{s}`" for s in caps.schemas))
        out.append("")
    if caps.notes:
        out.append("")
        for n in caps.notes:
            out.append(f"- {n}")
    out.append("")
    return "\n".join(out)


# ---------------------------------------------------------------- Table


def to_table(caps, outcomes: list[Outcome], meta: dict, show_rows: int = 5, verbose: bool = False) -> str:
    counts = summarize(outcomes)
    hits = sorted(
        [o for o in outcomes if o.status == HIT],
        key=lambda x: (-SEVERITY_ORDER.get(x.severity, 0), x.rule.id),
    )
    width = 88
    out: list[str] = []
    sep = "─" * width

    out.append(sep)
    out.append(f"mysqlbot · {meta.get('host_label', '')} · MySQL {caps.version_str}"
               f" · user={caps.current_user}")
    out.append(f"生成 {meta.get('generated_at', '')}")
    out.append(sep)

    verdict = overall_severity(outcomes).upper()
    icon = {"CRITICAL": "🔴", "WARN": "🟡", "INFO": "🔵", "CLEAN": "🟢"}.get(verdict, "•")
    out.append(
        f"{icon} {verdict:9s} 命中 {counts['hit']:2d}   干净 {counts['clean']:2d}"
        f"   跳过 {counts['skipped']:2d}   失败 {counts['error']:2d}"
        f"   （共 {len(outcomes)} 条规则）"
    )
    out.append(sep)

    if not hits:
        out.append("没有命中任何规则。")
    for o in hits:
        label = SEVERITY_LABEL.get(o.severity, o.severity)
        rows_label = f"≥{len(o.rows)} 行" if o.truncated else f"{len(o.rows)} 行"
        out.append(f"[{label}] {o.rule.id}  ({o.rule.dimension}/{o.rule.scope}, {rows_label})")
        out.append(f"        {o.rule.title}")
        for row in o.rows[:show_rows]:
            pairs = "  ".join(
                f"{c}={_fmt_cell(v, 40)}" for c, v in row.items() if v not in (None, "")
            )
            out.append(f"        · {pairs}")
        if len(o.rows) > show_rows:
            out.append(f"        · …另有 {len(o.rows) - show_rows} 行（-o json 看全量）")
        if o.truncated:
            out.append(f"        · 已达 SQL 的 LIMIT {o.row_limit}，真实命中 ≥ {len(o.rows)} 条")
        if verbose and o.rule.remediation:
            out.append(f"        处置: {o.rule.remediation}")
        if o.rule.safety:
            out.append(f"        ⚠ 含可执行语句: {o.rule.safety}")
        out.append("")

    if hits and not verbose:
        out.append("提示：-v 显示处置建议，-o json 输出完整契约，-o markdown 生成报告。")
        out.append("")

    skipped = [o for o in outcomes if o.status == SKIPPED]
    errored = [o for o in outcomes if o.status == ERROR]
    if skipped or errored:
        out.append(sep)
        out.append(f"未覆盖 {len(skipped) + len(errored)} 条（不等于干净，按规则看原因）：")
        for o in skipped + errored:
            out.append(f"  - {o.rule.id}: {_fmt_cell(o.reason, 70)}")
        out.append("")

    missing_caps = [k for k, v in caps.flags.items() if not v and k in caps.reasons]
    if missing_caps:
        out.append(f"缺失能力位: {', '.join(sorted(missing_caps))}")
    for n in caps.notes:
        out.append(f"⚠ {n}")
    out.append(sep)
    return "\n".join(out)


# ---------------------------------------------------------------- SARIF


def to_sarif(caps, outcomes: list[Outcome], meta: dict) -> str:
    """SARIF 2.1.0，用于 CI 门禁。每条规则一个 reportingDescriptor，每次命中一条 result。"""
    all_rules = [o.rule for o in outcomes]
    sarif_rules = []
    results = []
    for o in outcomes:
        sarif_rules.append(
            {
                "id": o.rule.id,
                "name": o.rule.id,
                "shortDescription": {"text": o.rule.title},
                "fullDescription": {"text": o.rule.remediation or o.rule.title},
                "help": {"text": "\n\n".join(x for x in (o.rule.remediation, o.rule.caveats) if x)},
                "properties": {
                    "dimension": o.rule.dimension,
                    "scope": o.rule.scope,
                    "exactness": o.rule.exactness,
                    "tags": o.rule.tags,
                },
                "defaultConfiguration": {"level": _sarif_level(o.rule.severity)},
            }
        )
        if o.status != HIT:
            continue
        for idx, row in enumerate(o.rows):
            results.append(
                {
                    "ruleId": o.rule.id,
                    "level": _sarif_level(o.severity),
                    "message": {
                        "text": f"{o.rule.title} — " + ", ".join(
                            f"{k}={v}" for k, v in list(row.items())[:6] if v is not None
                        )
                    },
                    "partialFingerprints": {
                        "mysqlbot/v1": f"{o.rule.id}:{idx}:{abs(hash(json.dumps(row, sort_keys=True, default=str))) % 10**8}"
                    },
                    "properties": {"object": o.rule.obj, "rows": row},
                }
            )
    sarif = {
        "version": "2.1.0",
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        "runs": [
            {
                "tool": {
                    "driver": {
                        "name": "mysqlbot",
                        "version": meta.get("tool_version", ""),
                        "informationUri": "https://github.com/",
                        "rules": sarif_rules,
                    }
                },
                "invocations": [
                    {
                        "executionSuccessful": True,
                        "startTimeUtc": meta.get("generated_at_utc", ""),
                        "properties": {
                            "targetVersion": caps.version_str,
                            "currentUser": caps.current_user,
                            "capabilities": caps.flags,
                        },
                    }
                ],
                "results": results,
            }
        ],
    }
    return json.dumps(sarif, ensure_ascii=False, indent=2)


def _sarif_level(sev: str) -> str:
    return {"critical": "error", "warn": "warning", "info": "note"}.get(sev, "warning")


def outcome_asdict(o: Outcome) -> dict:
    d = asdict(o)
    d.pop("rule", None)
    return d
