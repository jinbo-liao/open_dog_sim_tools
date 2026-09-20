#!/usr/bin/env bash
# sweep.sh —— 一键跑一批场景，自动起 Gazebo / 控制器 / 统计，最后出对比表
#
# 这是"多做测试场景"的主入口。它会：
#   1. 批量生成（如需）一批场景 .world
#   2. 逐个场景：重启 Gazebo -> 起控制器 -> auto_run.py 跑一段 -> 记摔倒统计
#   3. 汇总成 CSV + 终端表格，方便看"哪个地形最容易摔"
#
# 用法：
#   ./sweep.sh                                  # 跑内置的 4 个场景
#   ./sweep.sh obstacles stairs rough mixed     # 指定场景
#   ./sweep.sh --dir /tmp/genscenes             # 跑一个目录下所有 .world
#   DURATION=90 GAIT=trot ./sweep.sh --dir ...  # 改时长/步态
#
# 前置：
#   必须在容器内、source 好 ROS 环境、有 DISPLAY（Gazebo GUI）。
#   如果没显示器，加 HEADLESS=1 用 gui:=false 跑（RViz 也关）。

set -uo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "${_HERE}/simenv.sh"

WS_SETUP="${WS_SETUP:-${WS_ROOT}/devel/setup.bash}"
export ROBOT_TYPE="${ROBOT_TYPE:-dmgo}"

DURATION="${DURATION:-60}"
GAIT="${GAIT:-trot}"
SPEED="${SPEED:-0.4}"
PATHMODE="${PATHMODE:-random}"
HEADLESS="${HEADLESS:-0}"
STARTUP_WAIT="${STARTUP_WAIT:-25}"
OUTDIR="${OUTDIR:-${WS_ROOT}/sim/sweep_$(date +%m%d_%H%M)}"

# ---------- 解析参数 ----------
SCENES=()
DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --out) OUTDIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) SCENES+=("$1"); shift ;;
  esac
done

mkdir -p "${OUTDIR}/logs"

# ---------- 环境 ----------
ROS_DISTRO_LOCAL="${ROS_DISTRO_LOCAL:-noetic}"
if [[ -f "/opt/ros/${ROS_DISTRO_LOCAL}/setup.bash" ]]; then
  # shellcheck disable=SC1090
  source "/opt/ros/${ROS_DISTRO_LOCAL}/setup.bash"
else
  echo "[sweep] 警告: 找不到 /opt/ros/${ROS_DISTRO_LOCAL}/setup.bash" >&2
  echo "        容器里通常是 noetic；若不同请设 ROS_DISTRO_LOCAL=xxx" >&2
fi
if [[ -f "${WS_SETUP}" ]]; then
  # shellcheck disable=SC1090
  source "${WS_SETUP}"
else
  echo "[sweep] 警告: 找不到 ${WS_SETUP}，设 WS_SETUP=... 指定"
fi

