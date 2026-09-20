#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gait_bridge.py —— 不靠键盘，用话题直接切步态

为什么需要它（实测结论）
------------------------
OCS2 的 `legged_robot_gait_command` 内部用的是 `GaitKeyboardPublisher`，
它只从 **stdin** 读命令（源码：
ocs2_legged_robot_ros/src/gait/GaitKeyboardPublisher.cpp `getKeyboardCommand()`）。
但 `run_sim.sh` 是这样起的：
    roslaunch legged_controllers load_controller.launch > log 2>&1 &
stdin 不是 TTY，所以**永远收不到你敲的步态名**，机器人一直停在默认的
`stance`（四脚站着不动）。这就是"控制器 running、/cmd_vel 也在发，
但机器人不走"的真正原因。

关键发现
--------
`GaitKeyboardPublisher` 构造函数里注册了一个 **latched 话题**：
    modeSequenceTemplatePublisher_ =
      nodeHandle.advertise<ocs2_msgs::mode_schedule>(robotName + "_mpc_mode_schedule", 1, true);
即 `/legged_robot_mpc_mode_schedule`（类型 `ocs2_msgs/mode_schedule`）。
往这个话题发一条 mode_schedule，效果和键盘敲步态名**完全一样**，
而且不需要 TTY、不需要改 C++。

用法
----
    python3 gait_bridge.py --list                # 列出 gait.info 里所有步态
    python3 gait_bridge.py --gait trot           # 切到 trot
    python3 gait_bridge.py --gait trot --gait-file /path/to/gait.info
