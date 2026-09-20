#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gait_check.py —— 验证「步态切换是否真的生效」

原理
----
OCS2 的控制器会把「四条腿当前是否触地」发到
    /controllers/legged_controller/contacti_flag   (std_msgs/Int16MultiArray)
stance（默认）时四脚一直触地（flags 全是 1，纹丝不动）；
一旦切到 trot，flags 会按步态周期（trot = 0.6 s）在
「LF+RH 抬 / RF+LH 抬」之间交替。
所以统计 flags 的变化次数就能判定步态到底有没有切成功。

用法（容器内）:
    python3 gait_check.py                 # 量当前状态
    python3 gait_check.py --gait trot     # 先切 trot 再量
"""
import argparse
import sys
import time

import rospy
from std_msgs.msg import Float64MultiArray


class ContactMonitor(object):
    def __init__(self):
        self.samples = []
        rospy.Subscriber('/controllers/legged_controller/contacti_flag',
                         Float64MultiArray, self._cb, queue_size=200)

    def _cb(self, msg):
        # 归一成 0/1 的整数元组，方便比较
        self.samples.append(tuple(int(round(v)) for v in msg.data))


def summarise(samples):
    """统计触地 flags 的变化"""
    if not samples:
        return None
    n = len(samples)
    changed = 0
    patterns = {}
    for i in range(1, n):
        if samples[i] != samples[i - 1]:
            changed += 1
    for s in samples:
        patterns[s] = patterns.get(s, 0) + 1
    return n, changed, patterns


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--gait', default=None, help='先切到这个步态再量')
    ap.add_argument('--duration', type=float, default=4.0)
    args = ap.parse_args()

    rospy.init_node('gait_check', anonymous=True)

    if args.gait:
        # 可移植：优先环境变量，其次本脚本所在目录
        _sd = os.environ.get('C_TOOLS_DIR') or '/home/%s/sim_tools' % os.environ.get('USER', '')
        for _c in (os.environ.get('SIM_TOOLS_SCRIPTS'),
                   os.path.join(_sd, 'scripts'),
                   os.path.dirname(os.path.abspath(__file__))):
            if _c and os.path.isdir(_c) and _c not in sys.path:
                sys.path.insert(0, _c)
        import gait_bridge as gb
        from ocs2_msgs.msg import mode_schedule as ModeScheduleMsg
        gf = gb.find_gait_file()
        names, gaits = gb.parse_gait_file(gf)
        g = gaits[args.gait]
        ids = [gb.mode_id(m) for m in g['modeSequence']]
        times = list(g['switchingTimes'])
        if len(times) == len(ids):
            times = times + [times[-1]]
        pub = rospy.Publisher('/legged_robot_mpc_mode_schedule',
                              ModeScheduleMsg, queue_size=1, latch=True)
        m = ModeScheduleMsg()
        m.modeSequence = ids
        m.eventTimes = times
        time.sleep(1.0)
        for _ in range(4):
            pub.publish(m)
            time.sleep(0.3)
        print('[gait_check] 已切 %s -> modeSequence=%s eventTimes=%s'
              % (args.gait, ids, times))
        time.sleep(1.5)

    mon = ContactMonitor()
    print('[gait_check] 采样 %.1f 秒（看四腿触地标志）...' % args.duration)
    t0 = time.time()
    while time.time() - t0 < args.duration and not rospy.is_shutdown():
        time.sleep(0.05)

    r = summarise(mon.samples)
    if r is None:
        print('[gait_check] 没收到 contacti_flag —— 控制器可能没在跑')
        return 2
    n, changed, patterns = r
    print()
    print('采样点数        : %d' % n)
    print('触地状态变化次数: %d' % changed)
    print('出现过的触地组合:')
    for k, v in sorted(patterns.items(), key=lambda kv: -kv[1]):
        print('   %-14s x%d' % (str(k), v))
    print('-' * 46)
    if changed >= 4:
        print('=> 判定：步态【生效】—— 腿在交替抬起/落下')
    elif changed >= 1:
        print('=> 判定：有切换但不频繁，可能是过渡或负载变化')
    else:
        print('=> 判定：四脚一直触地 =stance，步态【没切成功】')
        print('   （若刚启动，先确认控制器已 running 再来测）')
    return 0


if __name__ == '__main__':
    sys.exit(main())
