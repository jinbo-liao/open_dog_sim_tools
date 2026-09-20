#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
jump_demo.py —— 尝试让机器人在 Gazebo 里"跳起来"

为什么需要这个脚本
------------------
切步态（比如 flying_trot）只改变"哪几条腿着地"的时序，
MPC 仍然认为基座高度由地面约束决定 —— 所以腿会做收腿动作，
但身体不会真正离地。要真正跳起来，需要给基座一个向上的速度指令。

TargetTrajectoriesPublisher.cpp 的 cmdVelToTargetTrajectories() 里：
    cmdVel[0..2] = linear.x/y/z   → 对应基座的线速度
    cmdVel[3]    = angular.z
而 TargetTrajectoriesPublisher.h 的 cmdVelCallback() 读的是：
    cmdVel[0] = msg->linear.x
    cmdVel[1] = msg->linear.y
    cmdVel[2] = msg->linear.z     ← 这个就是"向上速度"！
    cmdVel[3] = msg->angular.z

也就是说：**只要发带线性 z 分量的 /cmd_vel，就能尝试让机器人向上**。
（地面约束仍在，所以这是"弹跳"，不是"飞行"。）

用法
----
# 前提：Gazebo + 控制器在跑，且已切到 trot/flying_trot
python3 jump_demo.py --hops 5 --vz 1.5
python3 jump_demo.py --hops 3 --vz 2.5 --vx 0.3   # 边跳边前进

观察：
  统计脚本 auto_run.py 里 z 高度会有明显抬升→回落。
"""

import argparse
import time

import rospy
from geometry_msgs.msg import Twist
from nav_msgs.msg import Odometry

# 弹跳参数
LIFT_TIME = 0.25     # 向上推的时间（秒）
FALL_TIME = 0.35     # 回落时间（秒）
REST_TIME = 0.5      # 两次弹跳之间的停顿（秒）


class JumpDemo(object):
    def __init__(self):
        self.pub = rospy.Publisher('/cmd_vel', Twist, queue_size=10)
        self.max_z = -999.0
        self.min_z = 999.0
        self.base_z = None
        self.sub = rospy.Subscriber('/ground_truth/state', Odometry,
                                    self._cb, queue_size=10)

    def _cb(self, msg):
        z = msg.pose.pose.position.z
        if self.base_z is None:
            self.base_z = z
        self.max_z = max(self.max_z, z)
        self.min_z = min(self.min_z, z)

    def send(self, vx=0.0, vy=0.0, vz=0.0, wz=0.0):
        t = Twist()
        t.linear.x = vx
        t.linear.y = vy
        t.linear.z = vz
        t.angular.z = wz
        self.pub.publish(t)


def main():
    ap = argparse.ArgumentParser(description='让机器人尝试弹跳')
    ap.add_argument('--hops', type=int, default=5, help='弹跳次数')
    ap.add_argument('--vz', type=float, default=1.5, help='向上速度 m/s（越大跳越高）')
    ap.add_argument('--vx', type=float, default=0.0, help='同时前进速度 m/s')
    ap.add_argument('--rate', type=float, default=50.0, help='发布频率 Hz')
    args = ap.parse_args()

    rospy.init_node('jump_demo', anonymous=True)
    jd = JumpDemo()

    print('[jump] 等待 /ground_truth/state ...')
    t0 = time.time()
    while jd.base_z is None and time.time() - t0 < 20.0:
        time.sleep(0.2)
    if jd.base_z is None:
        print('[jump] ERROR: 收不到位姿，Gazebo 是否在跑？')
        return

    print('[jump] 基准高度 z = %.3f m' % jd.base_z)
    print('[jump] 参数: hops=%d vz=%.2f vx=%.2f' % (args.hops, args.vz, args.vx))
    print('[jump] 注意：先确认已切到 trot/flying_trot，否则不会跳。')

    rate = rospy.Rate(args.rate)

    for i in range(args.hops):
        if rospy.is_shutdown():
            break
        print('[jump] 第 %d/%d 跳 ...' % (i + 1, args.hops))

        # --- 向上推 ---
        t_end = time.time() + LIFT_TIME
        while time.time() < t_end and not rospy.is_shutdown():
            jd.send(vx=args.vx, vz=args.vz)
            rate.sleep()

        # --- 回落（不给向上速度，给一点向前）---
        t_end = time.time() + FALL_TIME
        while time.time() < t_end and not rospy.is_shutdown():
            jd.send(vx=args.vx, vz=0.0)
            rate.sleep()

        # --- 停一下 ---
        t_end = time.time() + REST_TIME
        while time.time() < t_end and not rospy.is_shutdown():
            jd.send(vx=0.0, vz=0.0)
            rate.sleep()

    # 收尾：确保速度归零
    for _ in range(10):
        jd.send(0.0, 0.0, 0.0)
        rate.sleep()

    print('\n[jump] 完成。')
    print('[jump] 高度统计: min=%.3f  max=%.3f  基准=%.3f  → 最大抬升=%.3f m'
          % (jd.min_z, jd.max_z, jd.base_z, jd.max_z - jd.base_z))
    if jd.max_z - jd.base_z < 0.02:
        print('[jump] 抬升很小，说明没跳起来。可能原因：')
        print('       - 没切到 trot/flying_trot（还在 stance）')
        print('       - vz 太小，试 --vz 3.0')
        print('       - 地面约束太强，MPC 不允许基座离开地面高度')
        print('       → 需要改 reference.info 的 comHeight 或加跳跃专用参考轨迹')


if __name__ == '__main__':
    main()
