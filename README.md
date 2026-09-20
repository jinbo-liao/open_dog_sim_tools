# open-dog 仿真增强工具包

给 `~/ros1_ws/src/open_dog` 的 Gazebo 仿真加：

1. **更多动作**（跳跃 / 奔跑 / 转身 / 站立 / 抬腿等 12 种步态）
2. **障碍物 + 场景**（斜坡、台阶、随机障碍、地形）
3. **自动跑 + 统计摔倒次数**

---

## 0. 怎么跑（实测跑通过的流程，照抄即可）

你的环境已经确认清楚：
- 容器名 **`ros1`**，IMAGE `ros1-noetic-ocs2:latest`
- 容器是 `--rm` 起的 → **只在仿真运行期间存在**；
  仿真一退它就被自动删掉，所以 `docker exec ros1 ...` 报
  `No such container: ros1` 是**正常现象**（不是坏了，是没在跑）
- 启动入口是你自己的 `~/open-dog-ros1/run.sh`
- 新终端可能没有 docker 组权限 → 本工具包用 `sg docker` 兜底（和你 `ros1.sh` 一样）

```bash
cd ~/ros1_ws/sim_tools

# ① 先自检（不需要 ROS，28 项）——出问题先跑这个
./scripts/selftest.sh

# ② 起仿真（宿主机执行；Gazebo/RViz 窗口会弹到你桌面）
./scripts/sim_ctl.sh start --no-rviz      # 省资源；想看 RViz 就去掉 --no-rviz
#    等 SUMMARY.txt 出现 "5) 启动 legged_controller / ok: True" 才算好（约 3~4 分钟）

# ③ 看状态
./scripts/sim_ctl.sh status

# ④ 让它真的走起来（★ 关键：必须先切步态！）
./scripts/walk_test.sh --gait trot --speed 0.4 --duration 15

# ⑤ 验证步态有没有真生效（看四腿触地标志的变化）
./scripts/sim_ctl.sh exec 'cd ~/ros1_ws/sim_tools && python3 scripts/gait_check.py --duration 4'

# ⑥ 自动跑 + 摔倒统计
./scripts/sim_ctl.sh exec 'cd ~/ros1_ws/sim_tools && python3 scripts/auto_run.py --path straight --duration 30 --speed 0.4 --gait trot'

# ⑦ 停掉（容器随之删除）
./scripts/sim_ctl.sh stop
```

> **为什么要先切步态**：OCS2 默认是 `stance`（四脚站着不动）。
> 不切步态就发 `/cmd_vel`，机器人**不会走**，只会被推歪、然后摔倒 ——
> 这是实测踩到的坑，不是猜测。详见下面「为什么控制器 running 但机器人不走」。

---

## 0.5 移植到别的电脑

**结论先给：用你 `~/open-dog-ros1/` 自带的打包工具，一条命令就够。**
（不要用 `sim_tools-portable.tar.gz` 单独拷 —— 它只有 76KB，不含镜像和源码，新机器跑不起来。）

### 第一步：把工具包放进打包范围（本机执行，只需一次）

```bash
cp -r ~/ros1_ws/sim_tools ~/open-dog-ros1/sim_tools
```

> 为什么：`make_bundle.sh` 是**整目录打包** `~/open-dog-ros1/`，
> 而 `sim_tools` 原本在 `~/ros1_ws/` 里，不在打包范围内，不复制就会漏掉。

### 第二步：打包

```bash
cd ~/open-dog-ros1
bash scripts/make_bundle.sh --with-image    # 含 6.45G 镜像，新机器免编译（推荐）
# 或
bash scripts/make_bundle.sh                 # 31M，只含脚本+源码，新机器要自己 build 镜像
```

产物在 `~/open-dog-ros1/bundles/`：

| 文件 | 大小 | 说明 |
|---|---|---|
| `open-dog-ros1-<日期>-with-image.tar` | **1.3 G** | **推荐**，含镜像，新机器 5 分钟就能跑 |
| `open-dog-ros1-<日期>.tar.gz` | 31 M | 不含镜像，新机器要编译 10~30 分钟 |
| `SHA256SUMS.txt` | 200 B | 校验和（搬大文件建议核对） |

### 第三步：拷到新电脑（U盘 / scp / 移动硬盘）

```bash
# 在旧机器上
scp ~/open-dog-ros1/bundles/open-dog-ros1-*-with-image.tar 用户@新机器:/tmp/
scp ~/open-dog-ros1/bundles/SHA256SUMS.txt 用户@新机器:/tmp/
```

### 第四步：新电脑上装（三条命令）

```bash
cd /tmp
tar -xf open-dog-ros1-*-with-image.tar
cd open-dog-ros1-*/

bash scripts/setup_docker.sh    # ① 唯一需要 sudo 的一步：装 Docker
bash install.sh                 # ② 一键装：导入镜像 + 铺源码 + 编译（会跳过已完成的步骤）
bash run.sh                     # ③ 跑仿真（Gazebo + RViz 窗口会弹出）
```

### 第五步：把工具包放到标准位置

```bash
cp -r /tmp/open-dog-ros1-*/sim_tools ~/ros1_ws/sim_tools
cd ~/ros1_ws/sim_tools

SIMENV_DEBUG=1 bash -c 'source scripts/simenv.sh'   # 核对路径（6 行）
./scripts/selftest.sh                                # 28 项，不需要 ROS
./scripts/sim_ctl.sh start --no-rviz
./scripts/walk_test.sh --gait trot --speed 0.4 --duration 12
```

### 前置条件（新电脑必须有）

- **Linux**（Ubuntu 20.04 / 22.04 / 24.04 实测可用）+ 有桌面（要弹 Gazebo 窗口）
- **NVIDIA 显卡可选**，但**装 Docker 需要一次 sudo 密码**
- 磁盘空间：镜像 6.45G + 源码编译产物，**建议留 30G+**
- 新机器用户名可以随便取（`sim_tools` 已做过可移植处理，会自动适配）

### 常见问题

| 现象 | 原因 / 解决 |
|---|---|
| `docker: permission denied` | 执行 `newgrp docker` 再开新终端，或重登一次 |
| `sim_ctl.sh` 报找不到 `run.sh` | `RUN_SH=/你的路径/run.sh ./scripts/sim_ctl.sh start` |
| 路径全错 | `simenv.conf` 没配对。用上面的 `SIMENV_DEBUG=1` 逐项核对 |
| 机器人站着不动 | **必须先切步态**（默认 `stance` 是四脚不动），见下面 0 节 |
| `install.sh` 卡在编译 | 正常，10~30 分钟。有 `-with-image` 的包会跳过构建镜像 |

