#!/usr/bin/env bash
# ============================================================================
#  起一个**一次性**的本地 MySQL 实例，专供 mysqlbot 自测。
#  只用于开发机。生产库请不要用这个脚本动。
#
#    tests/local_instance.sh start     初始化并启动
#    tests/local_instance.sh stop      停止并删除数据目录
#    tests/local_instance.sh status    查看状态
#
#  环境变量：
#    MYSQLBOT_TEST_HOME   数据目录（默认 /tmp/mysqlbot-test）
#    MYSQLBOT_TEST_PORT   端口（默认 13306）
#    MYSQLD_BIN           mysqld 路径（默认自动探测）
# ============================================================================
set -euo pipefail

HOME_DIR="${MYSQLBOT_TEST_HOME:-/tmp/mysqlbot-test}"
PORT="${MYSQLBOT_TEST_PORT:-13306}"
DATADIR="$HOME_DIR/data"
SOCK="$HOME_DIR/mysql.sock"
LOG="$HOME_DIR/mysqld.log"
PIDF="$HOME_DIR/mysqld.pid"

find_mysqld() {
  if [ -n "${MYSQLD_BIN:-}" ]; then echo "$MYSQLD_BIN"; return; fi
  for c in "$(command -v mysqld 2>/dev/null || true)" \
           /opt/homebrew/opt/mysql/bin/mysqld \
           /usr/local/opt/mysql/bin/mysqld \
           /usr/sbin/mysqld; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return; }
  done
  local found
  found="$(ls -d /opt/homebrew/Cellar/mysql*/*/bin/mysqld 2>/dev/null | sort -V | tail -1 || true)"
  [ -n "$found" ] && { echo "$found"; return; }
  echo "" 
}

MYSQLD="$(find_mysqld)"
[ -z "$MYSQLD" ] && { echo "找不到 mysqld，请设置 MYSQLD_BIN" >&2; exit 1; }
BASEDIR="$(cd "$(dirname "$MYSQLD")/.." && pwd)"
MYSQL="$BASEDIR/bin/mysql"
MYSQLADMIN="$BASEDIR/bin/mysqladmin"

cmd_start() {
  mkdir -p "$DATADIR"
  if [ ! -d "$DATADIR/mysql" ]; then
    echo "== 初始化数据目录 =="
    "$MYSQLD" --initialize-insecure --basedir="$BASEDIR" --datadir="$DATADIR" --log-error="$LOG"
  fi
  echo "== 启动（socket ${SOCK}, port ${PORT}）=="
  # 关键测试参数：
  #   innodb-buffer-pool-size=32M  让工作集远大于缓冲池，以便复现命中率类规则
  #   performance-schema-consumer-* 打开语句/等待采集
  #   不加 --skip-log-bin，保持 binlog ON 以便验证 binlog 类规则
  nohup "$MYSQLD" \
    --basedir="$BASEDIR" \
    --datadir="$DATADIR" \
    --socket="$SOCK" \
    --port="$PORT" \
    --bind-address=127.0.0.1 \
    --pid-file="$PIDF" \
    --log-error="$LOG" \
    --mysqlx=OFF \
    --performance-schema=ON \
    --performance-schema-consumer-events-statements-current=ON \
    --performance-schema-consumer-events-statements-history=ON \
    --performance-schema-consumer-events-waits-current=ON \
    --performance-schema-instrument='wait/lock/metadata/sql/mdl=ON' \
    --innodb-buffer-pool-size=32M \
    --max-connections=200 \
    --slow-query-log=OFF \
    >/dev/null 2>&1 &
  for _ in $(seq 1 60); do
    if "$MYSQLADMIN" --socket="$SOCK" -uroot ping >/dev/null 2>&1; then
      echo "就绪：$SOCK"
      return 0
    fi
    sleep 0.5
  done
  echo "启动超时，日志尾部：" >&2
  tail -20 "$LOG" >&2
  exit 1
}

cmd_stop() {
  if [ -S "$SOCK" ]; then
    "$MYSQLADMIN" --socket="$SOCK" -uroot shutdown >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do [ -S "$SOCK" ] || break; sleep 0.5; done
  fi
  pkill -f "$DATADIR" >/dev/null 2>&1 || true
  rm -rf "$HOME_DIR"
  echo "已停止并清除 $HOME_DIR"
}

cmd_status() {
  if [ -S "$SOCK" ] && "$MYSQLADMIN" --socket="$SOCK" -uroot ping >/dev/null 2>&1; then
    echo "运行中：$SOCK"
    "$MYSQL" --socket="$SOCK" -uroot -N -e "SELECT CONCAT('MySQL ', VERSION(), ' / uptime ', ROUND(VARIABLE_VALUE/60,1), ' 分钟') FROM performance_schema.global_status WHERE VARIABLE_NAME='Uptime';"
  else
    echo "未运行"
    return 1
  fi
}

case "${1:-start}" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  *) echo "用法: $0 {start|stop|status}" >&2; exit 2 ;;
esac
