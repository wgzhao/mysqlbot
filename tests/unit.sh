#!/usr/bin/env bash
# ============================================================================
#  mysqlbot 单元测试（不连数据库）
#
#  这一组守的是**"不报错但结论错"**的缺陷 —— 端到端测试抓不到的那一类：
#    test_grants.py    授权解析 / 能力位判定    —— 解析错只会让工具"声称"自己有能力
#    test_classify.py  错误分类 / LIMIT 截断    —— 分类错会让真缺陷伪装成"跳过"
#    test_signals.py   信号登记表 / 版本推演    —— 登记错会让推演给出合理但错误的答案
#
#  与另外两个装置的分工：
#    tests/unit.sh        不连库，纯逻辑，秒级
#    tests/run_tests.sh   本机一次性 8.4 实例，功能自测（种违规 + 断言命中）
#    tests/live_compat.sh 任意真实实例，兼容性检查 + 推演对账
#
#  用法: tests/unit.sh
#  退出码: 0 = 全部通过
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${MYSQLBOT_PY:-python3}"

RC=0
for t in test_grants test_classify test_signals; do
  printf '\n\033[1m════ %s ════\033[0m\n' "$t.py"
  "$PY" "$ROOT/tests/$t.py" || RC=1
done

printf '\n'
if [ "$RC" -eq 0 ]; then
  printf '\033[32m✓ 单元测试全部通过\033[0m\n'
else
  printf '\033[31m✗ 单元测试有失败\033[0m\n'
fi
exit "$RC"