### 关于 `sim_tools-portable.tar.gz`（另一个包，用途不同）

用 `./scripts/make_portable.sh` 生成，只有 76KB，**仅含工具包本身**。
适合「目标机器已经装好了整套仿真环境，只想更新工具包」的场景：

```bash
./scripts/make_portable.sh                  # 打包
./scripts/make_portable.sh --check-only     # 只做可移植性体检
./scripts/make_portable.sh --with-src       # 连 111M 源码一起打
```

它不能独立使用 —— 缺镜像、缺源码、缺 `~/open-dog-ros1/run.sh`。

---



这不是"功能缺失"，是**配置和用法问题**。你 `gait.info` 里其实已经有 **12 种步态**：

```
stance, trot, standing_trot, flying_trot, pace, standing_pace,
dynamic_walk, static_walk, amble, lindyhop, skipping, pawup
```

它们由 `ocs2_legged_robot_ros/legged_robot_gait_command` 节点（`load_controller.launch` 第 31-32 行启动）
通过 `legged_robot_gait_command` 的**交互式终端**切换 —— 就是你上次在终端 2 里敲 `list` / `trot` 那个。

> ### ★ 2026-09-18 实测确认：为什么"控制器 running 但机器人不走"
>
> 这次在真容器里跑通后，把根因彻底定位清楚了（不是猜）：
>
> 1. **`legged_robot_gait_command` 用的是 `GaitKeyboardPublisher`，只读 stdin。**
>    源码 `ocs2_legged_robot_ros/src/gait/GaitKeyboardPublisher.cpp` 里
>    `getKeyboardCommand()` 靠 `std::cin`。而 `run_sim.sh` 是这样起它的：
>    `roslaunch ... > log 2>&1 &` —— **stdin 不是 TTY**，
>    所以它一直在刷
>    `Enter the desired gait, ... Enter the desired gait, ...`，
>    你敲的字根本没进去，机器人永远停在默认的 **`stance`**（四脚站着不动）。
>
> 2. **但它其实注册了一个 latched 话题**（同一构造函数里）：
>    ```cpp
>    modeSequenceTemplatePublisher_ =
>      nodeHandle.advertise<ocs2_msgs::mode_schedule>(robotName + "_mpc_mode_schedule", 1, true);
>    ```
>    即 **`/legged_robot_mpc_mode_schedule`**（类型 `ocs2_msgs/mode_schedule`）。
>    接收方是 `ocs2_ros_interfaces/.../RosReferenceManager.cpp` 里的
>    `_mode_schedule` 订阅 —— 由 `legged_controller`（在 Gazebo 进程内）持有。
>    **往这个话题发消息 = 等价于键盘敲步态名**，而且不需要 TTY、不用改 C++。
>
> 3. 消息字段名（别猜错）：`ocs2_msgs/msg/mode_schedule.msg` 只有两个字段 ——
>    **`float64[] eventTimes`**（不是 `switchingTimes`）和 **`int8[] modeSequence`**。
>    `eventTimes` 比 `modeSequence` **多一个**元素。
>    例：trot → `modeSequence=[1, 2]`，`eventTimes=[0.0, 0.3, 0.6]`。
>
> 4. **实测验证（真数据，不是推断）**：
>    - 切 `trot` 之前，`/controllers/legged_controller/contacti_flag`
>      （`std_msgs/Float64MultiArray`，四腿触地标志）稳定不动；
>    - 切 `trot` 之后，4 秒内触地状态**变化 128 次**，
>      出现 `(1,1,0,0)`→`(1,1,0,1)`→`(0,1,0,1)` 等交替组合 —— 腿真的在迈。
>    - 同时位姿从 `x=0.540, z=0.156` 走到 `x=0.747, z=0.280`（走起来并站住了）。
>
> 这些结论已经固化进本工具包：
> `scripts/gait_bridge.py`（按名字切步态）、
> `scripts/gait_check.py`（用触地标志验证步态有没有真生效）、
> `scripts/walk_test.sh`（端到端走路 + 位移测量）。

**所以你"只能前进后退"的三个真实原因：**

| 原因 | 说明 | 解决 |
|---|---|---|
| 1. 只推了摇杆，没切步态 | 默认 `stance`（四脚站着不动），你不切 `trot` 它当然不走；切了也只是平移 | 用 `scripts/gait_bridge.py --gait trot`（不依赖键盘） |
| 2. 没做"跳跃"步态 | `gait.info` 里**没有真正的腾空跳跃**（`FLY` 模式虽有，但那是 trot 的腾空相，不是原地起跳） | 见下面「真跳跃怎么做」 |
| 3. 摇杆只映射了 3 个轴 | `joy.yaml` 只映射了 `linear.x/y` 和 `angular.z`，没有按键切步态 | 用工具包的 `joy_extended.yaml` |

### 真·跳跃怎么做（三选一，从易到难）

**方案 A：用现有 `flying_trot` / `skipping` 近似跳跃（改配置就行，推荐先试）**

```
flying_trot  → 有 FLY 腾空相，跑起来是"跳着跑"
skipping     → 单腿跳，最接近跳跃
pawup        → 前腿抬起（抬腿动作）
```

在 `gait.sh` 里输入 `flying_trot` 或 `skipping` 就能看到效果。

**方案 B：自定义跳跃步态（推荐，纯改配置，不用改 C++）**

在 `gait.info` 的 `list` 里加一行，再定义步态。跳跃 = 四条腿同时离地：

```
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
    [0]     0.0    ; 蹲下蓄力
    [1]     0.15   ; 蹬地起跳，四腿离地
    [2]     0.35   ; 腾空
    [3]     0.55   ; 落地缓冲
  }
}
```

> ⚠️ 注意：`FLY` 模式要求四腿全部离地，MPC 需要足够大的 `linear.z` 速度指令才能真正跳起来。
> 单纯切步态只会让腿做"收腿"动作，**要真正离地还得同时给向上速度**。见方案 C。

**方案 C：真正的弹跳（要写代码）**

Gazebo 里真正让身体离地，需要在 MPC 里给基座一个向上的速度指令。
最干净的做法是**加一个跳跃指令节点**，给 `/legged_robot_target` 发一个带 `vz` 的目标轨迹：

```cpp
// 伪代码：在 TargetTrajectoriesPublisher.cpp 里加一个 /jump 订阅
// 让 stateTrajectory[1].head(3) 的 z 分量（基座线速度）给一个正脉冲
```

