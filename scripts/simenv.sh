#!/usr/bin/env bash
# ==============================================================================
#  simenv.sh —— 统一解析「工程路径 / 工作区路径 / 容器内路径」
#
#  ★ 存在的唯一原因：让工具包可以搬到任何用户名、任何目录的机器上。
#
#  优先级（从高到低）：
#    1. 环境变量   WS_ROOT / MSGS_DIR / TOOLS_DIR ...
#    2. 配置文件   <工具包根>/simenv.conf   （make_portable.sh 会按目标机写一份）
#    3. 自动探测   $HOME/ros1_ws、$HOME/open-dog-ros1、rospack find ...
#    4. 兜底       $HOME/ros1_ws
#
#  用法（在脚本里）：
#    TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#    source "${TOOLS_DIR}/scripts/simenv.sh"
# ==============================================================================

# 允许调用方先设好 TOOLS_DIR；没设就按本文件位置推
if [[ -z "${TOOLS_DIR:-}" ]]; then
  TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
export TOOLS_DIR

# ---------- 载入配置文件（若有）----------
if [[ -f "${TOOLS_DIR}/simenv.conf" ]]; then
  # shellcheck disable=SC1090
  source "${TOOLS_DIR}/simenv.conf"
fi

# ---------- 工作区根目录（宿主机视角）----------
# 先看环境变量/配置，再自动探测，最后兜底
if [[ -z "${WS_ROOT:-}" ]]; then
  _home_probe="$(cd ~ && pwd 2>/dev/null || echo "${HOME}")"
  for _c in "${_home_probe}/ros1_ws" "${_home_probe}/catkin_ws" "${_home_probe}/ws"; do
    if [[ -d "${_c}" ]]; then WS_ROOT="${_c}"; break; fi
  done
  unset _home_probe
fi
WS_ROOT="${WS_ROOT:-${HOME}/ros1_ws}"
export WS_ROOT

# ---------- 容器内的工作区路径 ----------
# 你的容器把 $HOME/ros1_ws 挂成 /home/<user>/ros1_ws（同名同构），
# 所以容器内路径 = 把宿主机 $HOME 前缀换成 /home/<user>。
# 如果目标机的容器挂载点不同，在 simenv.conf 里写 C_WS_ROOT 覆盖。
#
# ★ 注意：CUSER 要用「当前登录用户」而不是环境里可能残留的 $USER，
#   否则从别的用户环境（sudo / 继承环境）跑会算错路径。
CUSER="${CUSER:-$(id -un 2>/dev/null || echo "${USER:-user}")}"
if [[ -z "${C_WS_ROOT:-}" ]]; then
  # 优先按“工作区路径相对于 $HOME 的偏移”来推，这样即使 HOME 被改过也对
  _home_real="$(cd ~ && pwd 2>/dev/null || echo "${HOME}")"
  if [[ "${WS_ROOT}" == "${_home_real}"* ]]; then
    C_WS_ROOT="/home/${CUSER}${WS_ROOT#"${_home_real}"}"
  else
    C_WS_ROOT="${WS_ROOT}"
  fi
  unset _home_real
fi
export C_WS_ROOT
export CUSER

# ---------- 工具包在容器内的路径 ----------
if [[ -z "${C_TOOLS_DIR:-}" ]]; then
  _home_real2="$(cd ~ && pwd 2>/dev/null || echo "${HOME}")"
  if [[ "${TOOLS_DIR}" == "${_home_real2}"* ]]; then
    C_TOOLS_DIR="/home/${CUSER}${TOOLS_DIR#"${_home_real2}"}"
  else
    C_TOOLS_DIR="${TOOLS_DIR}"
  fi
  unset _home_real2
fi
export C_TOOLS_DIR

# ---------- 工程源码目录（open_dog / open-dog-master，两种布局都认）----------
# 注意：MSGS_DIR 若为空字符串（simenv.conf 里留空），要当作「未设置」去自动探测
if [[ -z "${MSGS_DIR:-}" ]]; then
  if [[ -n "${SIMENV_MSGS_DIR:-}" && -d "${SIMENV_MSGS_DIR}" ]]; then
    MSGS_DIR="${SIMENV_MSGS_DIR}"
  elif [[ -n "${MSGS_DIR_SET_BY_CONF:-}" && -d "${MSGS_DIR_SET_BY_CONF}" ]]; then
    MSGS_DIR="${MSGS_DIR_SET_BY_CONF}"
  fi
fi

find_msgs_dir() {
  local c
  for c in \
    "${WS_ROOT}/src/open_dog" \
    "${WS_ROOT}/src/open-dog" \
    "${WS_ROOT}/open-dog-master/src/代码/src" \
    "${WS_ROOT}/open-dog-master/src" \
    "${HOME}/open_dog" \
    "${HOME}/open-dog"
  do
    if [[ -d "${c}/legged_controllers" ]]; then
      printf '%s\n' "${c}"; return 0
    fi
  done
  # 容器里用 rospack 问 ROS
  if command -v rospack >/dev/null 2>&1; then
    local p
    p="$(rospack find legged_controllers 2>/dev/null || true)"
    if [[ -n "${p}" ]]; then
      printf '%s\n' "$(cd "${p}/.." && pwd)"; return 0
    fi
  fi
  return 1
}

if [[ -z "${MSGS_DIR:-}" ]]; then
  MSGS_DIR="$(find_msgs_dir 2>/dev/null || true)"
fi
export MSGS_DIR

# ---------- 步态文件 ----------
# 只认真实存在的文件；配置里写错/留空都能自动纠正
if [[ -n "${GAIT_INFO:-}" && ! -f "${GAIT_INFO}" ]]; then
  GAIT_INFO=""
fi
if [[ -z "${GAIT_INFO:-}" && -n "${MSGS_DIR:-}" ]]; then
  GAIT_INFO="${MSGS_DIR}/legged_controllers/config/${ROBOT_TYPE:-dmgo}/gait.info"
  [[ -f "${GAIT_INFO}" ]] || GAIT_INFO=""
fi
export GAIT_INFO

# ---------- 日志目录 ----------
LOGDIR="${LOGDIR:-${WS_ROOT}/sim}"
export LOGDIR

# ---------- 打印（DEBUG=1 时）----------
if [[ "${SIMENV_DEBUG:-0}" == "1" ]]; then
  cat >&2 <<EOF
[simenv] TOOLS_DIR  = ${TOOLS_DIR}
[simenv] WS_ROOT    = ${WS_ROOT}
[simenv] MSGS_DIR   = ${MSGS_DIR:-<未找到>}
[simenv] GAIT_INFO  = ${GAIT_INFO:-<未找到>}
[simenv] C_WS_ROOT  = ${C_WS_ROOT}
[simenv] C_TOOLS_DIR= ${C_TOOLS_DIR}
[simenv] LOGDIR     = ${LOGDIR}
EOF
fi
