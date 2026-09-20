#!/usr/bin/env bash
# add_jump_gait.sh —— 往项目的 gait.info 里加自定义步态（含"跳跃"）
#
# 用法：在容器内执行
#   ./add_jump_gait.sh                    # 自动找 dmgo 的 gait.info
#   ./add_jump_gait.sh /path/to/gait.info # 指定文件
#
# 做了什么：
#   1. 备份原 gait.info 为 gait.info.bak.<时间戳>
#   2. 在 list 里补充新步态名
#   3. 追加步态定义（jump / hop / rear_up）
#   4. 如果已经加过，就跳过（幂等）
#
# 加完之后需要重启控制器：重新 roslaunch legged_controllers load_controller.launch

set -euo pipefail

GAIT_FILE="${1:-}"

if [[ -z "${GAIT_FILE}" ]]; then
  # 自动查找：优先 GAIT_INFO / MSGS_DIR 环境变量，再扫常见布局
  for p in \
    "${GAIT_INFO:-}" \
    "${MSGS_DIR:-}/legged_controllers/config/${ROBOT_TYPE:-dmgo}/gait.info" \
    "${WS_ROOT:-$HOME/ros1_ws}/src/open_dog/legged_controllers/config/${ROBOT_TYPE:-dmgo}/gait.info" \
    "${WS_ROOT:-$HOME/ros1_ws}/open-dog-master/src/代码/src/legged_controllers/config/${ROBOT_TYPE:-dmgo}/gait.info" \
    "$(rospack find legged_controllers 2>/dev/null)/config/${ROBOT_TYPE:-dmgo}/gait.info"
  do
    if [[ -n "${p}" && -f "${p}" ]]; then GAIT_FILE="${p}"; break; fi
  done
fi

if [[ -z "${GAIT_FILE}" || ! -f "${GAIT_FILE}" ]]; then
  echo "[add_jump_gait] 找不到 gait.info。请显式指定：" >&2
  echo "    $0 /path/to/gait.info" >&2
  echo "  或用环境变量： MSGS_DIR=... GAIT_INFO=... $0" >&2
  exit 1
fi

if [[ -z "${GAIT_FILE}" || ! -f "${GAIT_FILE}" ]]; then
  echo "[add_jump] 找不到 gait.info，请手动指定：./add_jump_gait.sh /path/to/gait.info"
  exit 1
fi

echo "[add_jump] 目标文件: ${GAIT_FILE}"

if grep -q '^jump$' "${GAIT_FILE}"; then
  echo "[add_jump] 已包含 jump 步态，跳过（幂等）"
  exit 0
fi

# 备份
BAK="${GAIT_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
cp "${GAIT_FILE}" "${BAK}"
echo "[add_jump] 已备份 -> ${BAK}"

# ---------- 1) 在 list 里补充新步态名 ----------
python3 - "${GAIT_FILE}" <<'PYEOF'
import re
import sys

path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    txt = f.read()

# 找到 list { ... } 块，在其中最后一个 [n] 后插入新条目
m = re.search(r'(list\s*\{)(.*?)(\})', txt, re.S)
if not m:
    print('[add_jump] 警告: 没找到 list { } 块，跳过 list 补充')
    sys.exit(0)

block = m.group(2)
# 找出已有最大索引
idxs = [int(x) for x in re.findall(r'\[(\d+)\]', block)]
next_idx = (max(idxs) + 1) if idxs else 0

additions = []
for name in ('jump', 'hop', 'rear_up'):
    if name in block:
        continue
    additions.append('%s[%d]  %s' % (' ' * 4, next_idx, name))
    next_idx += 1

if not additions:
    print('[add_jump] list 里已包含全部新步态')
    sys.exit(0)

new_block = block.rstrip() + '\n' + '\n'.join(additions) + '\n'
txt = txt[:m.start(2)] + new_block + txt[m.end(2):]

with open(path, 'w', encoding='utf-8') as f:
    f.write(txt)

print('[add_jump] list 已补充: %s' % ', '.join(a.strip().split()[-1] for a in additions))
PYEOF

# ---------- 2) 追加步态定义 ----------
cat >> "${GAIT_FILE}" <<'EOF'

; ===== 以下为自定义步态（由 add_jump_gait.sh 添加）=====
; 说明：
;   FLY 模式表示四条腿全部离地（腾空相）。
;   注意：切到这些步态后，还需要给 /cmd_vel 一个正的 linear.z
;         才能真正把身体推起来（见 scripts/jump_demo.py）。

; 原地弹跳：蹲 -> 蹬地腾空 -> 落地
jump
{
  modeSequence
  {
    [0]     STANCE
    [1]     FLY
    [2]     STANCE
  }
  switchingTimes
  {
    [0]     0.0     ; 蓄力
    [1]     0.20    ; 蹬地瞬间，四腿离地
    [2]     0.45    ; 腾空
    [3]     0.70    ; 落地缓冲
  }
}

; 单次跳（比 jump 更短促）
hop
{
  modeSequence
  {
    [0]     STANCE
    [1]     FLY
    [2]     STANCE
  }
  switchingTimes
  {
    [0]     0.0
    [1]     0.12
    [2]     0.30
    [3]     0.50
  }
}

; 后腿站立、前腿抬起（"作揖"/站立动作）
rear_up
{
  modeSequence
  {
    [0]     LF_RF_LH
  }
  switchingTimes
  {
    [0]     0.0
    [1]     1.5
  }
}
EOF

echo "[add_jump] 已追加步态定义: jump / hop / rear_up"
echo
echo "重启控制器后生效（在 gait_command 终端输入 list 应能看到新步态）："
echo "  roslaunch legged_controllers load_controller.launch cheater:=false"