具体实现见 `scripts/jump_demo.py`（本工具包提供一个发 `/cmd_vel` 带 z 速度的 Python 实现）。

---

## 目录结构

```
open_dog_sim_tools/
├── README.md                    # 本文件
├── GIT-使用说明.md              # git 使用完整手册
├── simenv.conf                  # 路径配置（留空 = 自动探测，不要提交本机私密值）
├── launch/
│   └── scene.launch             # ★ world 可参数化的启动文件（不改项目源码）
├── scripts/                     # ★ 所有脚本都在这里（唯一位置）
│   ├── simenv.sh                # ★ 路径解析（所有脚本 source 它，换机器不用改）
│   ├── make_portable.sh         # 打一个「任意用户名/目录」都能用的工具包
│   ├── selftest.sh              # ★ 离线自检（不需要 ROS，28 项检查）
│   ├── sim_ctl.sh               # ★ 宿主机：起/停/查仿真（封装你的 ~/open-dog-ros1/run.sh）
│   ├── container.sh             # ★ 被上面两个 source：docker 免 sudo 兜底 + 容器内执行
│   ├── omni_world.py            # ★ 程序化生成 14 类测试场景
│   ├── gen_scenes.sh            # ★ 批量生成 62 个场景（能力阶梯 + 随机）
│   ├── sweep.sh                 # ★ 一键跑一批场景并出对比表
│   ├── run_scene.sh             # 启动一个场景（world + 机器人 + 控制器）
│   ├── auto_run.py              # 自动跑 + 统计摔倒次数/距离/极值
│   ├── gait_bridge.py           # ★ 按名字切步态（发 /legged_robot_mpc_mode_schedule，免键盘）
│   ├── gait_check.py            # ★ 验证步态是否真生效（看四腿触地标志）
│   ├── walk_test.sh             # ★ 端到端走路 + 位移测量
│   ├── gait.sh                  # 交互式切步态
│   ├── jump_demo.py             # 发带 z 速度的 cmd_vel，尝试跳跃
│   ├── add_jump_gait.sh         # 往 gait.info 加 jump/hop/rear_up 步态
│   ├── batch_test.sh            # 多步态 × 多速度批量跑
│   └── test_fall_logic.py       # 摔倒判定单元测试（11 项）
├── worlds/
│   ├── obstacles.world          # 手写的障碍物场景
│   ├── stairs.world             # 手写的台阶/斜坡场景
│   ├── rough.world              # 手写的崎岖地形场景
│   └── generated/               # gen_scenes.sh 生成的 62 个场景
└── config/
    └── joy_extended.yaml        # 扩展手柄映射（带步态切换按键）
```

> **注意**：脚本**只在 `scripts/` 下有一份**。
> （历史上顶层曾复制过一份同样的文件，已清理 —— 见 `GIT-使用说明.md` 第十节。）
> 调用一律用 `./scripts/xxx.sh`。

---

## 0.7 用 git 管理和同步（推荐）

> 📖 **完整版请看 [`GIT-使用说明.md`](GIT-使用说明.md)** —— 那是专门的 git 手册，
> 从概念到排错全都有。本节只是速览。

工具包已经是一个 git 仓库（`main` 分支，首次提交已包含全部 106 个文件）。
**git 的好处**：改坏了能回退、能看每次改了什么、多台电脑一条命令更新。

### 日常：改完东西提交

```bash
cd ~/ros1_ws/sim_tools

git status                      # 看哪些文件改了
git diff                        # 看具体改了什么（重要！提交前先看一眼）
git add -A
git commit -m "把 x 改成 y"       # 写清楚改了什么
```

### 改坏了想回退

```bash
git checkout -- 文件名           # 撤销「还没提交」的改动（最常用）
git log --oneline               # 看历史，找到要回的版本号
git revert <版本号>              # 撤销某次「已提交」的改动（安全，会留记录）
```

### 同步到其他电脑

**方式一：打包带走（不需要网络）**

```bash
# 本机
cd ~/ros1_ws/sim_tools
git bundle create /tmp/sim_tools.bundle --all
scp /tmp/sim_tools.bundle 用户@目标机:/tmp/

# 目标机（首次）
cd ~/ros1_ws && git clone /tmp/sim_tools.bundle sim_tools
# 目标机（以后每次更新）
cd ~/ros1_ws/sim_tools && git pull /tmp/sim_tools.bundle main
```

**方式二：放到私有仓库（Gitee / GitHub / 自建）**

```bash
# 本机首次推到远端
git remote add origin <你的仓库地址>
git push -u origin main

# 其他电脑首次拉取
cd ~/ros1_ws && git clone <你的仓库地址> sim_tools

# 以后本机改完推送
git add -A && git commit -m "..." && git push

# 其他电脑更新
cd ~/ros1_ws/sim_tools && git pull
```

**方式三：rsync（不用 git，纯文件同步）**

```bash
rsync -av --delete --exclude='__pycache__' --exclude='*.pyc' \
      ~/ros1_ws/sim_tools/  用户@目标机:~/ros1_ws/sim_tools/
```

### ★ 哪些文件不进 git（`.gitignore` 已配好）

| 文件 | 是否进库 | 原因 |
|---|---|---|
| `simenv.conf` | ✅ 进 | 全空模板，所有机器共用 |
| `simenv.conf.local` | ❌ **不进** | 含本机用户名和绝对路径，别的机器用了会指错 |
| `__pycache__/` `*.pyc` | ❌ 不进 | Python 缓存，自动生成 |
| `*.tar` `*.tar.gz` | ❌ 不进 | 打包产物，会越滚越大 |
| `sim/` `*.log` | ❌ 不进 | 仿真日志，几百 M |

### 注意事项

1. **`simenv.conf.local` 绝不要提交** —— 里面有 `/home/yqc/...`，同步到别的机器会污染路径探测
2. **可执行位很重要** —— `*.sh` 必须是 `-rwx`，否则同步过去跑不了。git 默认会保留
3. **仓库里现在有重复文件** —— 顶层和 `scripts/` 下同名文件内容相同（历史遗留）。不影响使用，但改的时候建议**只改 `scripts/` 下的**，且两处都要改
4. **`git checkout --` 会永久丢弃改动** —— 执行前先 `git diff` 确认

---

## 0.8 推到 GitHub（从零开始的完整教程）

