#!/usr/bin/env bash
# run_scene.sh —— 在容器里启动一个场景（Gazebo + 机器人 + 控制器）
#
# 用法：
#   ./run_scene.sh obstacles              # 内置障碍物场景
#   ./run_scene.sh bumps                  # omni_world 场景（自动生成 world）
#   ./run_scene.sh mixed                  # 混合地形
#   ./run_scene.sh /tmp/x/gap_0.2.world   # 直接指定 .world 路径
#   ./run_scene.sh empty                  # 原始空地（对照组）
#   ./run_scene.sh obstacles ctrl         # 第二个终端：只启动控制器
#
#   ▸ 想看有哪些场景： python3 ./omni_world.py --list
#   ▸ 想批量跑并出统计表： ./sweep.sh --dir worlds/generated
#
# 说明：
#   本脚本必须在【容器内】运行，且已 source ROS 环境。
#   它会自动：
#     1. source /opt/ros/noetic/setup.bash 和工作空间
#     2. 用 xacro 生成 URDF 到 /tmp/legged_control/<ROBOT_TYPE>.urdf
#     3. 用 launch/scene.launch 启动 Gazebo + spawn 机器人 + RViz
#
# 因为 Gazebo 图形界面需要 DISPLAY，容器必须有 -e DISPLAY 和 X11 socket 挂载。

set -euo pipefail

SCENE="${1:-empty}"

# ---------- 路径配置（全部经 simenv.sh 解析，换机器不用改）----------
_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "${_HERE}/simenv.sh"

WS_SETUP="${WS_SETUP:-${WS_ROOT}/devel/setup.bash}"
WORLDS_DIR="${TOOLS_DIR}/worlds"
LOGDIR="${LOGDIR:-${WS_ROOT}/sim}"
export ROBOT_TYPE="${ROBOT_TYPE:-dmgo}"
ROS_DISTRO_LOCAL="${ROS_DISTRO_LOCAL:-noetic}"

mkdir -p "${LOGDIR}"

# ---------- 环境 ----------
if [[ -f "/opt/ros/${ROS_DISTRO_LOCAL}/setup.bash" ]]; then
  # shellcheck disable=SC1090
  source "/opt/ros/${ROS_DISTRO_LOCAL}/setup.bash"
else
  echo "[run_scene] 警告: 找不到 /opt/ros/${ROS_DISTRO_LOCAL}/setup.bash" >&2
  echo "           容器里通常是 noetic；若不同请设 ROS_DISTRO_LOCAL=xxx" >&2
fi
if [[ -f "${WS_SETUP}" ]]; then
  # shellcheck disable=SC1090
  source "${WS_SETUP}"
else
  echo "[run_scene] 警告: 找不到工作空间 setup: ${WS_SETUP}"
  echo "           请设置 WS_SETUP=/path/to/devel/setup.bash"
fi

# ---------- 选择 world 文件 ----------
# 支持三种写法：
#   1) 内置别名:      empty | obstacles | stairs | rough
#   2) 直接给 .world:  /path/to/xxx.world
#   3) omni_world 场景: bumps | maze | mixed | random ... （自动生成）
if [[ "${SCENE}" == *.world ]]; then
  WORLD="${SCENE}"
else
  case "${SCENE}" in
    empty)     WORLD="" ;;   # 用项目自带的 empty_world.world
    obstacles) WORLD="${WORLDS_DIR}/obstacles.world" ;;
    stairs)    WORLD="${WORLDS_DIR}/stairs.world" ;;
    rough)     WORLD="${WORLDS_DIR}/rough.world" ;;
    *)
      # 其余交给 omni_world.py 生成
      WORLD="${WORLDS_DIR}/generated/${SCENE}.world"
      ;;
  esac
fi

# 如果 world 文件不存在，尝试用 omni_world.py 现场生成（随机/参数化场景）
if [[ -n "${WORLD}" && ! -f "${WORLD}" ]]; then
  GEN="${TOOLS_DIR}/scripts/omni_world.py"
  if [[ -f "${GEN}" ]]; then
    echo "[run_scene] world 不存在，尝试生成: ${SCENE}"
    python3 "${GEN}" "${SCENE}" -o "${WORLD}" || {
      echo "[run_scene] 生成失败，可用场景见: python3 ${GEN} --list"
      exit 1
    }
  else
    echo "[run_scene] world 文件不存在: ${WORLD}"
    exit 1
  fi
fi

echo "======================================================"
echo " 场景      : ${SCENE}"
echo " world     : ${WORLD:-<项目自带 empty_world.world>}"
echo " ROBOT_TYPE: ${ROBOT_TYPE}"
echo " 日志目录  : ${LOGDIR}"
echo "======================================================"

# ---------- 模式 2：只启动控制器（在另一个终端跑）----------
# 用法: ./run_scene.sh <场景> ctrl
if [[ "${2:-}" == "ctrl" ]]; then
  echo "[run_scene] 启动控制器 load_controller.launch ..."
  roslaunch legged_controllers load_controller.launch cheater:=false \
    2>&1 | tee "${LOGDIR}/controller.log"
  exit 0
fi

# ---------- 生成 URDF（项目要求，见 legged_damiao_hw.launch）----------
# 项目自带的 generate_urdf.sh 内容其实就是：
#   rosrun xacro xacro $1 robot_type:=$2 > /tmp/legged_control/$2.urdf
# 这里等价地直接调 xacro，好处是能真正拿到退出码（项目的脚本里用了 > 重定向，
# 一旦 xacro 报错会生成一个空/半截文件，外面看不出来）。
echo "[run_scene] 生成 URDF ..."
URDF_OUT="/tmp/legged_control/${ROBOT_TYPE}.urdf"
mkdir -p /tmp/legged_control
XACRO_FILE="$(rospack find legged_damiao_description)/urdf/robot.xacro"
if rosrun xacro xacro "${XACRO_FILE}" robot_type:="${ROBOT_TYPE}" > "${URDF_OUT}" 2>"${LOGDIR}/xacro.err"; then
  echo "[run_scene]   URDF OK: ${URDF_OUT} ($(wc -l < "${URDF_OUT}") 行)"
else
  echo "[run_scene]   URDF 生成失败，错误见 ${LOGDIR}/xacro.err"
  tail -20 "${LOGDIR}/xacro.err" || true
  exit 1
fi

# ---------- 启动 Gazebo + 机器人 + RViz ----------
# 用本工具包自带的 launch/scene.launch（world_name 走参数）。
# 它和项目 empty_world.launch 内容一致，仅把写死的 world_name 变成参数，
# 因此不需要修改项目源码。
LAUNCH_FILE="${TOOLS_DIR}/launch/scene.launch"
if [[ ! -f "${LAUNCH_FILE}" ]]; then
  echo "[run_scene] 找不到 ${LAUNCH_FILE}"
  exit 1
fi

echo "[run_scene] 启动 Gazebo（world: ${WORLD:-项目自带 empty_world}）..."
echo "[run_scene] launch: ${LAUNCH_FILE}"
echo "[run_scene] （在另一个终端启动控制器： ./run_scene.sh <场景> ctrl ）"
echo

roslaunch --wait "${LAUNCH_FILE}" \
  world_name:="${WORLD:-$(rospack find legged_gazebo)/worlds/empty_world.world}" \
  2>&1 | tee "${LOGDIR}/empty_world.log"
