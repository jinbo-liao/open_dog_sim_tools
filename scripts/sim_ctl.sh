#!/usr/bin/env bash
# ==============================================================================
#  sim_ctl.sh —— 宿主机上的「仿真生命周期」控制器（不需要进容器手工敲命令）
#
#  为什么需要它：
#    你的容器 ros1 是用 `docker run --rm` 起的，**只在仿真运行期间存在**。
#    仿真一退出容器就被自动删掉，所以 `docker exec ros1 ...` 会报
#    "No such container: ros1" —— 那不是坏了，是没在跑。
#
#  用法（全部在宿主机执行）：
#    ./sim_ctl.sh start                # 起仿真（Gazebo + 机器人 + RViz + 控制器）
#    ./sim_ctl.sh start --no-rviz      # 省资源
#    ./sim_ctl.sh status               # 看容器/控制器/位姿
#    ./sim_ctl.sh shell                # 进容器 shell（不打断仿真）
#    ./sim_ctl.sh exec 'rostopic list' # 在容器里跑一条命令
#    ./sim_ctl.sh stop                 # 停掉（删容器）
#
#  它只是包了一层你自己的 ~/open-dog-ros1/run.sh，不重复实现逻辑。
# ==============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${DIR}/container.sh"

RUN_SH="${RUN_SH:-${HOME}/open-dog-ros1/run.sh}"
CNAME="${CNAME:-ros1}"

if [[ ! -f "${RUN_SH}" ]]; then
  echo "[sim_ctl] 找不到 ${RUN_SH}" >&2
  echo "         若你的启动脚本在别处，设: RUN_SH=/path/to/run.sh ./sim_ctl.sh start" >&2
  exit 1
fi

case "${1:-status}" in
  start)
    if container_running; then
      echo "[sim_ctl] 容器 ${CNAME} 已在运行（仿真应该正在跑），不重复启动。"
      echo "          进 shell: ./sim_ctl.sh shell        重启动: ./sim_ctl.sh restart"
      exit 0
    fi
    echo "[sim_ctl] 启动仿真: ${RUN_SH} sim ${*:2}"
    echo "[sim_ctl] 说明：Gazebo/RViz 窗口会出现在你的桌面；"
    echo "          这个脚本会一直占着当前终端（和官方 run.sh 行为一致）。"
    echo
    if [[ "${DETACH:-0}" == "1" ]]; then
      # 后台起，日志落盘，方便自动化
      LOG="${LOG:-${HOME}/ros1_ws/sim/sim_ctl.log}"
      mkdir -p "$(dirname "${LOG}")"
      nohup bash "${RUN_SH}" sim "${@:2}" >"${LOG}" 2>&1 &
      echo "[sim_ctl] 已后台启动，PID=$!，日志: ${LOG}"
      echo "[sim_ctl] 等待容器起来（最多 90 秒）..."
      for _ in $(seq 1 90); do
        container_running && { echo "[sim_ctl] 容器 ${CNAME} 已就绪"; exit 0; }
        sleep 1
      done
      echo "[sim_ctl] 超时：容器仍未就绪，看 ${LOG}" >&2
      exit 1
    else
      exec bash "${RUN_SH}" sim "${@:2}"
    fi
    ;;

  restart)
    bash "${DIR}/sim_ctl.sh" stop >/dev/null 2>&1 || true
    exec bash "${DIR}/sim_ctl.sh" start "${@:2}"
    ;;

  stop)
    if ! container_running; then
      echo "[sim_ctl] 没有在跑的容器 ${CNAME}（本来就已停止）"
      exit 0
    fi
    echo "[sim_ctl] 删除容器 ${CNAME} ..."
    _dk rm -f "${CNAME}" >/dev/null 2>&1 && echo "[sim_ctl] 已停止" || echo "[sim_ctl] 停止失败"
    ;;

  status)
    if ! container_running; then
      echo "[sim_ctl] 容器 ${CNAME}: 未运行"
      echo "          → 用 ./sim_ctl.sh start 启动（容器是 --rm，退出即消失，这是正常的）"
      exit 1
    fi
    echo "[sim_ctl] 容器 ${CNAME}: 运行中"
    container_exec '
      echo "--- 控制器 ---"
      rosservice call /controller_manager/list_controllers 2>/dev/null | grep -E "name:|state:"
      echo "--- 机器人位姿 ---"
      rosservice call /gazebo/get_model_state "model_name: dmgo" 2>/dev/null | grep -E "x:|y:|z:" | head -n 3
    '
    ;;

  shell)
    if ! container_running; then
      echo "[sim_ctl] 容器没在跑 → 先 ./sim_ctl.sh start" >&2
      exit 1
    fi
    exec bash "${RUN_SH}" shell
    ;;

  exec)
    shift
    if ! container_running; then
      echo "[sim_ctl] 容器没在跑 → 先 ./sim_ctl.sh start" >&2
      exit 1
    fi
    container_exec "$*"
    ;;

  -h|--help|*)
    sed -n '2,25p' "$0" | sed 's/^# \?//'
    ;;
esac