> **你的账号信息**（本机已配好）：
> - GitHub 用户名：**`jinbo-liao`**（API 实测存在，ID 316855035）
> - 邮箱：`13246842228@163.com`
> - SSH 公钥：**已生成**，位置 `~/.ssh/id_ed25519.pub`
> - `~/.ssh/config`：**已配好**（GitHub 自动走 443 端口）
> - git 身份：**已配好**（`jinbo-liao` / `13246842228@163.com`）
>
> ## ⚠️ 重要：本机访问 github.com 是「间歇性」的
>
> **实测结论（2026-09-20，连续多次测量）**：
>
> **同一天内，`github.com:443` 一会儿不通、一会儿又通。**
>
> | 时间 | `github.com:443` | 结果 |
> |---|---|---|
> | 第一次测 | 超时 20 秒 | ❌ 不通，`HTTP 000` |
> | 几分钟后再测 | 0.68 秒返回 | ✅ 通，`HTTP 200` |
> | 连测 3 次 | 全部正常 | ✅ 稳定通 |
>
> **所以：打不开网页时，先刷新几次或等几分钟再试。**
>
> ### 诊断过程（为什么判断是网络层干扰）
>
> | 检查项 | 结果 | 说明 |
> |---|---|---|
> | 百度 / 淘宝 / Gitee | ✅ HTTP 200 | 本机网络本身没问题 |
> | DNS 解析 `github.com` | ✅ `20.205.243.166` | **没被污染**（阿里/Google/系统 DNS 结果一致） |
> | ping 该 IP | ✅ 通，83ms | 路由可达 |
> | TCP 连 `20.205.243.166:443` | ✅ **能握手** | 端口没被封 |
> | **HTTPS/TLS 握手** | ❌ 超时 / 时而 ✅ 通 | **卡死在这一层** |
>
> `curl -v` 抓到的关键现场：
>
> ```
> * Connected to github.com (20.205.243.166) port 443   ← TCP 连上了
> * TLSv1.3 (OUT), TLS handshake, Client hello (1):     ← 发出 TLS 问候
>    （然后卡死，没有响应）
> ```
>
> **TCP 通、DNS 正常，但 TLS 握手被丢弃** —— 典型的网络层干扰特征
> （不是 DNS 污染、不是端口封锁，而是握手阶段随机掐断）。
> 这类阻断是**概率性**的，所以同一台机器同一时段会时通时不通。
>
> ### 各通道实测状态
>
> | 地址 | 状态 | 用途 |
> |---|---|---|
> | `github.com:443` | ⚠️ **时通时不通** | 网页、HTTPS clone |
> | `github.com:22`（SSH） | ✅ 稳定通 | SSH 推送 |
> | `ssh.github.com:443` | ✅ 稳定通 | **已设为默认通道，推送靠这个** |
> | `api.github.com:443` | ✅ 通（HTTP 200） | API |
> | `codeload.github.com:443` | ✅ 通 | 下载 |
> | `gitee.com:443` | ✅ **一直稳** | 国内码云，不用代理 |
> | 本地代理端口 7890/1080/8080 | ❌ 全没开 | 没有可用代理 |
>
> ### 打不开网页怎么办（按顺序试）
>
> | 办法 | 说明 |
> |---|---|
> | **① 刷新几次 / 等几分钟** | 间歇性阻断，很可能自己就好了 |
> | **② 手机热点** | 最可靠，手机流量网络通常不拦 |
> | **③ 改用 Gitee** | `gitee.com` 一直稳，完全不折腾（见下方方案 C） |
> | **④ 不用远程** | `git bundle` 打包拷文件，不需要任何账号（见方案 D） |
>
> **注意**：即使网页打不开，**推送往往是能用的** ——
> 因为推送走 `ssh.github.com:443`，这条路实测稳定。
> 所以「网页打不开」不等于「推不了代码」。
>
> ### 方案 A：换网络开网页（最快）
>
> 手机开热点给电脑，或连别的 WiFi，然后开 **https://github.com/settings/keys**。
> 贴完公钥、建好仓库，切回原来网络也能正常推送（推送通道本来就是通的）。
>
> ### 方案 B：用 Gitee（国内最稳，长期推荐）
>
> `gitee.com` 实测**一直通畅**，网页能开、能推送，不用代理：
>
> 1. 打开 **https://gitee.com** 注册/登录（可用同一邮箱 `13246842228@163.com`）
> 2. 头像 → **设置** → 左侧 **安全设置 → SSH 公钥**
> 3. 标题随便填，公钥框粘贴 `cat ~/.ssh/id_ed25519.pub` 的内容，点**确定**
> 4. 点右上 **+** → **新建仓库** → 名字 `open_dog_sim_tools` → **不要勾**任何初始化选项 → 创建
> 5. 本机执行：
>
> ```bash
> cd ~/ros1_ws/sim_tools
> ssh -T git@gitee.com                      # 应显示 Gitee 的欢迎语
> git remote add origin git@gitee.com:jinbo-liao/open_dog_sim_tools.git
> git push -u origin main
> ```
>
> ⚠️ **Gitee 坑点：默认分支叫 `master`，本地是 `main`。**
> 推送后到仓库「管理 → 默认分支」改成 `main`，否则别人克隆下来是**空的**
> （实测报错 `remote HEAD refers to nonexistent ref`）。
>
> ### 方案 C：用 API 传公钥（命令行，不用网页）
>
> `api.github.com` 实测可用，所以可以用 Token 直接把公钥传上去：
>
> ```bash
> TOKEN=你的token
> curl -sS -X POST -H "Authorization: token $TOKEN" \
>      -H "Accept: application/vnd.github+json" \
>      https://api.github.com/user/keys \
>      -d "{\"title\":\"我的笔记本\",\"key\":\"$(cat ~/.ssh/id_ed25519.pub)\"}"
> ```
>
> 返回 JSON 里有 `"id"` 就是成功，返回 `"message": "Bad credentials"` 就是 Token 不对。
>
> **怎么拿 Token**：需要先在**能开 GitHub 网页的网络**（比如手机热点）上，
> 打开 https://github.com/settings/tokens → **Generate new token (classic)** →
> 勾选 **`admin:public_key`**（传公钥必需）→ 生成 → **复制那串 `ghp_...`**（只显示一次）。
>
> ### 方案 D：不用远程，直接拷（兜底）
>
> 如果上面都嫌麻烦，其实不用 GitHub 也行 —— `git bundle` 就能搬整个仓库：
>
> ```bash
> # 本机
> cd ~/ros1_ws/sim_tools
> git bundle create /tmp/sim_tools.bundle --all
> ls -lh /tmp/sim_tools.bundle        # 约 92K
>
> # 拷到其他电脑（U盘 / scp / 微信传输都行）后
> cd ~/ros1_ws && git clone /tmp/sim_tools.bundle sim_tools
> # 以后更新
> cd ~/ros1_ws/sim_tools && git pull /tmp/sim_tools.bundle main
> ```
>
> 缺点：没有网页界面看代码、不能在任意地方拉取。优点：**零配置、不需要任何账号**。

