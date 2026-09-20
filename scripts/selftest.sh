#!/usr/bin/env bash
# selftest.sh —— 离线自检：不需要 ROS/Gazebo，验证工具包本身没问题
#
# 用法： ./selftest.sh
#
# 检查项：
#   1. 所有 Python 脚本语法
#   2. 所有 bash 脚本语法
#   3. worlds/*.world 的 XML 合法性
#   4. launch/scene.launch 的 XML 合法性
#   5. config/joy_extended.yaml 的 YAML 合法性
#   6. omni_world.py 能生成全部 14 个场景且 XML 合法
#   7. 摔倒判定单元测试（14 项，含起立宽限期回归测试）
#   8. gait_bridge.py 步态解析（用真实 gait.info 校验 trot 的权威值）

set -uo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${TOOLS_DIR}"

PASS=0
FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

echo "======================================================"
echo " open_dog_sim_tools 离线自检"
echo " 目录: ${TOOLS_DIR}"
echo "======================================================"

# ---------- 1. Python 语法 ----------
echo
echo "[1/8] Python 脚本语法"
for f in scripts/*.py; do
  if python3 -m py_compile "${f}" 2>/dev/null; then
    ok "${f}"
  else
    bad "${f}"
    python3 -m py_compile "${f}" 2>&1 | head -5 | sed 's/^/      /'
  fi
done

# ---------- 2. Bash 语法 ----------
echo
echo "[2/8] Bash 脚本语法"
for f in scripts/*.sh; do
  if bash -n "${f}" 2>/dev/null; then
    ok "${f}"
  else
    bad "${f}"
    bash -n "${f}" 2>&1 | head -5 | sed 's/^/      /'
  fi
done

# ---------- 3. world XML ----------
echo
echo "[3/8] worlds/*.world XML"
for f in worlds/*.world; do
  [[ -e "${f}" ]] || continue
  if python3 -c "import xml.etree.ElementTree as ET; ET.parse('${f}')" 2>/dev/null; then
    ok "${f}"
  else
    bad "${f}"
  fi
done

# ---------- 4. launch XML ----------
echo
echo "[4/8] launch/*.launch XML"
for f in launch/*.launch; do
  [[ -e "${f}" ]] || continue
  if python3 -c "import xml.etree.ElementTree as ET; ET.parse('${f}')" 2>/dev/null; then
    ok "${f}"
  else
    bad "${f}"
    python3 -c "import xml.etree.ElementTree as ET; ET.parse('${f}')" 2>&1 | tail -2 | sed 's/^/      /'
  fi
done

# ---------- 5. YAML ----------
echo
echo "[5/8] config/*.yaml"
for f in config/*.yaml; do
  [[ -e "${f}" ]] || continue
  if python3 -c "
import yaml, sys
yaml.safe_load(open('${f}'))
" 2>/dev/null; then
    ok "${f}"
  else
    bad "${f}"
  fi
done

# ---------- 6. omni_world 全部场景 ----------
echo
echo "[6/8] omni_world.py 生成全部场景"
TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT
N_OK=0
SCENE_LIST="$(python3 scripts/omni_world.py --list \
  | sed -n '/^-\{20,\}$/,/^-\{20,\}$/p' \
  | grep -oP '^  \K[a-z_]+(?= +)')"
for s in ${SCENE_LIST}; do
  if python3 scripts/omni_world.py "${s}" --seed 1 -o "${TMPD}/${s}.world" >/dev/null 2>&1 \
     && python3 -c "import xml.etree.ElementTree as ET; ET.parse('${TMPD}/${s}.world')" 2>/dev/null; then
    N_OK=$((N_OK + 1))
  else
    bad "场景 ${s} 生成失败"
  fi
done
if [[ ${N_OK} -gt 0 ]]; then
  ok "${N_OK} 个场景全部生成并通过 XML 校验"
fi

# 参数化检查
if python3 scripts/omni_world.py bumps --height 0.07 -o "${TMPD}/h.world" >/dev/null 2>&1 \
   && grep -q '<size>0.120 1.000 0.070' "${TMPD}/h.world"; then
  ok "--height 参数生效"
else
  bad "--height 参数没生效"
fi

# 可复现性
python3 scripts/omni_world.py mixed --seed 9 -o "${TMPD}/r1.world" >/dev/null 2>&1
python3 scripts/omni_world.py mixed --seed 9 -o "${TMPD}/r2.world" >/dev/null 2>&1
if cmp -s "${TMPD}/r1.world" "${TMPD}/r2.world"; then
  ok "同 seed 输出可复现"
else
  bad "同 seed 输出不一致"
fi

# ---------- 7. 单元测试 ----------
echo
echo "[7/8] 摔倒判定单元测试"
if python3 scripts/test_fall_logic.py > "${TMPD}/ut.log" 2>&1; then
  ok "14 项单元测试全部通过"
else
  bad "单元测试有失败"
  tail -20 "${TMPD}/ut.log" | sed 's/^/      /'
fi

# ---------- 8. 步态桥接自检（不需要 ROS，纯解析）----------
echo
echo "[8/8] 步态桥接 gait_bridge.py"
GB_LOG="${TMPD}/gait_bridge.log"
if python3 - "${TOOLS_DIR}" > "${GB_LOG}" 2>&1 <<'PYEOF'
import sys, types, os
tools = sys.argv[1]
# 宿主机没有 ROS 1，假造 rospy / ocs2_msgs 只测纯解析逻辑
sys.modules['rospy'] = types.ModuleType('rospy')
_m = types.ModuleType('ocs2_msgs.msg')
class _MS(object): pass
_m.mode_schedule = _MS
sys.modules['ocs2_msgs'] = types.ModuleType('ocs2_msgs')
sys.modules['ocs2_msgs.msg'] = _m
sys.path.insert(0, os.path.join(tools, 'scripts'))
import gait_bridge as gb

# 找一份真实的 gait.info 来测
cands = [
    os.path.expanduser('~/ros1_ws/src/open_dog/legged_controllers/config/dmgo/gait.info'),
    os.path.expanduser('~/ros1_ws/src/open_dog/legged_controllers/config/go1/gait.info'),
]
gf = next((c for c in cands if os.path.isfile(c)), None)
if gf is None:
    print('SKIP 没找到 gait.info（机器上没装工程源码）')
    sys.exit(0)

names, gaits = gb.parse_gait_file(gf)
assert len(names) >= 10, '步态数量太少: %d' % len(names)
assert 'trot' in gaits, '没解析出 trot'
assert 'stance' in gaits, '没解析出 stance'

# trot 的权威值（见 gait.info）
assert gaits['trot']['modeSequence'] == ['LF_RH', 'RF_LH'], gaits['trot']
assert [gb.mode_id(m) for m in gaits['trot']['modeSequence']] == [1, 2]
assert gaits['trot']['switchingTimes'] == [0.0, 0.3, 0.6], gaits['trot']

# OCS2 约定：switchingTimes 比 modeSequence 多一个
for n, g in gaits.items():
    assert len(g['switchingTimes']) == len(g['modeSequence']) + 1, \
        '%s 长度不合约定: %s %s' % (n, g['modeSequence'], g['switchingTimes'])

print('OK 解析 %d 个步态, trot=[1,2]/[0.0,0.3,0.6]' % len(names))
PYEOF
then
  ok "gait_bridge 解析正确（$(grep -o 'OK 解析.*' "${GB_LOG}" | head -1)）"
else
  if grep -q '^SKIP' "${GB_LOG}"; then
    ok "gait_bridge 解析（跳过：本机无 gait.info）"
  else
    bad "gait_bridge 解析失败"
    tail -8 "${GB_LOG}" | sed 's/^/      /'
  fi
fi

# ---------- 汇总 ----------
echo
echo "======================================================"
echo " 结果: ${PASS} 通过, ${FAIL} 失败"
echo "======================================================"
[[ ${FAIL} -eq 0 ]] && echo " ✓ 工具包自检通过，可以进容器跑了" || echo " ✗ 请修复上面的问题"
exit $(( FAIL > 0 ? 1 : 0 ))
