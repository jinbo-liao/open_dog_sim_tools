# Git 使用说明

> 这份文档专门讲**怎么用 git 管理这个工具包**，以及**怎么在多台电脑之间同步**。
> 面向没怎么用过 git 的人，所有命令都可以直接复制粘贴。
>
> 配套阅读：`README.md` 的「0.7 用 git 管理和同步」「0.8 推到 GitHub」两节。

---

## 一、现在的状态（已经配好的东西）

| 项目 | 值 |
|---|---|
| 本地仓库 | `~/ros1_ws/sim_tools` |
| 远程仓库 | https://github.com/jinbo-liao/open_dog_sim_tools |
| GitHub 用户名 | `jinbo-liao` |
| 邮箱 | `13246842228@163.com` |
| 分支 | `main` |
| SSH 密钥 | `~/.ssh/id_ed25519`（已加到 GitHub，验证通过） |
| SSH 配置 | `~/.ssh/config`（GitHub 自动走 443 端口） |

**验证一切正常**（任何一条不通过就去看第七节）：

```bash
cd ~/ros1_ws/sim_tools
ssh -T git@github.com      # 应显示 Hi jinbo-liao! ...
git status                 # 应显示 On branch main
git log --oneline          # 应能看到提交历史
```

---

## 二、核心概念（30 秒看懂）

git 有 **4 个区域**，理解这个就理解 git 了：

```
   工作区              暂存区            本地仓库          远程仓库
（你改的文件）      （准备提交的）     （存档历史）      （GitHub）
     │                  │                  │                │
     │  git add         │  git commit      │  git push      │
     └─────────────────>└─────────────────>└───────────────>│
                                                        │
     ┌──────────────────────────────────────────────────┘
     │  git pull（把 GitHub 上的更新拉下来）
     <──────────────────────────────────────────────────
```

| 区域 | 是什么 | 对应命令 |
|---|---|---|
| **工作区** | 你正在编辑的文件 | 直接改就行 |
| **暂存区** | "我准备把这几处改动存档" | `git add` |
| **本地仓库** | 一堆存档快照（可以回退） | `git commit` |
| **远程仓库** | GitHub 上的备份 | `git push` / `git pull` |

**类比**：
- `git add` = 把要存档的东西放进盒子
- `git commit` = 盖上盒子封存（本地存档）
- `git push` = 把盒子寄到云端（GitHub）

**关键**：`commit` 之后就能回退了，不用等到 `push`。

---

## 三、日常使用（最常用的 5 条）

```bash
cd ~/ros1_ws/sim_tools

git status           # ① 看哪些文件改了
git diff             # ② 看具体改了什么 ← 提交前一定先看
git add -A           # ③ 把改动加入暂存区
git commit -m "说明"  # ④ 存档（务必写清改了什么）
git push             # ⑤ 推到 GitHub
```

### 实际例子

假设你改了 `walk_test.sh` 里的默认速度：

```bash
$ cd ~/ros1_ws/sim_tools
$ git status
        modified:   walk_test.sh       ← 这个文件改了

$ git diff                             ← 看看改了什么
- SPEED="0.4"
+ SPEED="0.3"
        ↑ 减号是原来的，加号是新的

$ git add -A
$ git commit -m "walk_test 默认速度改成 0.3"
$ git push
```

**就这样。** 以后想回到这个版本，随时能回。

---

## 四、看历史 / 回退

### 看历史

```bash
git log --oneline                    # 简洁版（一行一个提交）
git log --oneline -5                 # 只看最近 5 条
git log --stat                       # 每个提交改了哪些文件
git show c1ad9c5                     # 看某个提交的具体改动
git diff c1ad9c5 HEAD                # 对比两个版本的区别
```

### 三种回退场景

**场景 1：刚改完，还没 commit，发现改错了 → 撤销**

```bash
git diff                       # 先确认要丢掉什么！
git checkout -- walk_test.sh   # 撤销单个文件
git checkout -- .              # 撤销全部未提交的改动
```

⚠️ **这个操作会永久丢弃改动**，无法恢复。执行前必须 `git diff` 确认。

**场景 2：已经 commit 了，想撤销那次提交 → revert（安全）**

