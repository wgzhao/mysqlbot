#!/usr/bin/env bash
# ============================================================================
#  mysqlbot 跨版本兼容性检查（针对**真实目标实例**）
#
#  这是 tests/run_tests.sh 的补充，不是替代：
#    run_tests.sh  在 /tmp 的一次性实例上做**功能**自测（种违规 + 断言命中）
#    live_compat.sh 在任意真实实例上做**兼容性**检查（42 条规则是否都能执行）
#
#  为什么需要它：规则里的列/变量名随 MySQL 版本漂移（QUERY_SAMPLE_TEXT 是
#  8.0.22+、binlog_expire_logs_seconds 8.0 才有、data_locks 8.0 才有、
#  INNODB_LOCKS 8.0 已移除）。这些不匹配原本会被当成"环境限制"降级成 skipped，
#  于是"0 报错"变成一句空话。现在它们会报 error——本脚本就是那条断言的守卫。
#
#  它跑两步：
#    ① mbot doctor —— 顺带把 signals.py 的 21 个**变量**信号与实例核对一遍
#       （软查表缺变量是"哑失败"，只有这一步能看见）
#    ② 全量巡检 + 把离线推演与实测结果对账（对账靠结构化 skip_kind，不匹配中文）
#
#  只读保证：mbot 自身只发 SELECT / SET SESSION，不做任何写入。
#
#  用法:
#     tests/live_compat.sh --defaults-file /tmp/mbot57.cnf --label 5.7.44
#     tests/live_compat.sh --defaults-file ~/.my.cnf --label '8.0.43'
#     tests/live_compat.sh --defaults-file /tmp/x.cnf --label 8.4 --json-out /tmp/r.json
#     # 本机一次性实例：写 socket=<数据目录>/mysql.sock + user=root 即可
#
#  退出码: 0 = 该目标上 0 条规则执行报错、且推演对账吻合；1 = 有报错或对账不一致
#          （工具缺陷）；2 = 用法/连接错误，或 doctor 自检失败（含信号登记表过期）
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

MAIN_RC=0
XCHECK_RC=0
"$PY" - "$JSON_OUT" "$LABEL" "$SHOW_ALL" <<'PY' || MAIN_RC=$?
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

printf '\n\033[1m== %s：版本推演对账\033[0m\n' "$LABEL"
"$PY" - "$JSON_OUT" "$ROOT" <<'PY' || XCHECK_RC=$?
# 把 mbot/signals.py 的**离线预测**与这台机器的**实测结果**对上。
# 这一步是整条链路的收口：登记表是人写的、会过期，真实实例才是权威。
# 一旦两者不一致，说明目标版本上有规则引用了没登记的版本敏感信号——
# 那正是过去只能靠人肉发现的那些"静默算错"，现在由脚本逼它浮出来。
import json, pathlib, re, sys

sys.path.insert(0, sys.argv[2])
from mbot import signals as sg          # noqa: E402
from mbot.rule import load_rules        # noqa: E402

d = json.load(open(sys.argv[1]))
raw = d["target"]["version"]
m = re.match(r"(\d+\.\d+(?:\.\d+)?)", raw)
ver = m.group(1) if m else raw

rules, _ = load_rules(pathlib.Path(sys.argv[2]) / "rules")
pred_gate = {r.id for r in rules if sg.verdict_for(r, ver).status == sg.GATED}
pred_risk = {r.id for r in rules if sg.verdict_for(r, ver).status == sg.AT_RISK}

# 用结构化的 skip_kind 分类，**不要**去匹配中文 reason：
# "执行被拒（Table 'x' doesn't exist）"是版本问题，不是权限问题，
# 靠字符串匹配会把它归错桶，于是一个假的「✓ 一致」就出来了。
act_gate, act_soft, act_missing, act_err = set(), set(), set(), set()
for r in d["rules"]:
    if r["status"] == "error":
        act_err.add(r["rule"])
    elif r["status"] == "skipped":
        k = r.get("skip_kind") or "other"
        if k == "version":
            act_gate.add(r["rule"])
        elif k == "missing_object":
            act_missing.add(r["rule"])
        else:
            act_soft.add(r["rule"])

print(f"  目标版本 : {raw}  （推演按 {ver}）")
print(f"  门禁跳过 : 预测 {len(pred_gate):>2} / 实测 {len(act_gate):>2}")
print(f"  版本风险 : 预测 {len(pred_risk):>2} / 实测失败 {len(act_err):>2}")
print(f"  软跳过   : 实测 {len(act_soft):>2}（权限/能力位/时长，离线不可知）")
if act_missing:
    print(f"  缺对象   : 实测 {len(act_missing):>2}（登记表认为能跑，实际对象不存在）")

bad = False
if pred_gate != act_gate:
    bad = True
    print("\n  \033[31m✗ 门禁预测与实测不一致 —— mbot/signals.py 的登记表已过期\033[0m")
    for x in sorted(pred_gate - act_gate):
        print(f"      预测会跳但实际跑了: {x}")
    for x in sorted(act_gate - pred_gate):
        print(f"      实际跳了但未预测到: {x}")
if act_missing:
    bad = True
    print("\n  \033[31m✗ 有规则在目标版本上「对象不存在」\033[0m")
    for x in sorted(act_missing):
        print(f"      {x}  ← 登记表没有这个信号，请补进 mbot/signals.py 的 _ORDER"
              "（含它的 since/removed_in）")
if pred_risk != act_err:
    bad = True
    print("\n  \033[31m✗ 版本风险预测与实测失败不一致\033[0m")
    for x in sorted(pred_risk - act_err):
        print(f"      预测有风险但实际成功: {x}")
    for x in sorted(act_err - pred_risk):
        print(f"      实际失败但未预测到: {x}  ← 引用了未登记的版本敏感信号，请补登记")
if bad:
    sys.exit(1)
print("\n  \033[32m✓ 离线推演与实测完全吻合\033[0m")
PY

echo
if [ "$MAIN_RC" -ne 0 ] || [ "$XCHECK_RC" -ne 0 ]; then
  echo "完整报告: $JSON_OUT"
  exit 1
fi
echo "完整报告: $JSON_OUT"
