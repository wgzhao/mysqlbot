#!/usr/bin/env bash
# ============================================================================
#  锁场景生成器：起三个后台 mysql 会话，租出三类"看不到但很致命"的状态。
#
#   会话 A：BEGIN + UPDATE 一行，然后**在客户端侧空转**（不在 SQL 里 sleep，
#           否则 TRX_QUERY 非空，就不是"空闲事务"了）
#           → 命中 idle_in_transaction（需空闲 >= 60s）
#           → 同时持有该行的行锁与该表的元数据锁
#   会话 B：UPDATE 同一行 → 被行锁阻塞
#           → 命中 blocking_chains（需等待 >= 10s）
#   会话 C：ALTER TABLE → 等元数据锁
#           → 命中 metadata_lock_wait
#
#  注意：A/B/C 用 root 连接，而 mbot 用 mbot_reader 连接。idle_in_transaction
#  与 metadata_lock_wait 会过滤掉"自己账号"的会话，所以两边必须不是同一个用户。
#
#  用法: 50_locks.sh <mysql_bin> <socket> [保持秒数]
# ============================================================================
set -euo pipefail

MYSQL_BIN="${1:?需要 mysql 客户端路径}"
SOCK="${2:?需要 socket 路径}"
HOLD="${3:-100}"
DB="mysqlbot_test"
PIDFILE="${MYSQLBOT_TEST_HOLD_PIDFILE:-/tmp/mysqlbot-test/locks.pid}"

: > "$PIDFILE"

MY() { "$MYSQL_BIN" --socket="$SOCK" -uroot --batch >/dev/null 2>&1; }

# --- 会话 A：空闲事务 + 持锁 -------------------------------------------------
{
  printf 'USE %s;\nBEGIN;\nUPDATE lock_target SET v = v + 1 WHERE id = 1;\n' "$DB"
  sleep "$HOLD"
  printf 'ROLLBACK;\n'
} | MY &
A_PID=$!
echo "$A_PID" >> "$PIDFILE"

sleep 3

# --- 会话 B：等行锁 ----------------------------------------------------------
{
  printf 'USE %s;\nSET SESSION innodb_lock_wait_timeout = %s;\nUPDATE lock_target SET v = v + 1 WHERE id = 1;\n' "$DB" "$((HOLD + 60))"
  sleep "$HOLD"
} | MY &
B_PID=$!
echo "$B_PID" >> "$PIDFILE"

sleep 2

# --- 会话 C：等元数据锁 ------------------------------------------------------
{
  printf 'USE %s;\nSET SESSION lock_wait_timeout = %s;\nALTER TABLE lock_target ADD COLUMN tmp_col INT;\n' "$DB" "$((HOLD + 60))"
  sleep "$HOLD"
} | MY &
C_PID=$!
echo "$C_PID" >> "$PIDFILE"

echo "已起持锁会话 A/B/C，保持 ${HOLD}s（pid ${A_PID} ${B_PID} ${C_PID}，记录于 ${PIDFILE}）"
