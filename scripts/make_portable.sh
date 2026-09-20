#!/usr/bin/env bash
# ==============================================================================
#  make_portable.sh —— 打一个「任意用户名 / 任意目录」都能用的工具包
#
#  用法：
#    ./scripts/make_portable.sh                     # 自动探测，出 tar.gz
#    ./scripts/make_portable.sh --out /tmp/xx.tar.gz
#    ./scripts/make_portable.sh --check-only        # 只做可移植性体检，不打包
#    ./scripts/make_portable.sh --with-src          # 连工程源码一起打（+111M）
#
#  它会做四件事：
#    1) 体检：扫描所有脚本里的写死路径（/home/<某人>/...）
#    2) 生成 simenv.conf（记录目标机的路径 + 容器挂载点）
#    3) 打包成 tar.gz，忽略 __pycache__ / 日志
#    4) 打印目标机上的解压 + 使用步骤
# ==============================================================================

set -uo pipefail

_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$(cd "${_HERE}/.." && pwd)"

OUT=""
CHECK_ONLY=0
WITH_SRC=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)         OUT="$2"; shift 2 ;;
    --check-only)  CHECK_ONLY=1; shift ;;
    --with-src)    WITH_SRC=1; shift ;;
    -h|--help)     sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
done

C_GRN=$'\033[32m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'; C_OFF=$'\033[0m'
info() { printf '%s[信息]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[成功]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[警告]%s %s\n' "$C_YEL" "$C_OFF" "$*"; }
bad()  { printf '%s[错误]%s %s\n' "$C_RED" "$C_OFF" "$*"; }

echo "======================================================"
echo " 打包可移植工具包"
echo " 源: ${TOOLS_DIR}"
echo "======================================================"

# ---------- 1) 可移植性体检 ----------
echo
info "1) 可移植性体检：扫描写死的绝对路径"
HARD=$(grep -rn -E '/home/[a-z_][a-z0-9_-]*/' \
         --include='*.sh' --include='*.py' \
         "${TOOLS_DIR}/scripts" 2>/dev/null \
       | grep -v -E '/home/<user>|/home/\$\{|/home/%s|simenv\.sh' \
       || true)

if [[ -n "${HARD}" ]]; then
  bad "发现写死的用户名路径（会让别的机器跑不起来）："
  echo "${HARD}" | sed 's/^/     /'
  echo
  warn "建议改成："
  echo "     bash:  \${WS_ROOT} / \${C_WS_ROOT} / \${C_TOOLS_DIR}  （由 simenv.sh 提供）"
  echo "     python: os.environ.get('WS_ROOT') / os.path.expanduser('~')"
  PORTABLE=0
else
  ok "没有写死的用户名路径"
  PORTABLE=1
fi