```bash
git log --oneline              # 找到要撤销的提交号
git revert c1ad9c5             # 撤销它（会生成一个新提交记录）
git push
```

**推荐用 `revert`** —— 它不会删历史，只是"再做一个反向的改动"，安全且可追溯。

**场景 3：想临时看看某个旧版本 → 只读查看**

```bash
git show c1ad9c5:walk_test.sh          # 直接看那个版本的文件内容
git diff c1ad9c5 -- walk_test.sh       # 对比那个版本和现在的区别
```

看完就完了，不会改变当前状态。

---

## 五、同步到其他电脑

### 首次：在目标电脑上克隆

**准备工作**：目标电脑也要能连 GitHub（配 SSH 密钥）。

```bash
# ① 在目标电脑上，如果没有密钥就先生成
ssh-keygen -t ed25519 -C "13246842228@163.com"   # 一路回车

# ② 打印公钥，加到 GitHub（https://github.com/settings/keys）
cat ~/.ssh/id_ed25519.pub

# ③ 验证
ssh -T git@github.com          # 应显示 Hi jinbo-liao!

# ④ 克隆
cd ~/ros1_ws
git clone git@github.com:jinbo-liao/open_dog_sim_tools.git sim_tools

# ⑤ 配 git 身份（每台机器一次）
cd sim_tools
git config user.name "jinbo-liao"
git config user.email "13246842228@163.com"

# ⑥ 验证
./scripts/selftest.sh          # 应显示 28 通过, 0 失败
```

> **偷懒办法**：把 `~/.ssh/id_ed25519` 和 `~/.ssh/id_ed25519.pub` 直接从旧电脑拷到新电脑的 `~/.ssh/`，就不用重新加公钥了。

### 以后：每次更新

```bash
cd ~/ros1_ws/sim_tools
git pull                       # 就这一条
```

### 反过来：目标电脑改了东西要同步回来

```bash
# 目标电脑上
git add -A && git commit -m "说明" && git push

# 本机
git pull
```

> ⚠️ **两台机器同时改同一文件会冲突**。建议**固定在一台机器上改**，其他机器只 `git pull`，最省心。

---

## 六、别把私密文件推上去

### `.gitignore` 的作用

`.gitignore` 里列出的文件**不会被 git 跟踪**（改多少都不会被提交）。

本工具包已配好，排除这些：

| 文件 / 目录 | 为什么排除 |
|---|---|
| **`simenv.conf.local`** | ⚠️ **含本机用户名和绝对路径**（如 `/home/yqc/...`），别的机器用了会污染路径探测 |
| `__pycache__/` `*.pyc` | Python 缓存，自动生成 |
| `*.tar` `*.tar.gz` | 打包产物，会越滚越大 |
| `sim/` `*.log` | 仿真日志，几百 M |
| `*.bak` `*~` `.vscode/` `.idea/` | 备份和编辑器配置 |

### 提交前必查这两条

```bash
git check-ignore -v simenv.conf.local   # 必须显示被忽略
git ls-files | grep -i local            # 必须没有输出
```

### 已经被误提交了怎么删

```bash
# 从 git 里删掉，但保留本地文件
git rm --cached simenv.conf.local
git commit -m "移除误提交的本地配置"
git push
```

⚠️ **注意**：这只能让**以后**不再跟踪。**已经推上去的历史里仍然存在**，
别人翻历史还能看到。如果里面有敏感信息（密码、Token），必须改成正确的处理方式
（`git filter-repo` 重写历史，或直接删仓库重建）。

---

## 七、常见问题

### 基础

| 问题 | 解决 |
|---|---|
| `Please tell me who you are` | 没配身份：`git config user.name "jinbo-liao"` + `git config user.email "13246842228@163.com"` |
| `not a git repository` | 目录不对，先 `cd ~/ros1_ws/sim_tools` |
| 想知道自己在哪个分支 | `git branch --show-current` |

### 推送相关