# ---------- 收集要跑的场景 ----------
TARGETS=()
if [[ -n "${DIR}" ]]; then
  while IFS= read -r f; do TARGETS+=("$f"); done < <(ls "${DIR}"/*.world 2>/dev/null | sort)
else
  [[ ${#SCENES[@]} -eq 0 ]] && SCENES=(empty obstacles stairs rough)
  for s in "${SCENES[@]}"; do
    if [[ -f "${s}" ]]; then
      TARGETS+=("${s}")
    else
      TARGETS+=("${TOOLS_DIR}/worlds/${s}.world")
    fi
  done
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "[sweep] 没找到任何场景"
  exit 1
fi

echo "======================================================"
echo " 场景扫描测试"
echo " 场景数    : ${#TARGETS[@]}"
echo " 每轮时长  : ${DURATION}s"
echo " 步态/速度 : ${GAIT} / ${SPEED} m/s"
echo " 路径模式  : ${PATHMODE}"
echo " 输出目录  : ${OUTDIR}"
echo "======================================================"

SUMMARY="${OUTDIR}/sweep_summary.csv"
echo "scene,duration,distance,falls,fall_per_min,max_tilt_deg,min_z,csv,log" > "${SUMMARY}"

# ---------- 工具函数 ----------
kill_all() {
  # 安静地清掉上一轮的进程
  pkill -f "roslaunch.*scene.launch" 2>/dev/null || true
  pkill -f "roslaunch.*load_controller" 2>/dev/null || true
  pkill -f gzserver 2>/dev/null || true
  pkill -f gzclient 2>/dev/null || true
  pkill -f "robot_state_publisher" 2>/dev/null || true
  sleep 3
  pkill -9 -f gzserver 2>/dev/null || true
  pkill -9 -f gzclient 2>/dev/null || true
  sleep 2
}

wait_for_topic() {
  # wait_for_topic <topic> <秒>
  local topic="$1" timeout="${2:-40}"
  for _ in $(seq 1 "${timeout}"); do
    if rostopic list 2>/dev/null | grep -q "^${topic}$"; then return 0; fi
    sleep 1
  done
  return 1
}

# 确保 Ctrl-C 时不留残进程
trap 'echo; echo "[sweep] 中断，清理进程..."; kill_all; exit 130' INT TERM

IDX=0
for WORLD in "${TARGETS[@]}"; do
  IDX=$((IDX + 1))
  NAME="$(basename "${WORLD}" .world)"
  RUNCSV="${OUTDIR}/falls_${NAME}.csv"
  RUNLOG="${OUTDIR}/logs/${NAME}.log"

  echo
  echo "======================================================"
  echo " [${IDX}/${#TARGETS[@]}] 场景: ${NAME}"
  echo "   world: ${WORLD}"
  echo "======================================================"

  kill_all

  # ---- 起 Gazebo（用工具包自带 launch，world_name 走参数）----
  GUI_ARG="gui:=true"
  HEADLESS_ARG=""
  if [[ "${HEADLESS}" == "1" ]]; then
    GUI_ARG="gui:=false"
  fi
  roslaunch --wait "${TOOLS_DIR}/launch/scene.launch" \
    world_name:="${WORLD}" \
    rviz:="$( [[ "${HEADLESS}" == "1" ]] && echo false || echo true )" \
    "${GUI_ARG}" > "${OUTDIR}/logs/${NAME}_gazebo.log" 2>&1 &

  echo "[sweep] 等待 Gazebo /clock ..."
  if ! wait_for_topic /clock 60; then
    echo "[sweep] Gazebo 没起来，跳过该场景（日志: ${OUTDIR}/logs/${NAME}_gazebo.log）"
    echo "${NAME},0,0,0,0,0,0,,${RUNLOG}" >> "${SUMMARY}"
    continue
  fi
  sleep 5

  # ---- 起控制器 ----
  roslaunch legged_controllers load_controller.launch cheater:=false \
    > "${OUTDIR}/logs/${NAME}_ctrl.log" 2>&1 &
  echo "[sweep] 等待控制器加载 ..."
  # 等控制器真正就绪：等 /ground_truth/state 出现（它由机器人插件发布）
  if ! wait_for_topic /ground_truth/state 60; then
    echo "[sweep] 没等到 /ground_truth/state，可能 spawn 失败"
    echo "         检查 ${OUTDIR}/logs/${NAME}_gazebo.log 和 ${NAME}_ctrl.log"
    kill_all
    echo "${NAME},0,0,0,0,0,0,,${RUNLOG}" >> "${SUMMARY}"
    continue
  fi

  # 切换控制器到 legged_controller
  rosservice call /controller_manager/switch_controller \
    "start_controllers: ['controllers/legged_controller']
stop_controllers: ['']
strictness: 0
start_asap: false
timeout: 0.0" > "${OUTDIR}/logs/${NAME}_switch.log" 2>&1 || true

  sleep 3

  # ---- 跑一段并统计 ----
  set +e
  python3 "${TOOLS_DIR}/scripts/auto_run.py" \
      --path "${PATHMODE}" \
      --duration "${DURATION}" \
      --speed "${SPEED}" \
      --gait "${GAIT}" \
      --csv "${RUNCSV}" 2>&1 | tee "${RUNLOG}"
  set -e

  DIST=$(grep -oP '行走距离\s*:\s*\K[0-9.]+' "${RUNLOG}" | tail -1)
  FALLS=$(grep -oP '摔倒次数\s*:\s*\K[0-9]+' "${RUNLOG}" | tail -1)
  FPM=$(grep -oP '摔倒频率\s*:\s*\K[0-9.]+' "${RUNLOG}" | tail -1)
  TILT=$(grep -oP '最大倾角\s*:\s*\K[0-9.]+' "${RUNLOG}" | tail -1)
  MINZ=$(grep -oP '最低高度\s*:\s*\K[0-9.]+' "${RUNLOG}" | tail -1)

  echo "${NAME},${DURATION},${DIST:-0},${FALLS:-0},${FPM:-0},${TILT:-0},${MINZ:-0},${RUNCSV},${RUNLOG}" \
    >> "${SUMMARY}"

  kill_all
done

trap - INT TERM

echo
echo "======================================================"
echo " 汇总结果"
echo "======================================================"
if command -v column >/dev/null 2>&1; then
  column -t -s, "${SUMMARY}"
else
  cat "${SUMMARY}"
fi
echo
echo "CSV:  ${SUMMARY}"
echo "日志: ${OUTDIR}/logs/"
echo
echo "按摔倒次数排序（最差的在前）:"
echo "  sort -t, -k4 -nr ${SUMMARY} | head"
