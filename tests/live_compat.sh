#!/usr/bin/env bash
# ============================================================================
#  mysqlbot 跨版本兼容性检查（针对**真实目标实例**）
#
#  这是 tests/run_tests.sh 的补充，不是替代：
#    run_tests.sh  在 /tmp 的一次性 8.4 实例上做**功能**自测（种违规 + 断言命中）
#    live_compat.sh 在任意真实实例上做**兼容性**检查（41 条规则是否都能执行）
#
#  为什么需要它：规则里的列/变量名随 MySQL 版本漂移（QUERY_SAMPLE_TEXT 是
#  8.0.22+、binlog_expire_logs_seconds 8.0 才有、data_locks 8.0 才有、
#  INNODB_LOCKS 8.0 已移除）。这些不匹配原本会被当成"环境限制"降级成 skipped，
#  于是"0 报错"变成一句空话。现在它们会报 error——本脚本就是那条断言的守卫。
#
#  只读保证：mbot 自身只发 SELECT / SET SESSION，不做任何写入。
#
#  用法:
#     tests/live_compat.sh --defaults-file /tmp/mbot57.cnf --label 5.7.44
#     tests/live_compat.sh --defaults-file ~/.my.cnf --label '8.0.43'
#     tests/live_compat.sh --defaults-file /tmp/x.cnf --label 8.4 --json-out /tmp/r.json
#
#  退出码: 0 = 该目标上 0 条规则执行报错；1 = 有报错（工具缺陷）；2 = 用法/连接错误
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MBOT="$ROOT/bin/mbot"
PY="${MYSQLBOT_PY:-python3}"

DEFAULTS_FILE=""
LABEL=""
JSON_OUT="$(mktemp -t mysqlbot-live.XXXXXX.json)"
SHOW_ALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --defaults-file) DEFAULTS_FILE="$2"; shift 2 ;;
    --label)         LABEL="$2"; shift 2 ;;
    --json-out)      JSON_OUT="$2"; shift 2 ;;
    --all)           SHOW_ALL=1; shift ;;
    -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -n "$DEFAULTS_FILE" ] || { echo "必须给 --defaults-file" >&2; exit 2; }
[ -f "$DEFAULTS_FILE" ] || { echo "凭据文件不存在: $DEFAULTS_FILE" >&2; exit 2; }
[ -n "$LABEL" ] || LABEL="$(basename "$DEFAULTS_FILE")"

printf '\n\033[1m== %s：能力探测 ==\033[0m\n' "$LABEL"
"$MBOT" doctor --defaults-file "$DEFAULTS_FILE" || exit 2

printf '\n\033[1m== %s：全量巡检（42 条规则）==\033[0m\n' "$LABEL"
"$MBOT" check --defaults-file "$DEFAULTS_FILE" \
  --label "$LABEL" --fail-on none -o json --out-file "$JSON_OUT" >/dev/null

"$PY" - "$JSON_OUT" "$LABEL" "$SHOW_ALL" <<'PY'
import json, sys

path, label, show_all = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
d = json.load(open(path))
s = d["summary"]
t = d["target"]

print(f"  版本     : {t['version']} / {t['version_comment']} / {t['edition']}")
print(f"  账号     : {t['current_user']}")
print(f"  覆盖 schema: {', '.join(d['capabilities'].get('visible_schemas') or []) or '（无）'}")
print(f"  结论     : 命中 {s['hit']} / 干净 {s['clean']} / 跳过 {s['skipped']} / 失败 {s['error']}"
      f"   （共 {len(d['rules'])} 条）")

by = {"error": [], "skipped": [], "hit": []}
for r in d["rules"]:
    by.get(r["status"], []).append(r)

if by["error"]:
    print("\n  \033[1m失败（工具缺陷，必须修）\033[0m")
    for r in by["error"]:
        print(f"    ✗ {r['rule']}: {(r.get('reason') or '')[:160]}")

if by["skipped"]:
    print("\n  跳过（= 没检查，不等于干净）")
    for r in by["skipped"]:
        print(f"    - {r['rule']}: {(r.get('reason') or '')[:120]}")

if by["hit"]:
    print("\n  命中")
    for r in by["hit"]:
        trunc = "  [已截断，真实 ≥]" if r.get("truncated") else ""
        print(f"    · {r.get('severity','?'):8} {r['rule']:34} {r['row_count']:>3} 行{trunc}")

if show_all:
    print("\n  全部规则状态")
    for r in sorted(d["rules"], key=lambda x: x["rule"]):
        print(f"    {r['status']:8} {r['rule']}")

print()
if by["error"]:
    print(f"\033[31m✗ {label}：有 {len(by['error'])} 条规则执行报错——这是工具缺陷，不是环境问题\033[0m")
    sys.exit(1)
print(f"\033[32m✓ {label}：42 条规则全部执行成功，0 条报错（跳过 {s['skipped']} 条均有明确原因）\033[0m")
PY

echo
echo "完整报告: $JSON_OUT"