---

### 以下步骤需要 github.com 网页可访问（网络通时适用）

如果哪天你的网络能开 github.com 了（或用了方案 B 的热点），就按下面的标准流程走。

### 第 1 步：把公钥贴到 GitHub（网页操作）

你的公钥内容如下，**复制这一整行**：

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL8iwrJbnBW+tKkJYAm8DMZ/7bwwPmGWlFe4TzoedQvA 13246842228@163.com
```

也可以随时自己打印一次：

```bash
cat ~/.ssh/id_ed25519.pub
```

然后：

1. 浏览器打开 **https://github.com/settings/keys**
   （登录 `jinbo-liao` → 右上角头像 → **Settings** → 左侧 **SSH and GPG keys**）
2. 点绿色按钮 **New SSH key**
3. **Title** 填 `我的笔记本`（随便，方便你自己认）
4. **Key type** 保持 `Authentication Key`
5. **Key** 框里粘贴上面那一整行
6. 点 **Add SSH key**

> **指纹核对**（可选）：你的密钥指纹是
> `SHA256:nvMDkdNxWQaULZI6kxPo6iyaSqDWC8J4J9yIFK/3/+Y`
> 添加后用 `ssh-keygen -lf ~/.ssh/id_ed25519.pub` 再看一眼，确认一致。

### 第 2 步：验证连上了

```bash
ssh -T git@github.com
```

**看到这句话就成功了：**

```
Hi jinbo-liao! You've successfully authenticated, but GitHub does not provide shell access.
```

> `does not provide shell access` **是正常的**，不是错误 —— 说明认证通过了。
>
> 在贴公钥之前，这条命令会返回 `Permission denied (publickey)`，
> 那说明**通道通了但钥匙还没登记**，属正常中间状态。

### 第 3 步：在 GitHub 建一个空仓库（网页操作）

1. 打开 **https://github.com/new**
2. **Repository name** 填 `open_dog_sim_tools`
3. **Description** 选填，如 `open-dog 仿真测试场景工具包`
4. **★ 关键：下面三个都不要勾**
   - ❌ 不要勾 `Add a README file`
   - ❌ 不要选 `Add .gitignore`
   - ❌ 不要选 `Choose a license`
5. 点 **Create repository**

> **为什么必须建空仓库**：你本地已经有代码和 2 个提交了。如果网页上建了 README，
> 远端就有你本地没有的提交，`push` 会被拒绝（提示 `rejected / non-fast-forward`），
> 新手最容易卡在这里。**万一已经勾了**，见下方报错对照表的解法。

### 第 4 步：把本地代码推上去（本机执行）

```bash
cd ~/ros1_ws/sim_tools

git remote add origin git@github.com:jinbo-liao/open_dog_sim_tools.git
git push -u origin main
```

**`-u` 是记住这个远端**，以后直接 `git push` / `git pull` 就行，不用再打全名。

成功的话会看到类似：

```
Enumerating objects: 110, done.
Writing objects: 100% (110/110), 89.5 KiB | 2.1 MiB/s, done.
To github.com:jinbo-liao/open_dog_sim_tools.git
 * [new branch]      main -> main
branch 'main' set up to track 'origin/main'.
```

### 第 5 步：其他电脑上拉取

**首次**（目标机上执行一次）：

```bash
# 目标机也要有自己的 SSH key 并加到 GitHub（重复第 1 步），
# 或直接复用同一把密钥（把 ~/.ssh/id_ed25519 和 .pub 拷过去也行）
cd ~/ros1_ws && git clone git@github.com:jinbo-liao/open_dog_sim_tools.git sim_tools
```

**以后每次更新**（就一条命令）：

```bash
cd ~/ros1_ws/sim_tools && git pull
```

### 日常循环：改完代码

```bash
cd ~/ros1_ws/sim_tools
git status                    # 看改了哪些
git diff                      # 看具体改了什么
git add -A
git commit -m "说明改了什么"
git push                      # 推到 GitHub
```

### 常见报错对照表

| 报错 | 原因 | 解决 |
|---|---|---|
| `Permission denied (publickey)` | 公钥没加到 GitHub，或加错了 | 重做第 1~2 步，`ssh -T git@github.com` 必须显示 `Hi jinbo-liao!` |
| `Connection timed out` / `port 443` | 用了 HTTPS 地址 | 改成 SSH：`git@github.com:jinbo-liao/open_dog_sim_tools.git` |
| `rejected ... non-fast-forward` | 建仓库时勾了 README | `git pull --rebase origin main` 再 `git push` |
| `fatal: remote origin already exists` | 已经加过 origin | `git remote set-url origin <新地址>` |
| `Please tell me who you are` | 没配 git 身份 | 见下方"补充" |
| `src refspec main does not match any` | 本地没有提交，或分支不叫 main | 先 `git add -A && git commit`；`git branch -M main` |
| 推上去发现**漏了文件** | 被 `.gitignore` 排除了 | `git check-ignore -v 文件名` 查是哪条规则 |

### 补充：git 身份配置

本仓库已经配好（`jinbo-liao` / `13246842228@163.com`）。
**其他电脑首次用 git 需要配一次**，或只对这个仓库配（推荐，不动全局）：

```bash
cd ~/ros1_ws/sim_tools
git config user.name "jinbo-liao"
git config user.email "13246842228@163.com"
```

### ★ 推之前一定检查：别把私密文件推上去

```bash
git status --short                    # 看有哪些要提交
git check-ignore -v simenv.conf.local # 确认被忽略了
git ls-files | grep -i local          # 应该没有输出
```

**`simenv.conf.local` 绝对不能推** —— 里面有 `/home/yqc/...` 和用户名，
公开仓库里泄路径虽然不算大事，但别人克隆后路径探测会被污染。

### 如果 GitHub 实在连不上：用 Gitee

`gitee.com:443` 本机实测**是通的**，不用代理。操作几乎一样：

1. 注册 https://gitee.com
2. 头像 → **设置** → **SSH 公钥** → 粘贴 `~/.ssh/id_ed25519.pub` 内容
3. **+** → **新建仓库** → 名字填 `open_dog_sim_tools` → **不要**勾初始化
4. 验证：`ssh -T git@gitee.com`
5. 推送：

```bash
git remote add origin git@gitee.com:jinbo-liao/open_dog_sim_tools.git
git push -u origin main
```

**注意**：Gitee 的默认分支叫 `master`，本地是 `main`。推送后到
仓库「管理 → 默认分支」改成 `main` 即可；否则**别人克隆下来会是空的**
（实测报错 `remote HEAD refers to nonexistent ref`）。

---

## 1. 先自检（不用 ROS）


> **先说本机实测的网络情况**（2026-09-20 实测）：
>
> | 地址 | 状态 | 说明 |
> |---|---|---|
> | `github.com:443` (HTTPS) | ❌ **不通** | 国内网络常见，需要代理 |
> | `github.com:22` (SSH) | ✅ **通** | 能握手（要求公钥） |
> | `ssh.github.com:443` (SSH走443) | ✅ 通 | 备用通道 |
> | `gitee.com:443` | ✅ 通 | 国内码云，不用代理 |
>
> **所以本机推荐走 SSH，不要用 HTTPS。** 如果 SSH 也不稳，直接用 Gitee（见文末）。

### 第 1 步：生成 SSH 密钥（本机做，一次就好）

```bash
ssh-keygen -t ed25519 -C "你的邮箱@example.com"
```

**会问三个问题，全都直接按回车：**

| 提示 | 怎么答 |
|---|---|
| `Enter file in which to save the key` | 直接回车（用默认 `~/.ssh/id_ed25519`） |
| `Enter passphrase` | 直接回车（不设密码，方便；要安全就设一个） |
| `Enter same passphrase again` | 直接回车 |

然后看公钥内容：

```bash
cat ~/.ssh/id_ed25519.pub
```

输出形如（**这一整行就是要复制的东西，以 `ssh-ed25519` 开头、邮箱结尾**）：

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... 你的邮箱@example.com
```