"""

import argparse
import os
import re
import sys
import time

import rospy
from ocs2_msgs.msg import mode_schedule

DEFAULT_ROBOT = os.environ.get('ROBOT_TYPE', 'dmgo')


def _ws_root():
    """工作区根目录；优先 WS_ROOT 环境变量，否则 $HOME/ros1_ws。
    可移植性：不写死用户名。"""
    return os.environ.get('WS_ROOT') or os.path.join(os.path.expanduser('~'), 'ros1_ws')


def find_gait_file(explicit=None):
    """按优先级找 gait.info（任意用户名/目录布局都能找到）"""
    if explicit:
        return explicit
    ws = _ws_root()
    robot = DEFAULT_ROBOT
    cands = [
        os.environ.get('GAIT_INFO', ''),
        # 环境变量 MSGS_DIR 指定的源码根
        os.path.join(os.environ.get('MSGS_DIR', ''), 'legged_controllers',
                     'config', robot, 'gait.info')
        if os.environ.get('MSGS_DIR') else '',
        # 工程里常见的两种布局
        os.path.join(ws, 'src/open_dog/legged_controllers/config', robot, 'gait.info'),
        os.path.join(ws, 'src/open-dog/legged_controllers/config', robot, 'gait.info'),
        os.path.join(ws, 'open-dog-master/src/代码/src/legged_controllers/config',
                     robot, 'gait.info'),
        os.path.join(ws, 'open-dog-master/src/legged_controllers/config',
                     robot, 'gait.info'),
    ]
    for c in cands:
        if c and os.path.isfile(c):
            return c
    # 兜底：问 ROS
    try:
        import subprocess
        pkg = subprocess.check_output(
            ['rospack', 'find', 'legged_controllers'],
            stderr=subprocess.DEVNULL).decode().strip()
        p = os.path.join(pkg, 'config', robot, 'gait.info')
        if os.path.isfile(p):
            return p
    except Exception:
        pass
    return None


def parse_gait_file(path):
    """
    解析 OCS2 的 gait.info（一种「类 info」文本）:
        list
        { stance, trot, ... }
        trot
         {
           modeSequence { [0] LF_RH  [1] RF_LH }
           switchingTimes { [0] 0.0  [1] 0.3  [2] 0.6 }
         }
    返回 (names, {gait: {'modeSequence': [...], 'switchingTimes': [...]}})
    """
    with open(path, 'r') as f:
        text = f.read()

    gaits = {}
    names = []
    m = re.search(r'\blist\b\s*\{(.*?)\}', text, re.S)
    if m:
        # list 段里除了名字还有 [0] [1] 这类下标，要滤掉
        raw = re.split(r'[,\s]+', m.group(1))
        names = [w for w in raw if w and not re.fullmatch(r'\[\s*\d+\s*\]', w)]

    for name in names:
        pat = re.compile(r'(?m)^\s*' + re.escape(name) + r'\s*\{')
        mm = pat.search(text)
        if not mm:
            continue
        seg = text[mm.end():]
        ms = re.search(r'modeSequence\s*\{(.*?)\}', seg, re.S)
        st = re.search(r'switchingTimes\s*\{(.*?)\}', seg, re.S)
        if not ms or not st:
            continue
        modes = re.findall(r'\[\s*\d+\s*\]\s*([A-Za-z_][A-Za-z0-9_]*)', ms.group(1))
        times = [float(t) for t in
                 re.findall(r'\[\s*\d+\s*\]\s*([-+0-9.eE]+)', st.group(1))]
        if modes and times:
            gaits[name] = {'modeSequence': modes, 'switchingTimes': times}
    return names, gaits


# OCS2 接触模式编号（见 ocs2_legged_robot/include/.../gait/ModeNumber.h）
MODE_MAP = {
    'STANCE': 0,
    'LF_RH': 1, 'RF_LH': 2, 'LF_LH': 3, 'RF_RH': 4,
    'LF_RF_RH': 5, 'RF_LH_RH': 6, 'LF_RF_LH': 7, 'LF_LH_RH': 8,
    'LF_RF': 9, 'LH_RH': 10,
    'FLY': 11,
}


def mode_id(name):
    """步态模式名 -> 整数编号"""
    key = name.strip().upper()
    if key in MODE_MAP:
        return MODE_MAP[key]
    # 未知名字：按「支撑腿集合」兜底推断
    legs = frozenset(t for t in key.split('_') if t in ('LF', 'RF', 'LH', 'RH'))
    combos = {
        frozenset(): 0,
        frozenset({'LF', 'RH'}): 1,
        frozenset({'RF', 'LH'}): 2,
        frozenset({'LF', 'LH'}): 3,
        frozenset({'RF', 'RH'}): 4,
        frozenset({'LF', 'RF', 'RH'}): 5,
        frozenset({'RF', 'LH', 'RH'}): 6,
        frozenset({'LF', 'RF', 'LH'}): 7,
        frozenset({'LF', 'LH', 'RH'}): 8,
        frozenset({'LF', 'RF'}): 9,
        frozenset({'LH', 'RH'}): 10,
    }
    if legs in combos:
        return combos[legs]
    raise KeyError('不认识步态模式名: %r（已知: %s）' % (name, sorted(MODE_MAP)))


def main():
    ap = argparse.ArgumentParser(
        description='用话题切换 OCS2 步态（不需要键盘/TTY）')
    ap.add_argument('--gait', help='要切换到的步态名，如 trot / dynamic_walk')
    ap.add_argument('--list', action='store_true', help='只列出可用步态')
    ap.add_argument('--gait-file', default=None, help='gait.info 路径（默认自动查找）')
    ap.add_argument('--robot-name', default='legged_robot',
                    help='话题前缀（默认 -> /legged_robot_mpc_mode_schedule）')
    ap.add_argument('--repeat', type=int, default=3, help='重复发布次数（默认 3）')
    args = ap.parse_args()

    gf = find_gait_file(args.gait_file)
    if not gf:
        print('[gait_bridge] 找不到 gait.info，请用 --gait-file 指定', file=sys.stderr)
        return 1
    print('[gait_bridge] gait.info: %s' % gf)

    names, gaits = parse_gait_file(gf)
    print('[gait_bridge] 可用步态(%d): %s' % (len(names), ', '.join(names)))

    if args.list or not args.gait:
        for n in names:
            g = gaits.get(n)
            if g:
                print('  %-16s modes=%s times=%s'
                      % (n, g['modeSequence'], g['switchingTimes']))
        return 0

    if args.gait not in gaits:
        print('[gait_bridge] 未知步态 %r，可用: %s'
              % (args.gait, ', '.join(names)), file=sys.stderr)
        return 1

    g = gaits[args.gait]
    try:
        ids = [mode_id(m) for m in g['modeSequence']]
    except KeyError as e:
        print('[gait_bridge] %s' % e, file=sys.stderr)
        return 1

    rospy.init_node('gait_bridge', anonymous=True)
    topic = '/%s_mpc_mode_schedule' % args.robot_name
    pub = rospy.Publisher(topic, mode_schedule, queue_size=1, latch=True)

    msg = mode_schedule()
    msg.modeSequence = ids
    times = list(g['switchingTimes'])
    # OCS2 约定：eventTimes 比 modeSequence 多一个（最后一个是周期结束时刻）
    # 字段名来自 ocs2_msgs/msg/mode_schedule.msg: float64[] eventTimes / int8[] modeSequence
    if len(times) == len(msg.modeSequence):
        times = times + [times[-1]]
    msg.eventTimes = times

    # 等 MPC 订阅上（latched 也要有订阅者才能收到）
    # 注意：实测在只跑 python 节点时 get_num_connections() 有时显示 0，
    #       但消息其实已经被 gazebo 进程内的 controller 收到（用 rostopic info 可验证）。
    #       所以这里只做「提示」，不因为 0 就放弃发布。
    t0 = time.time()
    while pub.get_num_connections() == 0 and not rospy.is_shutdown():
        if time.time() - t0 > 5:
            print('[gait_bridge] 提示: 未检测到订阅者（不影响发送）；'
                  '可另开终端用 rostopic info 核对', file=sys.stderr)
            break
        rospy.sleep(0.2)

    for _ in range(max(1, args.repeat)):
        pub.publish(msg)
        try:
            rospy.sleep(0.3)
        except rospy.exceptions.ROSInterruptException:
            break  # 节点被 Ctrl-C / timeout 关掉，消息已经发出去了，不算错

    print('[gait_bridge] 已发布 -> %s' % topic)
    print('[gait_bridge]   %s: modeSequence=%s eventTimes=%s'
          % (args.gait, ids, times))
    print('[gait_bridge]   订阅者数=%d' % pub.get_num_connections())
    try:
        rospy.sleep(0.5)
    except rospy.exceptions.ROSInterruptException:
        pass
    return 0


if __name__ == '__main__':
    sys.exit(main())

