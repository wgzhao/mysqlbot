"""规则文件的加载与元数据解析。

一条规则 = 一个 .sql 文件。文件头部是 `-- @key: value` 形式的元数据注释，
第一个非注释非空行之后全部是 SQL 主体。

契约（与 pgbot 一致）：
  **返回 0 行 = 未命中；返回 N 行 = 命中，且每行必须含 severity 列。**
这样每条规则都能脱离本工具、直接在 mysql 客户端或 DBeaver 里单独执行验证。
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

# -- @id: xxx
_HEADER_RE = re.compile(r"^--\s*@([a-z_]+)\s*:\s*(.*)$")

SEVERITY_ORDER = {"info": 0, "warn": 1, "critical": 2}
SEVERITY_LABEL = {"info": "INFO", "warn": "WARN", "critical": "CRIT"}

# 受控词表：维度 / 作用域 / 结论精确度。lint 会校验，防止词表随时间发散。
DIMENSIONS = {"latency", "throughput", "capacity", "risk", "hygiene"}
SCOPES = {"instance", "schema", "workload", "cluster", "history"}
# exact：直接读出的事实（如变量、版本）
# catalog：来自数据字典的确定结构（表定义、索引定义）
# cumulative：自实例启动累计的计数器，重启清零
# sampled：依赖统计采样，需运行足够久才可信
# scraped：从某处抓取的瞬时值
# unavailable：本次未能获取
EXACTNESS = {"exact", "catalog", "cumulative", "sampled", "scraped", "unavailable"}

# 逻辑字段名 -> 头部 @key
_KEY_MAP = {
    "id": "id",
    "title": "title",
    "severity": "severity",
    "dimension": "dimension",
    "scope": "scope",
    "obj": "object",
    "requires": "requires",
    "exactness": "exactness",
    "since": "since",
    "removed_in": "removed_in",
    "variant_of": "variant_of",
    "remediation": "remediation",
    "caveats": "caveats",
    "ref": "ref",
    "safety": "safety",
    "safety_note": "safety_note",
    "tags": "tags",
    "min_uptime": "min_uptime",
}


class RuleError(Exception):
    """规则文件不符合契约。"""


def parse_version(text: str) -> tuple[int, ...]:
    """'5.7' -> (5,7); '8.0.30' -> (8,0,30); '8.4' -> (8,4)。"""
    if not text:
        return ()
    parts = re.findall(r"\d+", str(text))
    return tuple(int(p) for p in parts) if parts else ()


def version_ge(a: tuple[int, ...], b: tuple[int, ...]) -> bool:
    """比较版本元组，长度不足的补 0（(8,4) >= (8,4,0) 为真）。"""
    n = max(len(a), len(b))
    a = a + (0,) * (n - len(a))
    b = b + (0,) * (n - len(b))
    return a >= b


@dataclass
class Rule:
    id: str
    path: Path
    title: str = ""
    severity: str = "warn"
    dimension: str = "risk"
    scope: str = "instance"
    obj: str = "-"
    requires: list[str] = field(default_factory=list)
    exactness: str = "catalog"
    since: str = ""
    removed_in: str = ""
    # 同一条逻辑规则的版本变体，指向基础规则的 @id。
    # 显式声明（而非靠 `_57` 后缀推断）是为了让 lint 能断言
    # "变体集合无缝覆盖声明区间" —— 见 signals.variant_gaps()。
    variant_of: str = ""
    remediation: str = ""
    caveats: str = ""
    ref: str = "-"
    safety: str = ""
    safety_note: str = ""
    tags: list[str] = field(default_factory=list)
    # 需要实例运行满这么多秒，累计型计数器才可信。0 表示无要求。
    min_uptime: int = 0
    sql: str = ""
    raw_header: dict[str, str] = field(default_factory=dict)

    @property
    def since_tuple(self) -> tuple[int, ...]:
        return parse_version(self.since)

    @property
    def removed_tuple(self) -> tuple[int, ...]:
        return parse_version(self.removed_in)

    def supports_version(self, ver: tuple[int, ...]) -> bool:
        if not ver:
            return True
        if self.since_tuple and not version_ge(ver, self.since_tuple):
            return False
        if self.removed_tuple and version_ge(ver, self.removed_tuple):
            return False
        return True


def parse_rule_text(text: str, path: Path) -> Rule:
    header: dict[str, str] = {}
    body_lines: list[str] = []
    in_body = False

    for line in text.splitlines():
        if not in_body:
            stripped = line.strip()
            if stripped == "" or stripped.startswith("--"):
                m = _HEADER_RE.match(line.strip())
                if m:
                    key, val = m.group(1), m.group(2).strip()
                    # 同键多次出现时后者覆盖（便于规则内追加说明）
                    header[key] = val
                continue
            in_body = True
        body_lines.append(line)

    sql = "\n".join(body_lines).strip().rstrip(";").strip()
    if not sql:
        raise RuleError(f"{path.name}: 缺少 SQL 主体")

    if "id" not in header:
        raise RuleError(f"{path.name}: 缺少 @id")

    kwargs: dict = {"id": header["id"], "path": path, "sql": sql, "raw_header": header}
    for attr, key in _KEY_MAP.items():
        if attr in ("id",):
            continue
        if key in header:
            val = header[key]
            if attr in ("requires", "tags"):
                # `-` / `none` 是显式的"无"占位符（与 @ref: - 的写法一致）
                if val.strip() in ("-", "none", "None", "无"):
                    val = []
                else:
                    val = [t.strip() for t in val.split(",") if t.strip()]
            elif attr == "min_uptime":
                try:
                    val = int(float(val))
                except ValueError as exc:
                    raise RuleError(f"{path.name}: @min_uptime 必须是秒数，实为 {val!r}") from exc
            kwargs[attr] = val

    if kwargs.get("severity") not in SEVERITY_ORDER:
        raise RuleError(f"{path.name}: @severity 必须是 info/warn/critical 之一，实为 {kwargs.get('severity')!r}")

    return Rule(**kwargs)


def load_rules(rules_dir: Path) -> tuple[list[Rule], list[str]]:
    """加载目录下所有规则，返回 (规则列表, 解析失败说明列表)。"""
    rules: list[Rule] = []
    errors: list[str] = []
    for path in sorted(Path(rules_dir).glob("*.sql")):
        try:
            rules.append(parse_rule_text(path.read_text(encoding="utf-8"), path))
        except RuleError as exc:
            errors.append(str(exc))

    seen: dict[str, str] = {}
    for r in rules:
        if r.id in seen:
            errors.append(f"重复的 @id: {r.id} ({seen[r.id]} 与 {r.path.name})")
        seen[r.id] = r.path.name
    return rules, errors