### 第 2 步：把公钥贴到 GitHub（网页操作）

1. 浏览器打开 **https://github.com/settings/keys**
   （或：登录 GitHub → 右上角头像 → **Settings** → 左侧 **SSH and GPG keys**）
2. 点绿色按钮 **New SSH key**
3. **Title** 随便填，比如 `我的笔记本`
4. **Key type** 保持 `Authentication Key`
5. **Key** 框里粘贴刚才 `cat` 出来的**一整行**
6. 点 **Add SSH key**

### 第 3 步：验证连上了

```bash
ssh -T git@github.com
```

**看到这句话就成功了：**

```
Hi 你的用户名! You've successfully authenticated, but GitHub does not provide shell access.
```

> 这句 `does not provide shell access` **是正常的**，不是错误 —— 说明认证通过了。

### 第 4 步：在 GitHub 建一个空仓库（网页操作）

1. 打开 **https://github.com/new**
2. **Repository name** 填 `open_dog_sim_tools`
3. **Description** 选填，如 `open-dog 仿真测试场景工具包`
4. **★ 关键：下面两个都不要勾**
   - ❌ 不要勾 `Add a README file`
   - ❌ 不要选 `Add .gitignore`
   - ❌ 不要选 `Choose a license`
5. 点 **Create repository**

> **为什么必须建空仓库**：你本地已经有代码和提交了。如果网页上建了 README，
> 远端就有你本地没有的提交，`push` 会被拒绝（提示 `rejected / non-fast-forward`），
> 新手最容易卡在这里。

建完后页面会显示仓库地址，记下它：

```
git@github.com:你的用户名/open_dog_sim_tools.git
```

### 第 5 步：把本地代码推上去

```bash
cd ~/ros1_ws/sim_tools

git remote add origin git@github.com:你的用户名/open_dog_sim_tools.git
git push -u origin main
```

**`-u` 是记住这个远端**，以后直接 `git push` / `git pull` 就行，不用再打全名。

成功的话会看到类似：

```
Enumerating objects: 110, done.
Writing objects: 100% (110/110), 89.5 KiB | 2.1 MiB/s, done.
To github.com:你的用户名/open_dog_sim_tools.git
 * [new branch]      main -> main
branch 'main' set up to track 'origin/main'.
```

### 第 6 步：其他电脑上拉取

**首次**（目标机上执行一次）：

```bash
# 目标机也要有自己的 SSH key 并加到 GitHub（重复第 1~2 步）
cd ~/ros1_ws && git clone git@github.com:你的用户名/open_dog_sim_tools.git sim_tools
```

**以后每次更新**（就一条命令）：

```bash
cd ~/ros1_ws/sim_tools && git pull
```

### 日常循环：改完代码

```bash
cd ~/ros1_ws/sim_tools
git status                    # 看改了哪些
git diff                      # 看具体改了什么
git add -A
git commit -m "说明改了什么"
git push                      # 推到 GitHub
```

### 常见报错对照表

| 报错 | 原因 | 解决 |
|---|---|---|
| `Permission denied (publickey)` | 公钥没加到 GitHub，或加错了 | 重做第 1~3 步，`ssh -T git@github.com` 必须能通过 |
| `Connection timed out` / `port 443` | HTTPS 不通（本机就这情况） | 改用 SSH 地址：`git@github.com:用户/仓库.git` |
| `rejected ... non-fast-forward` | 建仓库时勾了 README，远端有本地没有的提交 | `git pull --rebase origin main` 再 `git push` |
| `fatal: remote origin already exists` | 已经加过 origin 了 | `git remote set-url origin <新地址>` |
| `Please tell me who you are` | 没配 git 身份 | 见下方"补充" |
| `src refspec main does not match any` | 本地没有提交，或分支不叫 main | 先 `git add -A && git commit`；`git branch -M main` |
| 推上去发现**漏了文件** | 被 `.gitignore` 排除了 | `git check-ignore -v 文件名` 查是哪条规则 |

### 补充：git 身份配置

本仓库已经配好了（`yqc` / `yqc@localhost`）。**其他电脑首次用 git 需要配一次**：

```bash
git config --global user.name "你的名字"
git config --global user.email "你的邮箱@example.com"
```

或只对这一个仓库生效（推荐，不动全局）：

```bash
cd ~/ros1_ws/sim_tools
git config user.name "你的名字"
git config user.email "你的邮箱@example.com"
```

### ★ 推之前一定检查：别把私密文件推上去