| 问题 | 解决 |
|---|---|
| `Permission denied (publickey)` | 公钥没加到 GitHub。`ssh -T git@github.com` 验证，不通过就重加 |
| `Connection timed out` | 用了 `https://` 地址。改成 `git@github.com:jinbo-liao/...` |
| `rejected ... non-fast-forward` | 远端有你本地没有的提交（可能建仓库时勾了 README）。执行 `git pull --rebase origin main` 再 `git push` |
| `fatal: remote origin already exists` | 已配过远端。改地址用 `git remote set-url origin <新地址>` |
| `src refspec main does not match any` | 本地还没提交，或分支不叫 main。先 `git add -A && git commit`；必要时 `git branch -M main` |
| 推送很慢 / 卡住 | 网络问题。等一会儿重试，或改用 Gitee（见第八节） |

### 拉取相关

| 问题 | 解决 |
|---|---|
| `git pull` 报冲突（`CONFLICT`） | 打开冲突文件，找 `<<<<<<<` 标记，手动改成想要的样子，删掉标记，然后 `git add -A && git commit` |
| 拉下来发现文件少了 | 可能被 `.gitignore` 排除了。`git check-ignore -v 文件名` 查原因 |
| 本地改动被 `pull` 挡住了 | 先 `git stash`（暂存改动）→ `git pull` → `git stash pop`（恢复改动） |

### 想撤销操作

| 想干什么 | 命令 |
|---|---|
| 撤销还没 `add` 的改动 | `git checkout -- 文件名` |
| 撤销已 `add` 但没 `commit` 的 | `git reset HEAD 文件名`（退回未 add 状态） |
| 撤销最后一次 `commit`（保留改动） | `git reset --soft HEAD~1` |
| 撤销最后一次 `commit`（丢弃改动） | `git reset --hard HEAD~1` ⚠️危险 |
| 撤销已推送的 `commit` | `git revert <提交号>` 然后 `git push` |
| 忘了刚才 `reset --hard` 丢了什么 | `git reflog` 找到丢失的提交号，再 `git reset --hard <那个号>` |

---

## 八、GitHub 连不上怎么办

### 先诊断

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://github.com    # 200=通
ssh -T git@github.com                                           # Hi jinbo-liao!=通
```

**实测经验**：本机 `github.com` 是**间歇性**可访问 —— 有时超时，有时又通。
诊断结论是 **TLS 握手阶段被随机掐断**（不是 DNS 污染，也不是端口封锁）：

```
* Connected to github.com (20.205.243.166) port 443    ← TCP 连上了
* TLSv1.3 (OUT), TLS handshake, Client hello (1):      ← 发出 TLS 问候
   （然后卡死，服务器没响应）
```

### 打不开网页时的办法

| 办法 | 说明 |
|---|---|
| **① 刷新几次 / 等几分钟** | 间歇性阻断，常会自己好 |
| **② 手机热点** | 最可靠，手机流量网络通常不拦 |
| **③ 用 Gitee** | 国内一直稳，见下方 |
| **④ 不用远程** | `git bundle` 拷文件，见下方 |

> **重要**：**推送往往不受影响**！推送走 `ssh.github.com:443`（已配在 `~/.ssh/config`），
> 这条路实测稳定。所以 **"网页打不开" ≠ "推不了代码"**。

### 方案：改用 Gitee（国内最稳）

```bash
# 1. gitee.com 注册，设置 → SSH 公钥 → 粘贴 ~/.ssh/id_ed25519.pub
# 2. 新建仓库 open_dog_sim_tools（不要勾任何初始化）
# 3. 本机执行：
cd ~/ros1_ws/sim_tools
ssh -T git@gitee.com
git remote add gitee git@gitee.com:jinbo-liao/open_dog_sim_tools.git
git push -u gitee main
```

⚠️ **Gitee 坑**：默认分支叫 `master`，本地是 `main`。推完去「管理 → 默认分支」改成 `main`，
否则别人克隆下来是**空的**（会报 `remote HEAD refers to nonexistent ref`）。

**好处**：可以同时保留 GitHub 和 Gitee 两个远端，两条命令推两边：

```bash
git remote -v                  # 看有哪些远端
git push origin main           # 推到 GitHub
git push gitee main            # 推到 Gitee
```

### 方案：不用远程，直接拷

```bash
# 本机打包（约 92K）
cd ~/ros1_ws/sim_tools
git bundle create /tmp/sim_tools.bundle --all