echo
info "   检查关键脚本语法"
SYNTAX_OK=1
for f in "${TOOLS_DIR}"/scripts/*.sh; do
  bash -n "$f" 2>/dev/null || { bad "语法错: $(basename "$f")"; SYNTAX_OK=0; }
done
for f in "${TOOLS_DIR}"/scripts/*.py; do
  python3 -m py_compile "$f" 2>/dev/null || { bad "语法错: $(basename "$f")"; SYNTAX_OK=0; }
done
rm -rf "${TOOLS_DIR}/scripts/__pycache__" 2>/dev/null
[[ ${SYNTAX_OK} -eq 1 ]] && ok "   全部脚本语法通过"

if [[ ${CHECK_ONLY} -eq 1 ]]; then
  echo
  if [[ ${PORTABLE} -eq 1 && ${SYNTAX_OK} -eq 1 ]]; then
    ok "体检通过（--check-only，未打包）"
    exit 0
  else
    bad "体检未通过"
    exit 1
  fi
fi

# ---------- 2) 生成 simenv.conf ----------
echo
info "2) 生成 simenv.conf（目标机路径配置）"

# shellcheck disable=SC1090
source "${TOOLS_DIR}/scripts/simenv.sh"

CONF="${TOOLS_DIR}/simenv.conf"
cat > "${CONF}" <<'EOF'
# ==============================================================================
#  simenv.conf —— 路径配置
#
#  ★ 换机器时改这一个文件即可，不用碰任何脚本。
#  ★ 被 scripts/simenv.sh 自动加载。
#
#  ★★ 重要：这里所有变量「留空 = 自动探测」。「不要」把原机器（打包那台）
#     的路径原样带过来，否则在别的用户名/别的机器上会全部指错！
#     只在你确认自动探测失败时，才手工填。
# ==============================================================================

# 宿主机工作区根目录（通常就是 $HOME/ros1_ws）——留空自动探测
WS_ROOT=

# 宿主机登录用户名（容器内同名）——留空自动用当前登录用户
CUSER=

# 容器内的工作区路径（= 容器里 bind mount 的挂载点）——留空按 WS_ROOT 推算
C_WS_ROOT=

# 工具包在容器内的路径——留空按 TOOLS_DIR 推算
C_TOOLS_DIR=

# 工程源码根目录（含 legged_controllers 的那一层）——留空自动探测
MSGS_DIR=

# 步态文件绝对路径——留空自动探测
GAIT_INFO=

# 机型（这个一般不用改）
ROBOT_TYPE=dmgo
EOF
ok "已写入 ${CONF}（默认全部留空 = 自动探测，可直接搬到别的机器）"

# 顺便生成一份「本机实测值」备查，不含在包里
cat > "${TOOLS_DIR}/simenv.conf.local" <<EOF
# 本机（打包那台机器）实测解析值 —— 仅供排查参考，不要带到别的机器
WS_ROOT=${WS_ROOT}
CUSER=${CUSER}
C_WS_ROOT=${C_WS_ROOT}
C_TOOLS_DIR=${C_TOOLS_DIR}
MSGS_DIR=${MSGS_DIR:-}
GAIT_INFO=${GAIT_INFO:-}
EOF
info "本机实测值已另存: simenv.conf.local（排查用）"

# ---------- 3) 打包 ----------
echo
STAMP="$(date +%Y%m%d)"
NAME="sim_tools-portable-${STAMP}"
OUT="${OUT:-${TOOLS_DIR}/../${NAME}.tar.gz}"
OUT="$(cd "$(dirname "${OUT}")" && pwd)/$(basename "${OUT}")"

info "3) 打包 -> ${OUT}"

TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT
DEST="${TMPD}/${NAME}"
mkdir -p "${DEST}"

tar -C "${TOOLS_DIR}" \
    --exclude='__pycache__' --exclude='*.pyc' \
    --exclude='*.tar' --exclude='*.tar.gz' \
    --exclude='./simenv.conf.local' \
    -cf - . | tar -C "${DEST}" -xf - 2>/dev/null

# 双保险：解包后再清一遍（某些 tar 版本对 --exclude 匹配有差异）
find "${DEST}" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
find "${DEST}" -name '*.pyc' -delete 2>/dev/null

# 包内放一份「打包机实测值」供排查（是信息性文件，不是本机私密配置）
cat > "${DEST}/simenv.conf.local" <<EOF
# 打包机（$(hostname)）当时的实测解析值 —— 仅供排查参考
# ★ 这个文件不会被 scripts/simenv.sh 加载（它只读 TOOLS_DIR/simenv.conf），
#   所以里面的路径不会影响新机器上的自动探测。
WS_ROOT=${WS_ROOT}
CUSER=${CUSER}
C_WS_ROOT=${C_WS_ROOT}
C_TOOLS_DIR=${C_TOOLS_DIR}
MSGS_DIR=${MSGS_DIR:-}
GAIT_INFO=${GAIT_INFO:-}
EOF

if [[ ${WITH_SRC} -eq 1 && -n "${MSGS_DIR}" && -d "${MSGS_DIR}" ]]; then
  info "   附带工程源码: ${MSGS_DIR}"
  mkdir -p "${DEST}/src"
  tar -C "$(dirname "${MSGS_DIR}")" \
      --exclude='*/build' --exclude='*/devel' --exclude='*/.git' \
      --exclude='__pycache__' --exclude='*.pyc' \
      -cf - "$(basename "${MSGS_DIR}")" | tar -C "${DEST}/src" -xf - 2>/dev/null
fi

