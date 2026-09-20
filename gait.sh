#!/usr/bin/env bash
# gait.sh —— 一键切换步态（替代手敲 legged_robot_gait_command 终端）
#
# 用法：
#   ./gait.sh list                 # 列出所有可用步态
#   ./gait.sh trot                 # 切到小跑
#   ./gait.sh flying_trot          # 切到腾空小跑（近似"跳着跑"）
#   ./gait.sh skipping             # 切到单腿跳（最像跳跃）
#   ./gait.sh pawup                # 抬前腿
#   ./gait.sh jump                 # 自定义跳跃步态（需先把 jump 段加进 gait.info）
#
# 原理：
#   OCS2 的步态由 legged_robot_gait_command 节点管理，它是**交互式终端**程序，
#   不接受 ROS 话题。所以这里的做法是：
#     用 rosnode info 找到该节点，然后通过它的 stdin 写命令 —— 但 roslaunch
#     启动的节点 stdin 不开放，所以更可靠的办法是【在跑 load_controller.launch
#     的那个终端里手动输入】。
#
#   本脚本提供两种模式：
#     A) 只打印命令和提示（默认）—— 你复制到 gait_command 终端
#     B) 如果你用 gait_bridge.py 启动过（见该文件），则通过话题自动切换

set -euo pipefail

GAIT="${1:-list}"

# ---------- 决定走哪个通道 ----------
if rostopic list 2>/dev/null | grep -q "/gait_cmd_${GAIT}"; then
  echo "[gait] 通过话题 /gait_cmd_${GAIT} 切换（需要 gait_bridge.py 在跑）"
  rostopic pub -1 "/gait_cmd_${GAIT}" std_msgs/Float32 "data: 1.0"
  echo "[gait] 已发布。"
  exit 0
fi

# ---------- 提示人工操作 ----------
echo "======================================================"
echo "  切换步态: ${GAIT}"
echo "======================================================"
echo
echo "OCS2 的步态切换是【交互式终端】操作，请到运行"
echo "  roslaunch legged_controllers load_controller.launch"
echo "的那个终端里，输入："
echo
echo "    ${GAIT}"
echo
echo "输入 list 可以看到全部可用步态。"
echo
echo "本项目 gait.info 里已有的步态："
echo "  stance         四脚站立（不动）"
echo "  trot           小跑步态（默认走法）"
echo "  standing_trot  带停顿的小跑"
echo "  flying_trot    腾空小跑（有腾空相，接近跳跃）"
echo "  pace           同侧腿步态"
echo "  standing_pace  带停顿的同侧步态"
echo "  dynamic_walk   动态行走（4 腿支撑）"
echo "  static_walk    静态行走（最稳）"
echo "  amble          慢步"
echo "  lindyhop       复杂花样步态"
echo "  skipping       单腿跳（最像跳跃）"
echo "  pawup          把前腿抬起"
echo
echo "想加自定义【跳跃】步态，编辑："
echo "  \$(rospack find legged_controllers)/config/dmgo/gait.info"
echo "在 list 里加 'jump'，再按 README 里的 jump 段添加定义。"
echo
echo "提示：没切步态时默认是 stance，机器人不会走，"
echo "      所以「只能前进后退」多半是因为没切 trot。"