# 拷到目标电脑后
cd ~/ros1_ws && git clone /tmp/sim_tools.bundle sim_tools
# 以后更新
cd ~/ros1_ws/sim_tools && git pull /tmp/sim_tools.bundle main
```

零配置、不需要账号，缺点是没网页界面。

---

## 九、速查表（打印贴桌上）

```bash
# ── 日常 ─────────────────────────────
cd ~/ros1_ws/sim_tools
git status                    # 看改了啥
git diff                      # 看具体改动
git add -A                    # 全部暂存
git commit -m "说明"           # 存档
git push                      # 传 GitHub

# ── 同步 ─────────────────────────────
git pull                      # 其他电脑：拉最新
git clone git@github.com:jinbo-liao/open_dog_sim_tools.git sim_tools   # 首次

# ── 撤销 ─────────────────────────────
git checkout -- 文件名         # 撤销未提交的改动（危险，先 git diff）
git revert <提交号>            # 撤销已提交的改动（安全）
git reset --soft HEAD~1       # 撤销最后一次 commit，保留改动

# ── 查看 ─────────────────────────────
git log --oneline             # 提交历史
git log --oneline -5          # 最近 5 条
git show <提交号>              # 看某个提交的详情
git diff <版本1> <版本2>        # 对比两个版本
git branch -a                 # 看所有分支

# ── 排错 ─────────────────────────────
ssh -T git@github.com         # 验证 GitHub 连通
git check-ignore -v 文件名     # 查为什么文件被忽略
git remote -v                 # 看远端地址
git reflog                    # 找回误删的提交
```

---

## 十、这个仓库的特殊情况

### ⚠️ 有重复文件

工具包的**顶层**和 **`scripts/` 目录下**存在同名且内容相同的文件：

```
walk_test.sh   ≡  scripts/walk_test.sh
run_scene.sh   ≡  scripts/run_scene.sh
gait_bridge.py ≡  scripts/gait_bridge.py
...（共 20 多个）
```

这是历史遗留（早期复制出来的）。**不影响使用**，但：

- **改代码时要两处都改**，否则会不一致
- 或者只在 `scripts/` 下改，然后把顶层那份删掉

**想清理的话**（确认顶层那份没被引用后）：

```bash
cd ~/ros1_ws/sim_tools
grep -rn 'walk_test.sh' --include='*.sh' --include='*.py' .   # 先查引用
git rm walk_test.sh run_scene.sh gait_bridge.py              # 按需列出
git commit -m "删除与 scripts/ 重复的顶层文件"
```

> ⚠️ **不确定就先别删。** 删错了用 `git checkout -- 文件名` 能救回来。

### 仓库里有什么

| 内容 | 说明 |
|---|---|
| 106 个文件 | 脚本 + 场景 + 配置 + 文档 |
| `.git` 目录 | 约 880K（版本历史） |
| 分支 | 只有 `main` |

### 相关文档

| 文档 | 内容 |
|---|---|
| `README.md` | 工具包总体说明 |
| `README.md` §0.5 | 移植到别的电脑（整套环境） |
| `README.md` §0.7 / §0.8 | git 管理 / GitHub 教程 |
| `PORTABLE-HOWTO.md` | 可移植性打包说明 |
| **本文档** | git 使用完整手册 |

---

## 附录：一张图看懂所有命令

```
                      你在这里改文件
                            │
                            │ ① git status / git diff   （看改了啥）
                            ▼
        ┌───────────────────────────────────┐
        │           工作区                   │
        └───────────────────────────────────┘
                            │
                            │ ② git add -A              （加入暂存）
                            ▼
        ┌───────────────────────────────────┐
        │           暂存区                   │
        └───────────────────────────────────┘
                            │
                            │ ③ git commit -m "说明"     （存档 ← 这里就能回退了）
                            ▼
        ┌───────────────────────────────────┐
        │          本地仓库                   │   ← git log 看历史
        │   （所有历史版本都在这里）           │   ← git checkout -- 撤销
        └───────────────────────────────────┘
                            │
                            │ ④ git push                （传到云端）
                            ▼
        ┌───────────────────────────────────┐
        │      GitHub / Gitee 远程仓库        │
        └───────────────────────────────────┘
                            │
                            │ ⑤ git pull                （其他电脑拉更新）
                            ▼
                     其他电脑的工作区
```
