#!/usr/bin/env python3
"""错误分类与结果截断判定的单元测试 —— 不需要数据库。

守住两件事，都是 2026-09-16 在真实 5.7.44 上暴露出来的：

1. **「权限不足」和「SQL 与版本不匹配」必须落成两种不同的规则状态。**
   原先 1054（列不存在）和 1193（变量不存在）跟 1142（权限不足）一起被归为
   "可降级"，两者都变成 `skipped`。后果是 5.7 上 `full_table_scan_heavy`、
   `statement_high_total_latency`、`replication_stopped` 三条规则带着真实的版本
   不兼容缺陷，伪装成"环境限制导致的跳过"，而自测里"0 条报错"这条硬断言
   因此变成一句空话——工具坏了，报告却说环境不行。
   正确的分工：权限 → skipped（你去加权限）；版本不匹配 → error（工具要修）。

2. **结果截断必须可见。** 规则普遍带 `LIMIT 10/50` 防刷屏。命中行数正好等于
   LIMIT 时，"N 行"的真实含义是"至少 N 行"。5.7 那个实例上 `unused_index`
   报了 50 行，而实际符合条件的有 66 个——报告不标注就会被读成"一共 50 条"。

用法：python3 tests/test_classify.py
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from mbot.conn import QueryError, _classify  # noqa: E402
from mbot.report import HIT, CLEAN, Outcome  # noqa: E402
from mbot.rule import Rule  # noqa: E402
from mbot.runner import _outer_limit  # noqa: E402

FAILED = 0


def check(name: str, got, want) -> None:
    global FAILED
    if got == want:
        print(f"  ✓ {name}")
    else:
        FAILED += 1
        print(f"  ✗ {name}\n      期望 {want!r}\n      实际 {got!r}")


def err(code: int) -> QueryError:
    return QueryError(f"ERR {code}", code=code, kind=_classify(code))


print("── 错误分类：可降级（环境不给能力） ──")
for code, label in [
    (1044, "Access denied to database"),
    (1045, "Access denied (auth)"),
    (1142, "SELECT command denied"),
    (1227, "需要 PROCESS 权限"),
    (1146, "表不存在，如 5.7 没有 data_locks"),
    (1109, "Unknown table"),
    (1305, "sys 库的函数没装"),
]:
    check(f"{code} {label} → 可降级", err(code).degradable, True)

print("\n── 错误分类：不可降级（工具缺陷，必须报 error） ──")
for code, label in [
    (1054, "列在本版本不存在，如 QUERY_SAMPLE_TEXT 是 8.0.22+"),
    (1193, "变量在本版本不存在，如 binlog_expire_logs_seconds"),
    (1231, "会话前导设置了本版本不认的变量"),
    (1064, "语法错误"),
]:
    check(f"{code} {label} → 不可降级", err(code).degradable, False)

print("\n── 分类结果本身 ──")
check("1054 → version_mismatch", _classify(1054), "version_mismatch")
check("1193 → version_mismatch", _classify(1193), "version_mismatch")
check("1142 → permission", _classify(1142), "permission")
check("1146 → missing_object", _classify(1146), "missing_object")
check("1231 → version_mismatch", _classify(1231), "version_mismatch")

print("\n── 外层 LIMIT 解析 ──")
check(
    "普通结尾 LIMIT",
    _outer_limit("SELECT 1 FROM t WHERE x > 1\nLIMIT 50"),
    50,
)
check("带分号", _outer_limit("SELECT 1 FROM t LIMIT 10;"), 10)
check("小写 limit", _outer_limit("select 1 from t limit 7"), 7)
check("没有 LIMIT", _outer_limit("SELECT 1 FROM t WHERE x = 1"), None)
check(
    "子查询里的 LIMIT 不算外层（规则真实存在的写法）",
    _outer_limit(
        "SELECT * FROM (\n"
        "  SELECT OBJECT_SCHEMA FROM performance_schema.x LIMIT 1\n"
        ") u\n"
        "WHERE u.a = 1"
    ),
    None,
)
check(
    "子查询有 LIMIT、外层也有",
    _outer_limit("SELECT * FROM (SELECT 1 LIMIT 1) x WHERE 1 LIMIT 20"),
    20,
)

print("\n── 截断判定 ──")
rule = Rule(id="t", path=Path("t.sql"))


def hit(n: int, limit: int | None) -> Outcome:
    return Outcome(rule, HIT, rule.severity, "", rows=[{}] * n, row_limit=limit)


check("50 行 / LIMIT 50 → 截断", hit(50, 50).truncated, True)
check("49 行 / LIMIT 50 → 未截断", hit(49, 50).truncated, False)
check("3 行 / 无 LIMIT → 未截断", hit(3, None).truncated, False)
check("干净结果不判截断", Outcome(rule, CLEAN, row_limit=50).truncated, False)
check("跳过结果不判截断", Outcome(rule, "skipped", row_limit=50).truncated, False)

print()
if FAILED:
    print(f"✗ {FAILED} 项失败")
    sys.exit(1)
print("✓ 全部通过")
