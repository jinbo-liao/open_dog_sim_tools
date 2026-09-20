#!/usr/bin/env bash
# batch_test.sh —— 批量测试：多个场景 × 多种步态，汇总摔倒统计
#
# 用法：
#   ./batch_test.sh                    # 默认测 obstacles 场景，3 种步态
#   ./batch_test.sh obstacles          # 指定场景
#   DURATION=120 ./batch_test.sh       # 每轮 120 秒
#
# 前提：Gazebo + 控制器已在跑（用 run_scene.sh 另开终端启动）。
#       本脚本假设 ROS master 已存在，只负责发指令 + 收集统计。

set -uo pipefail

SCENE="${1:-obstacles}"
DURATION="${DURATION:-60}"
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "${_HERE}/simenv.sh"
OUTDIR="${OUTDIR:-${WS_ROOT}/sim/batch_${SCENE}_$(date +%m%d_%H%M)}"

# 要测的组合：步态:速度
COMBOS=(
  "static_walk:0.3"
  "trot:0.4"
  "trot:0.6"
  "flying_trot:0.6"
  "dynamic_walk:0.4"
)

mkdir -p "${OUTDIR}"
echo "======================================================"
echo " 批量测试  场景=${SCENE}  每轮 ${DURATION}s"
echo " 输出目录  ${OUTDIR}"
echo "======================================================"

SUMMARY="${OUTDIR}/summary.csv"
echo "gait,speed,duration,distance,falls,fall_per_min,csv" > "${SUMMARY}"

for combo in "${COMBOS[@]}"; do
  GAIT="${combo%%:*}"
  SPEED="${combo##*:}"
  TAG="${GAIT}_${SPEED}"
  RUNCSV="${OUTDIR}/falls_${TAG}.csv"

  echo
  echo "------------------------------------------------------"
  echo " 测试: 步态=${GAIT}  速度=${SPEED} m/s"
  echo "------------------------------------------------------"

  # 提醒切步态（自动通道需要 gait_bridge.py）
  echo "  [提示] 请在 gait_command 终端确认已切到: ${GAIT}"

  # 跑一轮
  python3 "${TOOLS_DIR}/scripts/auto_run.py" \
      --path random \
      --duration "${DURATION}" \
      --speed "${SPEED}" \
      --gait "${GAIT}" \
      --csv "${RUNCSV}" 2>&1 | tee "${OUTDIR}/run_${TAG}.log"

  # 从 log 里抠出统计数字，写进 summary
  DIST=$(grep -oP '行走距离\s+:\s+\K[0-9.]+' "${OUTDIR}/run_${TAG}.log" | tail -1)
  FALLS=$(grep -oP '摔倒次数\s+:\s+\K[0-9]+' "${OUTDIR}/run_${TAG}.log" | tail -1)
  FPM=$(grep -oP '摔倒频率\s+:\s+\K[0-9.]+' "${OUTDIR}/run_${TAG}.log" | tail -1)
  echo "${GAIT},${SPEED},${DURATION},${DIST:-0},${FALLS:-0},${FPM:-0},${RUNCSV}" >> "${SUMMARY}"

  sleep 3
done

echo
echo "======================================================"
echo " 汇总 (${SUMMARY})"
echo "======================================================"
column -t -s, "${SUMMARY}" 2>/dev/null || cat "${SUMMARY}"
echo
echo "每个组合的详细日志在: ${OUTDIR}/run_*.log"
echo "摔倒明细在:          ${OUTDIR}/falls_*.csv"
