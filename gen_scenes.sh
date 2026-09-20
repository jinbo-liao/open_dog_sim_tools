#!/usr/bin/env bash
# gen_scenes.sh —— 批量生成一批测试场景（.world），用于课程式评测
#
# 用法：
#   ./gen_scenes.sh                    # 生成到 ./worlds/generated/
#   ./gen_scenes.sh /tmp/scenes        # 指定输出目录
#
# 生成内容：
#   1) 通过性阶梯：bumps 高度 0.02~0.12（每 0.01 一档）+ stairs rise 阶梯
#   2) 坡度阶梯：  slope 6/8/10/12/15/20 度
#   3) 沟壑阶梯：  gap 0.08~0.26
#   4) 走廊宽度：  corridor 0.4~1.0
#   5) 随机场景：  mixed/random 各 10 个不同 seed
#
# 这样可以把"能力边界"扫出来：例如 trot 能过 0.06 但过不了 0.09。

set -euo pipefail

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="${TOOLS_DIR}/scripts/omni_world.py"
OUT="${1:-${TOOLS_DIR}/worlds/generated}"

mkdir -p "${OUT}"

echo "生成目录: ${OUT}"
echo

count=0
gen() {
  # gen <场景名> <参数...> -- 由调用者补 -o
  local name="$1"; shift
  python3 "${GEN}" "${name}" "$@" -o "${OUT}/${name}.world" >/dev/null
  count=$((count + 1))
}

echo "[1/5] 通过性阶梯（矮坎高度）..."
for h in 0.02 0.03 0.04 0.05 0.06 0.07 0.08 0.09 0.10 0.12; do
  python3 "${GEN}" bumps --height "${h}" -o "${OUT}/bumps_h${h}.world" >/dev/null
  count=$((count + 1))
done

echo "[2/5] 台阶高度阶梯..."
for r in 0.03 0.04 0.05 0.06 0.08 0.10 0.12; do
  python3 "${GEN}" stairs --height "${r}" -o "${OUT}/stairs_r${r}.world" >/dev/null
  count=$((count + 1))
done

echo "[3/5] 坡度阶梯..."
for a in 6 8 10 12 15 20 25; do
  python3 "${GEN}" slope --angle "${a}" -o "${OUT}/slope_a${a}.world" >/dev/null
  count=$((count + 1))
done

echo "[4/5] 沟壑 / 走廊宽度阶梯..."
for g in 0.08 0.12 0.16 0.20 0.24 0.30; do
  python3 "${GEN}" gap --gap "${g}" -o "${OUT}/gap_${g}.world" >/dev/null
  count=$((count + 1))
done
for w in 0.4 0.5 0.6 0.8 1.0; do
  python3 "${GEN}" corridor --width "${w}" -o "${OUT}/corridor_w${w}.world" >/dev/null
  count=$((count + 1))
done

echo "[5/5] 随机地形（mixed / random 各 10 个 seed）..."
for s in $(seq 1 10); do
  python3 "${GEN}" mixed --seed "${s}" --difficulty 0.5 \
    -o "${OUT}/mixed_s${s}.world" >/dev/null
  count=$((count + 1))
  python3 "${GEN}" random --seed "${s}" --difficulty 0.5 \
    -o "${OUT}/random_s${s}.world" >/dev/null
  count=$((count + 1))
done

# 基础场景也复制一份，方便统一引用
for s in flat rough maze stepping pillars boxes dynamic; do
  python3 "${GEN}" "${s}" --seed 1 -o "${OUT}/${s}.world" >/dev/null
  count=$((count + 1))
done

echo
echo "完成：共生成 ${count} 个场景 -> ${OUT}"
echo
echo "全部 XML 合法性校验:"
bad=0
for f in "${OUT}"/*.world; do
  if ! python3 -c "import xml.etree.ElementTree as ET; ET.parse('${f}')" 2>/dev/null; then
    echo "  ✗ XML 错误: ${f}"
    bad=$((bad + 1))
  fi
done
if [[ "${bad}" -eq 0 ]]; then
  echo "  ✓ ${count} 个文件全部通过"
fi
echo
echo "跑一个试试（容器内）:"
echo "  ./run_scene.sh ${OUT}/bumps_h0.06.world"
