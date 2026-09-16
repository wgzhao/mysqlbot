#!/usr/bin/env bash
# ============================================================================
#  语句风暴生成器：把 SQL 打到 stdout，由 run_tests.sh 一次性 pipe 进 mysql。
#
#  要点：**每条语句的文本必须完全一致**。performance_schema 是按
#  (SCHEMA, DIGEST) 聚合的，如果每次把字面量改掉（比如换个 LIKE 参数），
#  就会散成上千个 COUNT_STAR=1 的 digest，规则里的 COUNT_STAR 门禁永远过不了。
#
#  用法: 40_storm.sh [扫描次数] [临时表次数]
# ============================================================================
set -euo pipefail

SCANS="${1:-150}"   # 全表扫描次数（需 > 100 以过 statement_high_total_latency 的 COUNT_STAR 门禁）
TMPQ="${2:-1200}"   # 内部临时表次数（需 > 1000 以过 tmp_table_disk_spill 门禁）

echo "USE mysqlbot_test;"

# --- 全表扫描：每次扫 20 万行 -----------------------------------------------
#   期望命中 full_table_scan_heavy（SUM_ROWS_EXAMINED 累计数千万）
#   可能命中 statement_high_total_latency（累计耗时超 10 秒）
for _ in $(seq 1 "$SCANS"); do
  echo "SELECT COUNT(*) FROM nopk_big WHERE payload LIKE '%zzz%';"
done

# --- 内部临时表落盘 ----------------------------------------------------------
#   派生表 300 行 x 约 190 字节 ≈ 57KB，超过 tmp_table_size=16K → 落盘
#   期望命中 tmp_table_disk_spill
for _ in $(seq 1 "$TMPQ"); do
  echo "SELECT k, COUNT(*) AS c FROM (SELECT payload AS k FROM nopk_big LIMIT 300) x GROUP BY k;"
done

# --- 大规模排序（sort_buffer_size 已被压到 32K）-----------------------------
#   期望命中 sort_merge_passes
for _ in $(seq 1 6); do
  echo "SELECT payload FROM nopk_big ORDER BY payload LIMIT 1;"
done