chmod +x "${DEST}"/scripts/*.sh 2>/dev/null
rm -rf "${DEST}/scripts/__pycache__"

# ---------- 包内说明 ----------
cat > "${DEST}/PORTABLE-HOWTO.md" <<'HOWTO'
# 在新电脑上怎么用

## 1. 解压到工作区

```bash
mkdir -p ~/ros1_ws
tar -xzf sim_tools-portable-*.tar.gz -C ~/ros1_ws
mv ~/ros1_ws/sim_tools-portable-* ~/ros1_ws/sim_tools   # 改名（脚本默认找 sim_tools）
cd ~/ros1_ws/sim_tools
```

## 2. 先别急着改 simenv.conf

包里的 `simenv.conf` **默认全部留空 = 自动探测**，绝大多数情况直接就能用。
先跑这条看看自动探测结果对不对：

```bash
SIMENV_DEBUG=1 bash -c 'source scripts/simenv.sh'
```

输出里有 6 行，重点是这两行的「用户名」部分要对：

```
[simenv] WS_ROOT    = /home/你的用户名/ros1_ws
[simenv] C_WS_ROOT  = /home/你的用户名/ros1_ws     ← 必须和容器里的挂载点一致
```

- **全对** → 什么都不用改，跳到第 3 步。
- **`C_WS_ROOT` 不对** → 说明容器里的挂载点不是 `/home/<用户>/ros1_ws`，
  这时才需要改 `simenv.conf`：

```
CUSER=你的用户名
C_WS_ROOT=/容器里的实际挂载点/ros1_ws
C_TOOLS_DIR=/容器里的实际挂载点/ros1_ws/sim_tools
```

怎么查真实挂载点：
```bash
sg docker -c 'docker inspect ros1 --format "{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}"'
```

> ⚠️ 不要从原机器（打包那台）抄路径过来 —— 用户名不同就会全错。

## 3. 体检 + 自检

```bash
SIMENV_DEBUG=1 bash -c 'source scripts/simenv.sh'   # 逐项核对路径
./scripts/selftest.sh                                # 26 项，不需要 ROS
```

## 4. 工具包「不含」的东西（必须另配）

| 依赖 | 体积 | 怎么带过来 |
|---|---|---|
| Docker 镜像 `ros1-noetic-ocs2:latest` | 6.45G | `cd ~/open-dog-ros1 && bash scripts/make_bundle.sh --with-image` |
| open-dog 工程源码 | 111M | 同上，或本包加 `--with-src` 重打 |
| 启动脚本 `~/open-dog-ros1/run.sh` | 1.5G | 同上（`sim_ctl.sh` 依赖它） |

`run.sh` 若不在默认位置：
```bash
RUN_SH=/你的路径/run.sh ./scripts/sim_ctl.sh start
```

## 5. 跑起来

```bash
./scripts/sim_ctl.sh start --no-rviz
./scripts/walk_test.sh --gait trot --speed 0.4 --duration 12
./scripts/sim_ctl.sh stop
```

## 常见问题

- **`docker: permission denied`**
  执行一次 `newgrp docker` 再开新终端，或 `sudo usermod -aG docker $USER` 后重登。
  脚本内已有 `sg docker` 兜底，通常直接就能用。

- **路径全错**
  `simenv.conf` 没改对。用 `SIMENV_DEBUG=1 bash -c 'source scripts/simenv.sh'` 逐项核对。

- **`sim_ctl.sh` 报找不到 run.sh**
  `RUN_SH=/你的路径/run.sh ./scripts/sim_ctl.sh start`

- **机器人站着不动**
  必须先切步态（默认 `stance` 是四脚不动）。
  `./scripts/walk_test.sh --gait trot` 会自动切；手动切用
  `python3 scripts/gait_bridge.py --gait trot`。
HOWTO

tar -C "${TMPD}" -czf "${OUT}" "${NAME}"
SIZE="$(du -h "${OUT}" | cut -f1)"

# ---------- 4) 完成 ----------
echo
echo "======================================================"
ok "打包完成: ${OUT}  (${SIZE})"
echo "======================================================"
echo
info "包内结构:"
tar -tzf "${OUT}" | head -25 | sed 's/^/     /'
echo "     ... 共 $(tar -tzf "${OUT}" | wc -l) 项"
echo
info "在新电脑上："
echo "     mkdir -p ~/ros1_ws"
echo "     tar -xzf $(basename "${OUT}") -C ~/ros1_ws"
echo "     mv ~/ros1_ws/${NAME} ~/ros1_ws/sim_tools"
echo "     cd ~/ros1_ws/sim_tools && ./scripts/selftest.sh"
echo
warn "新机器还需要 Docker 镜像 + open-dog 源码才能真的跑仿真"
warn "（详见包内 PORTABLE-HOWTO.md）"
echo
if [[ ${PORTABLE} -eq 1 ]]; then
  ok "可移植性: 通过（无写死路径）"
else
  bad "可移植性: 有写死路径，请先修好"
  exit 1
fi