```bash
git status --short                    # 看有哪些要提交
git check-ignore -v simenv.conf.local # 确认被忽略了
git ls-files | grep -i local          # 应该没有输出
```

**`simenv.conf.local` 绝对不能推** —— 里面有 `/home/yqc/...` 和用户名，
公开仓库里泄路径虽然不算大事，但白送给别人会污染他们的路径探测。

### 如果 GitHub 实在连不上：用 Gitee

`gitee.com:443` 本机实测**是通的**，不用代理。操作几乎一样：

1. 注册 https://gitee.com
2. 头像 → **设置** → **SSH 公钥** → 粘贴 `~/.ssh/id_ed25519.pub` 内容
3. **+** → **新建仓库** → 名字填 `open_dog_sim_tools` → **不要**勾初始化
4. 验证：`ssh -T git@gitee.com`
5. 推送：

```bash
git remote add origin git@gitee.com:你的用户名/open_dog_sim_tools.git
git push -u origin main
```

**注意**：Gitee 的默认分支叫 `master`，本地是 `main`。推送后到
仓库「管理 → 默认分支」改成 `main` 即可；或者本地改名 `git branch -M master` 再推。

---

## 1. 先自检（不用 ROS）

```bash
cd open_dog_sim_tools
./scripts/selftest.sh
```

会检查所有脚本语法、XML/YAML 合法性、14 个场景能否生成、11 项单元测试。
**预期 28 通过 0 失败**。

---

## 2. 测试场景（这是重点）

### 2.1 内置 14 类场景

```bash
python3 scripts/omni_world.py --list
```

| 场景 | 用途 | 可调参数 |
|---|---|---|
| `flat` | 纯平地基准组 | — |
| `bumps` | 等间距矮坎，测通过性 | `--height 0.03~0.12` |
| `stairs` | 连续台阶 | `--height`(rise) |
| `rough` | 随机碎石不平地面 | `--height`(最高) |
| `maze` | 之字形走廊，测转向 | — |
| `gap` | 沟壑，测越沟 | `--gap 0.08~0.30` |
| `slope` | 斜坡+平台+下坡 | `--angle 6~25` |
| `corridor` | 窄走廊，测贴墙 | `--width 0.4~1.0` |
| `stepping` | 错落踏步石，测落脚 | `--height` |
| `pillars` | 密集圆柱阵，测避障 | `--count` |
| `boxes` | 阶梯升高箱子（0.05/0.10/0.20/0.30） | — |
| `dynamic` | 可推动障碍，测抗扰动 | `--count` |
| `mixed` | 混合地形，综合考核 | `--difficulty 0~1 --seed` |
| `random` | 完全随机，压力测试 | `--difficulty --seed --count` |

示例：

```bash
# 生成一个 8cm 矮坎场景
python3 scripts/omni_world.py bumps --height 0.08 -o /tmp/bumps8.world

# 20 度斜坡
python3 scripts/omni_world.py slope --angle 20 -o /tmp/slope20.world

# 可复现的随机地形（同 seed 必定同结果）
python3 scripts/omni_world.py mixed --seed 3 --difficulty 0.7 -o /tmp/mixed3.world
```

> **关键设计**：场景尺寸围绕 dmgo 实际能力（站高 ~0.35 m、步高 ~0.12 m）设计，
> 所以矮坎 0.03~0.10 是"能不能过"的分界线，0.25 m 以上必摔。
> 全部只用 box/cylinder/sphere，不依赖 Gazebo 模型数据库，离线可加载。

### 2.2 批量生成 62 个场景（能力阶梯）

```bash
./scripts/gen_scenes.sh              # 输出到 worlds/generated/
```

生成内容：
- **通过性阶梯**：`bumps_h0.02` ~ `bumps_h0.12`（10 档）→ 扫出"最高能过多高"
- **台阶阶梯**：`stairs_r0.03` ~ `stairs_r0.12`（7 档）
- **坡度阶梯**：`slope_a6` ~ `slope_a25`（7 档）
- **沟壑阶梯**：`gap_0.08` ~ `gap_0.30`（6 档）
- **走廊宽**：`corridor_w0.4` ~ `corridor_w1.0`（5 档）
- **随机**：`mixed_s1..10` + `random_s1..10`（20 个，可复现）

### 2.3 跑单场景

```bash
# 终端1：起 Gazebo + 机器人 + RViz
./scripts/run_scene.sh obstacles
./scripts/run_scene.sh bumps              # 自动生成 world
./scripts/run_scene.sh /tmp/bumps8.world  # 直接给路径

# 终端2：起控制器
./scripts/run_scene.sh obstacles ctrl

# 终端3：自动跑 + 统计
python3 scripts/auto_run.py --duration 60 --speed 0.4 --gait trot
```

### 2.4 一键扫一批场景并出对比表 ★

```bash
./scripts/sweep.sh --dir worlds/generated          # 跑全部 62 个
./scripts/sweep.sh obstacles stairs rough          # 跑指定几个
DURATION=90 GAIT=trot SPEED=0.5 ./scripts/sweep.sh --dir /tmp/genscenes
HEADLESS=1 ./scripts/sweep.sh --dir worlds/generated   # 无显示器
```

`sweep.sh` 会自动：逐个场景 → 重启 Gazebo → 起控制器 → 切控制器 →
`auto_run.py` 跑一段 → 收集统计 → 清理进程 → 下一个。最后输出：

```
scene,duration,distance,falls,fall_per_min,max_tilt_deg,min_z,csv,log
bumps_h0.02,60,12.31,0,0.000,18.2,0.341,...
bumps_h0.08,60,8.44,2,2.000,71.3,0.108,...
bumps_h0.12,60,3.12,5,5.000,88.1,0.052,...
```

按摔倒次数排序就能看出**能力边界**：

```bash
sort -t, -k4 -nr /home/yqc/ros1_ws/sim/sweep_*/sweep_summary.csv | head
```

---

## 摔倒检测原理

工具包用**两条判据**判断摔倒（Gazebo 里没有现成的 "fall" 事件）：

| 判据 | 话题 | 阈值 |
|---|---|---|
| 机体倾角过大 | `/ground_truth/state`（`gazebo_ros_p3d` 插件发布，见 `gazebo.xacro`） | roll/pitch > 45° |
| 机体高度过低 | 同上，`position.z` | < 0.15 m（正常站立 ~0.35 m） |

异常需**持续 0.5 s** 才确认（抗抖动误判）。另外全程记录两个极值：

