#!/usr/bin/env bash
# ==============================================================================
#  container.sh —— 统一的「宿主机 <-> 容器」桥接（被 run_scene.sh / sweep.sh 复用）
#
#  你的环境（已实测）：
#    容器名   : ros1                （--rm，只在仿真运行期间存在！）
#    镜像     : ros1-noetic-ocs2:latest
#    工作区   : ~/ros1_ws  <=>  /home/<user>/ros1_ws
#    启动方式 : bash ~/open-dog-ros1/run.sh          （= ros1.sh sim）
#    进容器   : bash ~/open-dog-ros1/run.sh          （sim 在跑时会自动 exec 进去）
#    停止     : bash ~/open-dog-ros1/run.sh stop
#
#  本文件只做三件事，别的都不管：
#    1) 给 docker 命令提供「免 sudo」兜底（sg docker），因为新终端可能还没有 docker 组权限
#    2) 判断容器 ros1 是否在跑
#    3) 在容器里执行一条命令（自动 source ROS 环境）
# ==============================================================================

CNAME="${CNAME:-ros1}"
CUSER="${CUSER:-$USER}"
IMAGE="${IMAGE:-ros1-noetic-ocs2:latest}"

# ---------- 载入统一路径解析（可移植性核心）----------
# 这样 WS_ROOT / C_WS_ROOT / C_TOOLS_DIR 都由 simenv.sh 统一决定，
# 换机器/换用户名不用改任何脚本。
_CE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "${_CE_DIR}/simenv.sh"

# ---------- 修正「工具包在容器里的路径」----------
# simenv.sh 是按「宿主机 $HOME 的偏移」推的，但如果脚本是从宿主机别的目录
# （比如开发目录、或 sim_tools 的软链接）调用的，推出来的容器路径在容器里根本不存在。
# 这里以「工具包在容器里真实存在」为准重新判定：
#   候选1: C_WS_ROOT/<工具包相对 WS_ROOT 的偏移>   ← 正常情况（sim_tools 在工作区内）
#   候选2: C_WS_ROOT/sim_tools                     ← 标准位置
#   候选3: 保持 simenv.sh 的推断
if [[ "${TOOLS_DIR}" == "${WS_ROOT}"/* ]]; then
  _rel="${TOOLS_DIR#"${WS_ROOT}"/}"
  C_TOOLS_DIR="${C_WS_ROOT}/${_rel}"
else
  C_TOOLS_DIR="${C_WS_ROOT}/sim_tools"
fi
unset _rel
export C_TOOLS_DIR

# ---------- docker 命令包装：优先直连，不行就 sg docker 兜底 ----------
# 完全照抄你 ros1.sh 里的做法：他那个脚本在没 docker 组权限的终端里也能跑。
if docker info >/dev/null 2>&1; then
  _dk() { docker "$@"; }
elif sg docker -c 'docker info' >/dev/null 2>&1; then
  _dk() { sg docker -c "docker $(printf '%q ' "$@")"; }
else
  echo "[container] 错误: 连不上 docker daemon。" >&2
  echo "           试着执行一次: newgrp docker   然后重开终端" >&2
  return 1 2>/dev/null || exit 1
fi

# ---------- 容器是否在跑 ----------
container_running() {
  [[ -n "$(_dk ps -q -f "name=^${CNAME}$" 2>/dev/null)" ]]
}

# ---------- 校正「工具包在容器里的路径」----------
# 脚本可能是从宿主机开发目录调用的（工具包不在容器挂载点里），
# 那样 simenv.sh 推出来的 C_TOOLS_DIR 在容器里并不存在。
# 这里以「容器里真实存在」为准做一次纠正，保证 container_exec "cd $C_TOOLS_DIR" 不会失败。
if container_running; then
  if ! _dk exec "${CNAME}" test -d "${C_TOOLS_DIR}" 2>/dev/null; then
    if _dk exec "${CNAME}" test -d "${C_WS_ROOT}/sim_tools" 2>/dev/null; then
      C_TOOLS_DIR="${C_WS_ROOT}/sim_tools"
      export C_TOOLS_DIR
    fi
  fi
fi

# ---------- 在容器里执行命令（自动 source ROS 1 环境）----------
# 用法: container_exec 'roslaunch ...'
# 可移植：容器内工作区路径由 C_WS_ROOT 决定（simenv.sh 算好），不写死用户名
container_exec() {
  local cmd="$1"
  _dk exec -i "${CNAME}" bash -lc \
    "source /opt/ros/noetic/setup.bash 2>/dev/null; source ${C_WS_ROOT}/devel/setup.bash 2>/dev/null; export ROBOT_TYPE=\${ROBOT_TYPE:-dmgo}; export WS_ROOT=${C_WS_ROOT}; export C_TOOLS_DIR=${C_TOOLS_DIR}; ${cmd}"
}

# ---------- 在容器里后台执行（nohup，日志重定向）----------
# 用法: container_exec_bg 'roslaunch ...' /path/on/host.log
container_exec_bg() {
  local cmd="$1" logfile="$2"
  local cl="/tmp/$(basename "${logfile}")"
  _dk exec -i -d "${CNAME}" bash -lc \
    "source /opt/ros/noetic/setup.bash 2>/dev/null; source ${C_WS_ROOT}/devel/setup.bash 2>/dev/null; export ROBOT_TYPE=\${ROBOT_TYPE:-dmgo}; export WS_ROOT=${C_WS_ROOT}; export C_TOOLS_DIR=${C_TOOLS_DIR}; ${cmd} > ${cl} 2>&1"
  # 容器内 /tmp 与宿主不同步，用 docker cp 持续捞取不方便，故直接让调用方用 container_exec 阻塞跑
}

# ---------- 把宿主机文件路径映射成容器内路径 ----------
# 你的容器把 $HOME/ros1_ws 挂成 /home/<user>/ros1_ws，其余路径（/tmp、工作区外的）不可见。
host_to_container_path() {
  local p="$1"
  if [[ "${p}" == "${WS_ROOT}"* ]]; then
    printf '%s%s\n' "${C_WS_ROOT}" "${p#"${WS_ROOT}"}"
  elif [[ "${p}" == "${HOME}"* ]]; then
    printf '/home/%s%s\n' "${CUSER}" "${p#"${HOME}"}"
  else
    printf '%s\n' "${p}"
  fi
}
