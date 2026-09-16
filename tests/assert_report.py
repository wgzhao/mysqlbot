#!/usr/bin/env python3
"""自测断言：读 mbot 的 JSON 报告，校验三件事。

  1. 没有任何规则处于 error 状态（这一条专门抓"未知名/未知表/未知变量"这类
     SQL 与目标版本不匹配的问题——它们在其他工具里往往表现为静默返回空结果）
  2. expected_hits.txt 里每条都必须 status=hit（硬断言）
  3. expected_hits_soft.txt 里每条都应命中（只告警）

用法: assert_report.py <report.json> [expected_hits.txt] [expected_hits_soft.txt]
"""

from __future__ import annotations

import json
import sys
from pathlib import Path


def read_ids(path: str) -> list[str]:
    """读取期望命中列表。注释支持 # 与 -- 两种前缀（照顾习惯写 SQL 注释的人）。"""
    if not path or not Path(path).is_file():
        return []
    out = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("--"):
            continue
        out.append(line)
    return out


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: assert_report.py <report.json> [hard.txt] [soft.txt]", file=sys.stderr)
        return 2

    report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    hard = read_ids(sys.argv[2] if len(sys.argv) > 2 else "")
    soft = read_ids(sys.argv[3] if len(sys.argv) > 3 else "")

    rules = {r["rule"]: r for r in report.get("rules", [])}
    summary = report.get("summary", {})

    print("=" * 78)
    print(f"目标    : {report['target']['version_comment']} {report['target']['version']}")
    print(f"账号    : {report['target']['current_user']}")
    print(f"规则总数: {len(rules)}   命中 {summary.get('hit')}  "
          f"干净 {summary.get('clean')}  跳过 {summary.get('skipped')}  失败 {summary.get('error')}")
    print("=" * 78)

    failures: list[str] = []
    warnings: list[str] = []

    # 1) 契约与执行错误
    errored = [r for r in rules.values() if r["status"] == "error"]
    if errored:
        print("\n【失败】以下规则执行报错（说明 SQL 与目标版本不兼容）：")
        for r in errored:
            print(f"  ✗ {r['rule']}: {r.get('reason', '')}")
            failures.append(f"{r['rule']} 执行报错")
    else:
        print("\n[OK] 所有规则均无执行错误")

    # 2) 硬断言
    if hard:
        print(f"\n【硬断言】{len(hard)} 条必须命中：")
        for rid in hard:
            r = rules.get(rid)
            if r is None:
                print(f"  ✗ {rid}: 规则不存在（是不是改过 id？）")
                failures.append(f"{rid} 规则不存在")
            elif r["status"] == "hit":
                print(f"  ✓ {rid}  ({r['severity']}, {r['row_count']} 行)")
            else:
                detail = r.get("reason") or r["status"]
                print(f"  ✗ {rid}: 期望 hit，实际 {r['status']} — {detail}")
                failures.append(f"{rid} 未命中（{r['status']}）")

    # 3) 软断言
    if soft:
        print(f"\n【软断言】{len(soft)} 条尽力命中：")
        for rid in soft:
            r = rules.get(rid)
            if r is None:
                print(f"  - {rid}: 规则不存在")
            elif r["status"] == "hit":
                print(f"  ✓ {rid}  ({r['severity']}, {r['row_count']} 行)")
            else:
                detail = r.get("reason") or r["status"]
                print(f"  ! {rid}: 未命中（{r['status']}）— {detail}")
                warnings.append(rid)

    # 4) 覆盖面提示：把跳过项摊开，避免"没报错 = 没问题"的错觉
    skipped = [r for r in rules.values() if r["status"] == "skipped"]
    if skipped:
        print(f"\n【未覆盖】{len(skipped)} 条被跳过（这不等于「没问题」）：")
        seen: dict[str, int] = {}
        for r in skipped:
            key = (r.get("reason") or "").split("（")[0][:60]
            seen[key] = seen.get(key, 0) + 1
        for reason, n in sorted(seen.items(), key=lambda kv: -kv[1]):
            print(f"  - {n:2d} 条: {reason}")

    print("\n" + "=" * 78)
    if failures:
        print(f"结论：失败（{len(failures)} 项硬性不通过）")
        for f in failures:
            print(f"  ✗ {f}")
        return 1
    print(f"结论：通过（硬断言 {len(hard)} 条全部命中，0 条执行错误）")
    if warnings:
        print(f"      软断言未命中 {len(warnings)} 条（不失败）：{', '.join(warnings)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
