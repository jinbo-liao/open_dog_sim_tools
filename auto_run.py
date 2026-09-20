#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
auto_run.py —— 自动跑仿真 + 统计摔倒次数

原理
----
1. 订阅 /ground_truth/state （由 URDF 里 gazebo_ros_p3d 插件发布，见 gazebo.xacro）
   拿到机器人在 world 系下的绝对位姿（不需要改任何 C++ 代码）。
2. 两条判据判断"摔倒"：
     - 倾角：|roll| 或 |pitch| > 45°（正常站立时接近 0）
     - 高度：position.z < 0.15 m（正常站立约 0.35 m，dmgo 的 comHeight）
   异常持续 FALL_CONFIRM_TIME 秒才记为一次摔倒，避免抖动误判。
3. 按 --path 自动发 /cmd_vel 走一条路径（直线、矩形、S 形、随机、原地转）。
4. 结束时打印统计并写 CSV。

用法
----
# 前提：Gazebo + 控制器已经在跑（见 run_scene.sh）
python3 auto_run.py --path straight --duration 60 --speed 0.4 --gait trot
python3 auto_run.py --path rect     --duration 120 --speed 0.5
python3 auto_run.py --path random   --duration 180 --speed 0.6 --csv /tmp/fall_log.csv

注意：必须先切到 trot 之类的步态，stance 下机器人不走。
"""

import argparse
import csv
import math
import os
import random
import sys
import threading
import time

import rospy
from geometry_msgs.msg import Twist
from nav_msgs.msg import Odometry
from std_msgs.msg import Float32

# gait_bridge.py 与本文件同目录；确保能被 import
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# ---------------- 摔倒判据参数 ----------------
FALL_ROLL_PITCH_DEG = 45.0   # 倾角阈值（度）
FALL_HEIGHT_M = 0.15         # 高度阈值（米），低于此认为倒下
FALL_CONFIRM_TIME = 0.5      # 持续多久才算摔倒（秒），避免瞬时抖动误判
NORMAL_HEIGHT = 0.35         # 正常站立高度（dmgo 的 comHeight）

# ★ 起立宽限期（实测踩坑）：
#   机器人 spawn 在 z=0.5，落地后 controller 起来前，基座高度只有 ~0.12 m
#   （腿是蜷着的），低于 FALL_HEIGHT_M，会被误判成"一上来就摔了"。
#   所以：在基座高度【首次达到 STANDUP_HEIGHT_M 以上】之前，不判摔倒。
#   实测：DMGO 站好后 z ≈ 0.341，落地蜷腿时 z ≈ 0.12，故阈值取 0.25 很安全。
STANDUP_HEIGHT_M = 0.25      # z 超过此值 => 视为已站好，之后才开始判摔
STANDUP_TIMEOUT_S = 60.0     # 最多等这么久；超时则强制开始判摔


def quat_to_rpy(q):
    """四元数 -> (roll, pitch, yaw)，弧度"""
    x, y, z, w = q.x, q.y, q.z, q.w
    sinr_cosp = 2.0 * (w * x + y * z)
    cosr_cosp = 1.0 - 2.0 * (x * x + y * y)
    roll = math.atan2(sinr_cosp, cosr_cosp)
    sinp = 2.0 * (w * y - z * x)
    if abs(sinp) >= 1.0:
        pitch = math.copysign(math.pi / 2.0, sinp)
    else:
        pitch = math.asin(sinp)
    return roll, pitch


class FallMonitor(object):
    """订阅 ground_truth/state，统计摔倒"""

    def __init__(self):
        self.lock = threading.Lock()
        self.last_pose = None       # ((x,y,z), (roll,pitch,yaw), stamp)
        self.falls = []             # [dict]
        self._fall_start = None
        self._in_fall = False
        self._dist = 0.0
        self._prev_xy = None
        self._start_time = time.time()
        self.max_tilt_deg = 0.0     # 全程最大倾角（含未摔倒时刻）
        self.min_z = float('inf')   # 全程最低基座高度

        # 起立宽限期状态
        self._stood_up = False      # 是否已确认站好（之后才开始判摔）
        self._arm_time = None       # 开始判摔的时刻
        self.standup_time = None    # 实测"站好"发生在第几秒

        # gazebo_ros_p3d 发布 nav_msgs/Odometry 到 /ground_truth/state
        self.sub = rospy.Subscriber('/ground_truth/state', Odometry,
                                    self._cb, queue_size=10)

    def _cb(self, msg):
        p = msg.pose.pose.position
        o = msg.pose.pose.orientation
        roll, pitch = quat_to_rpy(o)
        now = time.time()

        with self.lock:
            self.last_pose = ((p.x, p.y, p.z), (roll, pitch), now)

            # 累计行走距离（XY 平面）
            if self._prev_xy is not None:
                d = math.hypot(p.x - self._prev_xy[0], p.y - self._prev_xy[1])
                if d < 1.0:          # 过滤 Gazebo reset 造成的跳变
                    self._dist += d
            self._prev_xy = (p.x, p.y)

            self._check_fall(p.x, p.y, p.z, roll, pitch, now)

    def armed(self, now=None):
        """是否已进入「开始判摔」阶段（给外部脚本判断用）"""
        return self._stood_up

    def _arm(self, now):
        """正式开启摔判断（起立完成，或等超时）"""
        if not self._stood_up:
            self._stood_up = True
            self._arm_time = now
            if self.standup_time is None:
                self.standup_time = now - self._start_time
            rospy.loginfo('[auto_run] 机器人已站好，从现在开始统计摔倒')

    def _check_fall(self, x, y, z, roll, pitch, now):
        roll_deg = math.degrees(roll)
        pitch_deg = math.degrees(pitch)

        # 记录极值（不管是否摔倒）
        tilt = max(abs(roll_deg), abs(pitch_deg))
        if tilt > self.max_tilt_deg:
            self.max_tilt_deg = tilt
        if z < self.min_z:
            self.min_z = z

        # ---------- 起立宽限期 ----------
        # 站好之前不判摔倒：spawn 落地时腿是蜷的，z 只有 ~0.12 m，
        # 会被高度判据误判成"刚开跑就摔了"（实测确认过这个假阳性）。
        if not self._stood_up:
            if z >= STANDUP_HEIGHT_M:
                self._arm(now)
            elif now - self._start_time >= STANDUP_TIMEOUT_S:
                rospy.logwarn('[auto_run] 等待起立超时(%.0fs)，强制开始判摔'
                              '（若此时 z 仍偏低，首次"摔倒"可能是起立失败）',
                              STANDUP_TIMEOUT_S)
                self._arm(now)
            return

        tilt_bad = (abs(roll_deg) > FALL_ROLL_PITCH_DEG or
                    abs(pitch_deg) > FALL_ROLL_PITCH_DEG)
        height_bad = z < FALL_HEIGHT_M
        abnormal = tilt_bad or height_bad

        if abnormal:
            if self._fall_start is None:
                self._fall_start = now
            elif (not self._in_fall) and (now - self._fall_start) >= FALL_CONFIRM_TIME:
                self._in_fall = True
                reason = []
                if tilt_bad:
                    reason.append('tilt(roll=%.1f,pitch=%.1f)' % (roll_deg, pitch_deg))
                if height_bad:
                    reason.append('height(z=%.3f)' % z)
                self.falls.append({
                    'time': now - self._start_time,
                    'x': x, 'y': y, 'z': z,
                    'roll_deg': roll_deg, 'pitch_deg': pitch_deg,
                    'reason': ' '.join(reason),
                })
                rospy.logwarn('[FALL #%d] t=%.2fs pos=(%.2f,%.2f,%.3f) %s',
                              len(self.falls), now - self._start_time,
                              x, y, z, ' '.join(reason))
        else:
            self._fall_start = None
            self._in_fall = False

    def get_pose(self):
        with self.lock:
            return self.last_pose

    def get_stats(self):
        with self.lock:
            return {'duration': time.time() - self._start_time,
                    'distance': self._dist,
                    'max_tilt_deg': self.max_tilt_deg,
                    'min_z': 0.0 if self.min_z == float('inf') else self.min_z,
                    'standup_time': self.standup_time,
                    'falls': list(self.falls)}

    def stop(self):
        self.sub.unregister()


class CmdVelWalker(object):
    """按预设路径自动发 /cmd_vel"""

    def __init__(self, speed, turn_speed):
        self.pub = rospy.Publisher('/cmd_vel', Twist, queue_size=10)
        self.speed = speed
        self.turn_speed = turn_speed

    def send(self, vx, vy=0.0, wz=0.0):
        t = Twist()
        t.linear.x = vx
        t.linear.y = vy
        t.linear.z = 0.0
        t.angular.z = wz
        self.pub.publish(t)

    def stop_robot(self):
        self.send(0.0, 0.0, 0.0)

    def run_path(self, path, duration):
        """每 0.1s 发一次速度指令，根据路径类型改变方向"""
        rate = rospy.Rate(10)
        t0 = time.time()
        seg = 0.0
        rnd_vx = self.speed
        rnd_vy = 0.0
        rnd_wz = 0.0

        while not rospy.is_shutdown() and (time.time() - t0) < duration:
            el = time.time() - t0

            if path == 'straight':
                self.send(self.speed, 0.0, 0.0)

            elif path == 'rect':
                # 每 7 秒一个周期：前 5 秒直走，后 2 秒原地转
                cycle = el % 7.0
                if cycle < 5.0:
                    self.send(self.speed, 0.0, 0.0)
                else:
                    self.send(0.0, 0.0, self.turn_speed)

            elif path == 'sine':
                # S 形：侧向速度随时间正弦变化
                vy = self.speed * 0.6 * math.sin(2.0 * math.pi * el / 6.0)
                self.send(self.speed, vy, 0.0)

            elif path == 'random':
                # 每 3 秒随机换一次方向
                if el - seg > 3.0:
                    seg = el
                    rnd_vx = random.uniform(0.2, 1.0) * self.speed
                    rnd_vy = random.uniform(-0.5, 0.5) * self.speed
                    rnd_wz = random.uniform(-0.5, 0.5) * self.turn_speed
                self.send(rnd_vx, rnd_vy, rnd_wz)

            elif path == 'spin':
                self.send(0.0, 0.0, self.turn_speed)

            else:
                self.send(self.speed, 0.0, 0.0)

            rate.sleep()

        self.stop_robot()


def print_report(stats, path, speed):
    n_fall = len(stats['falls'])
    dur = stats['duration']
    dist = stats['distance']

    print('\n' + '=' * 62)
    print('                仿真自动跑统计报告 (path=%s)' % path)
    print('=' * 62)
    print('  运行时长        : %.1f s' % dur)
    su = stats.get('standup_time')
    if su is not None:
        print('  起立耗时        : %.1f s (之前不判摔，避免误判)' % su)
    print('  行走距离        : %.2f m' % dist)
    print('  平均速度        : %.3f m/s (指令 %.2f)'
          % (dist / dur if dur > 0 else 0.0, speed))
    print('  摔倒次数        : %d' % n_fall)
    if dur > 0:
        print('  平均无摔倒时长  : %.1f s' % (dur / (n_fall + 1)))
        print('  摔倒频率        : %.3f 次/分钟' % (n_fall / dur * 60.0))
    # 全程姿态极值（即使用户没摔倒，也能看出"接近摔倒"的程度）
    print('  最大倾角        : %.1f deg' % stats.get('max_tilt_deg', 0.0))
    print('  最低高度        : %.3f m' % stats.get('min_z', 0.0))
    print('-' * 62)

    if n_fall > 0:
        print('  摔倒明细：')
        print('    %-8s %-24s %-14s %s' % ('时间(s)', '位置(x,y,z)', '姿态(deg)', '原因'))
        for f in stats['falls']:
            print('    %-8.2f (%6.2f,%6.2f,%5.2f)  r=%6.1f p=%6.1f  %s'
                  % (f['time'], f['x'], f['y'], f['z'],
                     f['roll_deg'], f['pitch_deg'], f['reason']))
    else:
        print('  ✓ 全程没有摔倒')
    print('=' * 62)


def write_csv(path_csv, stats):
    try:
        with open(path_csv, 'w', newline='') as fp:
            w = csv.writer(fp)
            w.writerow(['fall_index', 'time_s', 'x', 'y', 'z',
                        'roll_deg', 'pitch_deg', 'reason'])
            for i, f in enumerate(stats['falls'], 1):
                w.writerow([i, '%.3f' % f['time'], '%.4f' % f['x'],
                            '%.4f' % f['y'], '%.4f' % f['z'],
                            '%.2f' % f['roll_deg'], '%.2f' % f['pitch_deg'],
                            f['reason']])
        print('[auto_run] 摔倒记录已写入: %s' % path_csv)
    except IOError as e:
        print('[auto_run] 写 CSV 失败: %s' % e, file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description='自动跑仿真 + 统计摔倒次数')
    ap.add_argument('--path', default='straight',
                    choices=['straight', 'rect', 'sine', 'random', 'spin'],
                    help='行走路径类型')
    ap.add_argument('--duration', type=float, default=60.0, help='持续时间（秒）')
    ap.add_argument('--speed', type=float, default=0.4, help='前进速度 m/s')
    ap.add_argument('--turn-speed', type=float, default=1.0, help='转向速度 rad/s')
    ap.add_argument('--gait', default='trot',
                    help='开始时自动切换的步态（stance/trot/flying_trot/skipping/...）')
    ap.add_argument('--csv', default='', help='摔倒记录输出 CSV 路径')
    ap.add_argument('--no-gait', action='store_true', help='不自动切步态')
    args = ap.parse_args()

    rospy.init_node('auto_run', anonymous=True)

    # ---- 等待 ground_truth/state 出现 ----
    print('[auto_run] 等待 /ground_truth/state ...')
    monitor = FallMonitor()
    t_wait = time.time()
    while monitor.get_pose() is None:
        if time.time() - t_wait > 20.0:
            print('[auto_run] ERROR: 20 秒没收到 /ground_truth/state。\n'
                  '  请检查: (1) Gazebo 是否在跑 (2) URDF 里 p3d_base_controller 插件是否加载\n'
                  '  可用 `rostopic list | grep ground_truth` 确认话题名',
                  file=sys.stderr)
            sys.exit(1)
        time.sleep(0.2)

    pose = monitor.get_pose()
    print('[auto_run] 收到位姿: pos=(%.3f, %.3f, %.3f) 初始高度=%.3f m'
          % (pose[0][0], pose[0][1], pose[0][2], pose[0][2]))
    print('[auto_run] 摔倒判据: 倾角>%.0f° 或 高度<%.2f m (正常站立 %.2f m)'
          % (FALL_ROLL_PITCH_DEG, FALL_HEIGHT_M, NORMAL_HEIGHT))

    # ---- 自动切步态 ----
    # ★ 关键（实测踩坑）：OCS2 默认步态是 stance（四脚站着不动）。
    #   不切步态就发 /cmd_vel —— 机器人根本不会走，只会被推歪然后摔倒。
    #   正确做法：复用 gait_bridge.py 的解析逻辑，把 gait.info 里该步态翻译成
    #   ocs2_msgs/mode_schedule 消息，发到 /legged_robot_mpc_mode_schedule
    #   （latched 话题，由 gazebo 进程内的 legged_controller 订阅）。
    #   旧版本发的是 /gait_cmd_<name>（Float32）—— 那个话题根本不存在，是错的。
    if not args.no_gait and args.gait:
        try:
            from ocs2_msgs.msg import mode_schedule as ModeScheduleMsg
            import gait_bridge as gb
            gf = gb.find_gait_file()
            names, gaits = gb.parse_gait_file(gf)
            if args.gait not in gaits:
                print('[auto_run] 未知步态 %r，可用: %s' % (args.gait, ', '.join(names)))
            else:
                g = gaits[args.gait]
                ids = [gb.mode_id(m) for m in g['modeSequence']]
                times = list(g['switchingTimes'])
                if len(times) == len(ids):
                    times = times + [times[-1]]
                gp = rospy.Publisher('/legged_robot_mpc_mode_schedule',
                                     ModeScheduleMsg, queue_size=1, latch=True)
                m = ModeScheduleMsg()
                m.modeSequence = ids
                m.eventTimes = times
                time.sleep(0.5)
                for _ in range(3):
                    gp.publish(m)
                    time.sleep(0.3)
                print('[auto_run] 已切步态 -> %s (modeSequence=%s eventTimes=%s)'
                      % (args.gait, ids, times))
        except ImportError:
            print('[auto_run] 跳过切步态（缺 gait_bridge.py 或 ocs2_msgs）；'
                  '若机器人不动，手动在 gait_command 终端输入: %s' % args.gait)
        except Exception as e:
            print('[auto_run] 切步态出错: %s（继续跑，但可能机器人不走）' % e)
        time.sleep(1.5)

    # ---- 开始自动走 ----
    walker = CmdVelWalker(args.speed, args.turn_speed)
    print('[auto_run] 开始自动行走: path=%s duration=%.0fs speed=%.2f (Ctrl-C 提前结束)'
          % (args.path, args.duration, args.speed))

    try:
        walker.run_path(args.path, args.duration)
    except KeyboardInterrupt:
        print('\n[auto_run] 用户中断')
        walker.stop_robot()

    time.sleep(1.0)
    stats = monitor.get_stats()
    monitor.stop()

    print_report(stats, args.path, args.speed)
    if args.csv:
        write_csv(args.csv, stats)


if __name__ == '__main__':
    main()
