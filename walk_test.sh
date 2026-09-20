#!/usr/bin/env bash
# ==============================================================================
#  walk_test.sh —— 端到端验证「机器人真的会走」（宿主机执行）
#
#  为什么单独写一个：
#    之前的 auto_run.py 直接发 /cmd_vel 却发现机器人不动，原因是
#    OCS2 默认步态是 stance（四脚站着），不发步态切换就永远不走。
#    这个脚本按正确顺序做：
#      1) 记录初始位姿
#      2) 用 gait_bridge.py 切到 trot（走话题，不需要键盘）
#      3) 同步发 /cmd_vel 前进
#      4) 量实际位移，判断到底有没有走
#
#  用法:
#    ./scripts/walk_test.sh                # 默认 trot，0.4 m/s，20 秒
#    ./scripts/walk_test.sh --gait dynamic_walk --speed 0.3 --duration 30
# ==============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${DIR}/container.sh"

GAIT="trot"
SPEED="0.4"
DURATION="20"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gait) GAIT="$2"; shift 2 ;;
    --speed) SPEED="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

if ! container_running; then
  echo "[walk_test] 容器 ${CNAME} 没在跑 → 先 ./scripts/sim_ctl.sh start" >&2
  exit 1
fi

echo "=== 1) 初始位姿 ==="
container_exec 'timeout 5 rostopic echo -n1 /ground_truth/state/pose/pose/position 2>/dev/null | grep -E "x:|y:|z:" | head -n 3'

echo
echo "=== 2) 切换步态 -> ${GAIT} ==="
# 可移植：用容器内工具包路径变量，不写死用户名/目录
container_exec "cd ${C_TOOLS_DIR} && python3 scripts/gait_bridge.py --gait ${GAIT} 2>&1 | tail -n 4"

echo
echo "=== 3) 发 /cmd_vel 前进 ${SPEED} m/s，持续 ${DURATION}s ==="
container_exec "(timeout ${DURATION} rostopic pub -r 20 /cmd_vel geometry_msgs/Twist \"{linear: {x: ${SPEED}, y: 0.0, z: 0.0}, angular: {x: 0.0, y: 0.0, z: 0.0}}\" >/dev/null 2>&1 &) ; sleep ${DURATION}; sleep 2"

echo
echo "=== 4) 结束位姿 ==="
container_exec 'timeout 5 rostopic echo -n1 /ground_truth/state/pose/pose/position 2>/dev/null | grep -E "x:|y:|z:" | head -n 3'

echo
echo "=== 结论判读 ==="
echo "  把上面「初始」和「结束」的 x/y 比一下："
echo "    x 明显增大  → 在走（步态切换生效）"
echo "    x 基本不变  → 没走，检查 【$GAIT】是否被 MPC 接受（看 mpc 日志）"
echo "    z < 0.15    → 摔了"