- `max_tilt_deg` —— 最大倾角（**即使没摔倒也能看出"接近摔倒"的程度**）
- `min_z` —— 最低基座高度

这两个极值很关键：跑 `flat` 时如果 `max_tilt` 已经 40°，说明步态本身就不稳。

这两个数据来自 URDF 里的 `p3d_base_controller` 插件：
```xml
<plugin name="p3d_base_controller" filename="libgazebo_ros_p3d.so">
  <bodyName>base</bodyName>
  <topicName>ground_truth/state</topicName>
  <frameName>world</frameName>
</plugin>
```
**这个插件已经配好了，不用改代码**，直接订阅就能拿到绝对位姿。

`auto_run.py` 输出示例：

```
  运行时长        : 60.0 s
  行走距离        : 12.31 m
  平均速度        : 0.205 m/s (指令 0.40)
  摔倒次数        : 2
  平均无摔倒时长  : 20.0 s
  摔倒频率        : 2.000 次/分钟
  最大倾角        : 71.3 deg
  最低高度        : 0.108 m
```

另外还有个更简单的信号：`LeggedController.cpp` 第 141-145 行的 `SafetyChecker`
—— 倾角超过 ±90° 会直接停控制器并打印 `Safety check failed`。摔倒统计也可以数这个。

---

## 4. 更多动作 / 步态

### 4.1 已有 12 种步态

```
stance, trot, standing_trot, flying_trot, pace, standing_pace,
dynamic_walk, static_walk, amble, lindyhop, skipping, pawup
```

由 `ocs2_legged_robot_ros/legged_robot_gait_command` 节点通过**交互式终端**切换。

**你"只能前进后退"的真实原因：默认步态是 `stance`（四脚站着），没切到 `trot`。**
切换方式：控制器起来后，在 `gait_command` 终端输入 `list` 看列表，输入 `trot` 切换。

### 4.2 加跳跃步态

```bash
./scripts/add_jump_gait.sh      # 往 gait.info 加 jump / hop / rear_up（幂等+自动备份）
```

重启控制器后生效。配合发向上速度：

```bash
python3 scripts/jump_demo.py --hops 5 --vz 1.5
```

> ⚠️ **诚实说明**：真跳跃光切步态不够，必须同时给 `/cmd_vel` 的 `linear.z`
> （`TargetTrajectoriesPublisher.cpp` 里 `cmdVel[2] = msg->linear.z` 映射成基座垂直速度）。
> 而且 MPC 的质心动力学把基座高度当状态约束，**地面约束可能不让它真离地**。
> 如果 `jump_demo.py` 报告"最大抬升 < 0.02 m"，那就需要改 `reference.info` 的
> `comHeight` 或写专用跳跃参考轨迹 —— 那是要动 C++ 的。

---

## 5. 落地步骤（在容器内）

### 5.1 先确认环境（实测过的真实路径）

```bash
# 宿主机：拷进容器可见目录（/home/yqc/ros1_ws 是容器的 bind mount）
cp -r /home/yqc/.cline/data/workspaces/chat/open_dog_sim_tools /home/yqc/ros1_ws/sim_tools
chmod +x /home/yqc/ros1_ws/sim_tools/scripts/*.sh /home/yqc/ros1_ws/sim_tools/scripts/*.py
```

本工具包已按你的真实环境配置好，**默认值即正确**：

| 项 | 值 | 说明 |
|---|---|---|
| 工作空间 | `/home/yqc/ros1_ws` | `devel/setup.bash` 已存在 |
| 项目源码 | `/home/yqc/ros1_ws/src/open_dog` | ⚠️ **不是** `open-dog-master/src/代码/src` |
| ROS | `noetic`（容器内） | 可用 `ROS_DISTRO_LOCAL` 覆盖 |
| 机器人 | `dmgo` | `ROBOT_TYPE=dmgo` |
| 日志 | `/home/yqc/ros1_ws/sim/` | 已有 `SUMMARY.txt` 等历史记录 |

> **注意**：宿主机 `/opt/ros/` 只有 `jazzy`（ROS 2），**没有 ROS 1**。
> 所以所有 `roslaunch` 命令**必须在容器内执行**，宿主机只能跑 `selftest.sh`。

### 5.2 容器内执行

```bash
# 进入容器（名字按你的实际情况，历史日志里是 ros1）
docker exec -it ros1 bash

cd /home/yqc/ros1_ws/sim_tools

./scripts/selftest.sh      # 28 通过 0 失败（不需要 ROS，宿主机也能跑）
./scripts/gen_scenes.sh    # 生成 62 个场景
./scripts/run_scene.sh flat
```

### 快速验证清单

| 步骤 | 命令 | 预期 |
|---|---|---|
| 1 | `./scripts/selftest.sh` | 28 通过 0 失败 |
| 2 | `python3 scripts/omni_world.py --list` | 列出 14 个场景 |
| 3 | `./scripts/gen_scenes.sh` | 生成 62 个 world，全部 XML 通过 |
| 4 | `./scripts/run_scene.sh flat` | Gazebo 起来，狗站在平地上 |
| 5 | `./scripts/run_scene.sh flat ctrl` | 控制器加载成功 |
| 6 | `python3 scripts/auto_run.py --duration 30` | 出统计报告 |

如果第 4 步失败，按此顺序排查：

```bash
echo $DISPLAY                       # 必须是 :0 之类，不是空
ls /tmp/.X11-unix/                  # 容器要挂载了 X11 socket
cat /home/yqc/ros1_ws/sim/empty_world.log | tail -40
```

### 与项目源码的关系

工具包**不修改** `src/open_dog` 的任何文件（唯一例外：`add_jump_gait.sh`
会往 `gait.info` 追加段落，且自动备份 + 幂等，第二次运行会跳过）。
关键做法是用 `launch/scene.launch` 替代项目里 `world_name` 写死的 `empty_world.launch`：

```xml
<!-- src/open_dog/.../legged_damiao_description/launch/empty_world.launch：写死 -->
<arg name="world_name" value="$(find legged_gazebo)/worlds/empty_world.world"/>
<!-- 本工具包的 scene.launch：可参数化（value → default） -->
<arg name="world_name" default="$(find legged_gazebo)/worlds/empty_world.world"/>
```

其他部分（xacro 展开、`generate_urdf.sh`、`default.yaml`、
spawn 初始关节角 `-J LF_KFE -2.101` 等、RViz）全部与项目保持一致，
已逐行比对过项目的 `empty_world.launch`。
