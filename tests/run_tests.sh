#!/usr/bin/env bash
# ============================================================================
#  mysqlbot 规则库自测
#
#  做三件事：
#    1. 向一次性实例里种下"确定会违规"的库、表、配置与锁场景
#    2. 用**只读账号**跑一轮完整巡检
#    3. 断言：没有规则执行报错 + 植入的违规都被抓到
#
#  ============================ 安全闸 ============================
#  本脚本会 DROP DATABASE 并修改 GLOBAL 配置。
#  **只允许指向 /tmp 下的一次性实例**（tests/local_instance.sh 起的那个）。
#  想指向别处必须显式设 MYSQLBOT_TEST_ALLOW_ANY_TARGET=i-know-what-im-doing
#  ================================================================
#
#  用法:
#     tests/local_instance.sh start
#     tests/run_tests.sh                      # 默认连 /tmp/mysqlbot-test/mysql.sock
#     tests/run_tests.sh --socket /tmp/x/mysql.sock
#     tests/local_instance.sh stop
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS="$ROOT/tests"
MBOT="$ROOT/bin/mbot"

HOLD_SECONDS="${MYSQLBOT_TEST_HOLD:-100}"   # 持锁会话保持时长（idle_in_transaction 需 > 60s）
SETTLE_SECONDS="${MYSQLBOT_TEST_SETTLE:-70}" # 等锁稳定后再巡检
STORM_SCANS="${MYSQLBOT_TEST_SCANS:-150}"
STORM_TMPQ="${MYSQLBOT_TEST_TMPQ:-1200}"

SOCK="${MYSQLBOT_TEST_SOCKET:-${MYSQLBOT_TEST_HOME:-/tmp/mysqlbot-test}/mysql.sock}"
READER_USER="mbot_reader"
READER_PASS="mbot_test_pw"
REPORT="$(mktemp -t mysqlbot-report.XXXXXX.json)"

while [ $# -gt 0 ]; do
  case "$1" in
    --socket) SOCK="$2"; shift 2 ;;
    --hold)   HOLD_SECONDS="$2"; shift 2 ;;
    --settle) SETTLE_SECONDS="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

# ---------------------------- 安全闸 ----------------------------
if [ "${MYSQLBOT_TEST_ALLOW_ANY_TARGET:-}" != "i-know-what-im-doing" ]; then
  case "$SOCK" in
    /tmp/*) : ;;
    *)
      cat >&2 <<'EOF'
拒绝执行：自测会 DROP DATABASE 并修改 GLOBAL 配置，只允许作用在 /tmp 下的一次性实例。

  正确用法：
      tests/local_instance.sh start
      tests/run_tests.sh

  如果你确实要在别处跑（例如容器里的测试实例），显式声明风险：
      MYSQLBOT_TEST_ALLOW_ANY_TARGET=i-know-what-im-doing tests/run_tests.sh --socket <path>
EOF
      exit 2
      ;;
  esac
fi

# ---------------------------- 找 mysql 客户端 ----------------------------
find_mysql() {
  for c in "$(command -v mysql 2>/dev/null || true)" \
           /opt/homebrew/opt/mysql/bin/mysql \
           /opt/homebrew/opt/mysql-client/bin/mysql \
           /usr/local/bin/mysql /usr/bin/mysql; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return; }
  done
  ls -d /opt/homebrew/Cellar/mysql*/*/bin/mysql 2>/dev/null | sort -V | tail -1
}
MYSQL="$(find_mysql)"
[ -z "$MYSQL" ] && { echo "找不到 mysql 客户端" >&2; exit 1; }

[ -S "$SOCK" ] || { echo "socket $SOCK 不存在，请先 tests/local_instance.sh start" >&2; exit 1; }

AS_ROOT=("$MYSQL" --socket="$SOCK" -uroot --batch)

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

PIDFILE="${MYSQLBOT_TEST_HOLD_PIDFILE:-${MYSQLBOT_TEST_HOME:-/tmp/mysqlbot-test}/locks.pid}"
export MYSQLBOT_TEST_HOLD_PIDFILE="$PIDFILE"

cleanup() {
  # 只按 PID 回收持锁会话。**不要**用 pkill -f "$SOCK" ——
  # mysqld 自己的命令行里就含 "--socket=$SOCK"，那样会把测试实例一起杀掉。
  if [ -f "$PIDFILE" ]; then
    while read -r pid; do
      [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1 || true
    done < "$PIDFILE"
    rm -f "$PIDFILE"
  fi
}
trap cleanup EXIT

step "0/6 连通性"
"${AS_ROOT[@]}" -e "SELECT VERSION() AS version, @@innodb_buffer_pool_size AS bp;"

step "1/6 植入结构违规（10_schema.sql）"
"${AS_ROOT[@]}" < "$TESTS/fixtures/10_schema.sql"

step "2/6 灌数据（20_load.sql）"
"${AS_ROOT[@]}" < "$TESTS/fixtures/20_load.sql"

step "3/6 建立只读巡检账号（sql/readonly_account.sql + 结构类所需的 schema 读权限）"
# 先删掉旧账号，保证每次都是干净的最小权限起点（否则上一轮的残留授权会让
# "缺少能力位则跳过"这类断言失效）
"${AS_ROOT[@]}" -e "DROP USER IF EXISTS '${READER_USER}'@'%';"
sed "s/CHANGE_ME_STRONG_PASSWORD/${READER_PASS}/" "$ROOT/sql/readonly_account.sql" | "${AS_ROOT[@]}" >/dev/null
# 结构类规则（无主键表、冗余索引、超大表）需要看到业务 schema 的元信息，
# 而 information_schema 是按权限过滤的 —— 这里按文档里的 B 档授权。
"${AS_ROOT[@]}" -e "GRANT SELECT ON *.* TO '${READER_USER}'@'%'; FLUSH PRIVILEGES;"

step "4/6 把实例配置调成有问题（30_settings.sql）"
"${AS_ROOT[@]}" < "$TESTS/fixtures/30_settings.sql"

step "5/6 语句风暴（40_storm.sh）"
bash "$TESTS/fixtures/40_storm.sh" "$STORM_SCANS" "$STORM_TMPQ" | "${AS_ROOT[@]}" >/dev/null
echo "已灌入 $((STORM_SCANS + STORM_TMPQ + 6)) 条语句"

step "6/6 起持锁会话并等待稳定（${HOLD_SECONDS}s 保持 / ${SETTLE_SECONDS}s 后巡检）"
bash "$TESTS/fixtures/50_locks.sh" "$MYSQL" "$SOCK" "$HOLD_SECONDS"

echo "等待 ${SETTLE_SECONDS}s 让锁等待与空闲事务积累到门禁之上…"
sleep "$SETTLE_SECONDS"

printf '\n\033[1m== 巡检（以只读账号 %s 执行）==\033[0m\n' "$READER_USER"
"$MBOT" check \
  --socket="$SOCK" \
  -u "$READER_USER" -p "$READER_PASS" \
  --label "mysqlbot-selftest" \
  --ignore-min-uptime \
  --fail-on none \
  -o json --out-file "$REPORT"

cleanup
trap - EXIT

printf '\n\033[1m== 断言 ==\033[0m\n'
set +e
python3 "$TESTS/assert_report.py" \
  "$REPORT" \
  "$TESTS/expected_hits.txt" \
  "$TESTS/expected_hits_soft.txt"
RC=$?
set -e

echo
echo "完整报告已保留在: $REPORT"
exit $RC
