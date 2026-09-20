#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_fall_logic.py —— 不依赖 ROS 的摔倒判定逻辑单元测试

用途：验证 auto_run.py 里的 quat_to_rpy / 摔倒判据是否正确，
      不需要启动 Gazebo。

运行：
    python3 test_fall_logic.py
"""

import math
import os
import sys

# 让 import 能找到 auto_run.py
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# auto_run.py 顶部 import rospy 和 ROS 消息类型。
# 为了让本测试在【没有 ROS 的机器上也能跑】，这里注入最小 stub。
# 在容器内（有 ROS）跑时，真实模块已存在，stub 不会生效。
try:
    import rospy                      # noqa: F401
except ImportError:
    import types

    class _Msg(object):
        def __init__(self, *a, **kw):
            pass

    def _make_stub(name, attrs):
        m = types.ModuleType(name)
        for a in attrs:
            setattr(m, a, type(a, (_Msg,), {}))
        sys.modules[name] = m

    rospy_stub = types.ModuleType('rospy')
    rospy_stub.Subscriber = lambda *a, **kw: None
    rospy_stub.Publisher = lambda *a, **kw: None
    rospy_stub.init_node = lambda *a, **kw: None
    rospy_stub.Rate = lambda *a, **kw: None
    rospy_stub.is_shutdown = lambda: False
    rospy_stub.logwarn = lambda *a, **kw: None
    rospy_stub.loginfo = lambda *a, **kw: None
    rospy_stub.logerr = lambda *a, **kw: None
    rospy_stub.logdebug = lambda *a, **kw: None
    rospy_stub.sleep = lambda *a, **kw: None
    rospy_stub.get_time = lambda: 0.0
    sys.modules['rospy'] = rospy_stub

    _make_stub('geometry_msgs.msg', ['Twist'])
    _make_stub('nav_msgs.msg', ['Odometry'])
    _make_stub('std_msgs.msg', ['Float32'])
    _make_stub('geometry_msgs', [])
    _make_stub('nav_msgs', [])
    _make_stub('std_msgs', [])
    print('[test] 未检测到 ROS，已注入 rospy stub（只测数学逻辑）')

try:
    import auto_run as ar
except ImportError as e:
    print('[test] 无法导入 auto_run：%s' % e)
    sys.exit(1)


class FakeQuat(object):
    def __init__(self, x, y, z, w):
        self.x, self.y, self.z, self.w = x, y, z, w


def euler_to_quat(roll, pitch, yaw):
    """ZYX 顺序的欧拉角 -> 四元数"""
    cy, sy = math.cos(yaw * 0.5), math.sin(yaw * 0.5)
    cp, sp = math.cos(pitch * 0.5), math.sin(pitch * 0.5)
    cr, sr = math.cos(roll * 0.5), math.sin(roll * 0.5)
    w = cr * cp * cy + sr * sp * sy
    x = sr * cp * cy - cr * sp * sy
    y = cr * sp * cy + sr * cp * sy
    z = cr * cp * sy - sr * sp * cy
    return FakeQuat(x, y, z, w)


def approx(a, b, tol=1e-6):
    return abs(a - b) < tol


def make_monitor(stood_up=True):
    """
    构造一个绕过 __init__ 的 FallMonitor（不建 ROS 订阅），
    并把所有内部字段初始化好 —— 等价于 __init__ 里做的事情。

    stood_up=True：直接进入「已站好、开始判摔」状态（多数测试的默认前提），
                   这样测试用的 0.35 m 站立高度不会被起立宽限期拦住。
    stood_up=False：停在起立宽限期，用于专门测宽限期的用例。
    """
    m = ar.FallMonitor.__new__(ar.FallMonitor)
    m._fall_start = None
    m._in_fall = False
    m.falls = []
    m._start_time = 0.0
    m.max_tilt_deg = 0.0
    m.min_z = float('inf')
    # 起立宽限期字段（与 __init__ 保持一致）
    m._stood_up = stood_up
    m._arm_time = 0.0 if stood_up else None
    m.standup_time = 0.0 if stood_up else None
    return m


def test_quat_identity():
    """单位四元数 -> roll/pitch 全为 0"""
    roll, pitch = ar.quat_to_rpy(FakeQuat(0, 0, 0, 1))
    assert approx(roll, 0.0), 'identity roll 应为 0，得到 %f' % roll
    assert approx(pitch, 0.0), 'identity pitch 应为 0，得到 %f' % pitch
    print('  ✓ 单位四元数 -> roll=pitch=0')


def test_quat_roll_90():
    """绕 x 轴转 90° -> roll = 90°"""
    q = euler_to_quat(math.radians(90), 0, 0)
    roll, pitch = ar.quat_to_rpy(q)
    assert approx(roll, math.radians(90), 1e-5), 'roll 应为 90°，得到 %f' % math.degrees(roll)
    assert approx(pitch, 0.0, 1e-5), 'pitch 应为 0，得到 %f' % math.degrees(pitch)
    print('  ✓ 绕 x 转 90° -> roll=90°')


def test_quat_pitch_60():
    """绕 y 轴转 60° -> pitch = 60°"""
    q = euler_to_quat(0, math.radians(60), 0)
    roll, pitch = ar.quat_to_rpy(q)
    assert approx(pitch, math.radians(60), 1e-5), 'pitch 应为 60°，得到 %f' % math.degrees(pitch)
    print('  ✓ 绕 y 转 60° -> pitch=60°')


def test_standing_not_fall():
    """正常站立：高度 0.35、姿态水平 -> 不算摔倒"""
    m = make_monitor()

    for t in [0.1, 0.5, 1.0, 2.0]:
        m._check_fall(0.0, 0.0, 0.35, 0.0, 0.0, t)

    assert len(m.falls) == 0, '正常站立不应判为摔倒，却记了 %d 次' % len(m.falls)
    print('  ✓ 正常站立（z=0.35, 水平）-> 0 次摔倒')


def test_tilt_detected():
    """倾角 60° 持续 0.6s -> 判为一次摔倒"""
    m = make_monitor()

    roll = math.radians(60)
    m._check_fall(0.0, 0.0, 0.35, roll, 0.0, 1.0)      # 开始异常
    m._check_fall(0.0, 0.0, 0.35, roll, 0.0, 1.7)      # 0.7s > 0.5s，确认摔倒

    assert len(m.falls) == 1, '倾角 60° 应判 1 次摔倒，得到 %d' % len(m.falls)
    assert 'tilt' in m.falls[0]['reason'], '原因应含 tilt，得到 %s' % m.falls[0]['reason']
    print('  ✓ 倾角 60° 持续 0.7s -> 1 次摔倒 (reason=%s)' % m.falls[0]['reason'])


def test_low_height_detected():
    """高度 0.05m -> 判为摔倒"""
    m = make_monitor()

    m._check_fall(1.0, 2.0, 0.05, 0.0, 0.0, 1.0)
    m._check_fall(1.0, 2.0, 0.05, 0.0, 0.0, 1.7)

    assert len(m.falls) == 1, '高度 0.05m 应判 1 次摔倒，得到 %d' % len(m.falls)
    assert 'height' in m.falls[0]['reason'], '原因应含 height，得到 %s' % m.falls[0]['reason']
    print('  ✓ 高度 0.05m -> 1 次摔倒 (reason=%s)' % m.falls[0]['reason'])


def test_brief_tilt_not_fall():
    """瞬时倾角 0.1s 就恢复 -> 不判摔倒（避免抖动误判）"""
    m = make_monitor()

    roll = math.radians(60)
    m._check_fall(0.0, 0.0, 0.35, roll, 0.0, 1.0)   # 异常开始
    m._check_fall(0.0, 0.0, 0.35, 0.0, 0.0, 1.1)    # 0.1s 就恢复

    assert len(m.falls) == 0, '瞬时倾角不应判摔倒，却记了 %d 次' % len(m.falls)
    print('  ✓ 瞬时倾角 0.1s 恢复 -> 0 次摔倒（抗抖动）')


def test_multiple_falls():
    """摔倒 -> 恢复 -> 再摔倒，应记 2 次"""
    m = make_monitor()

    roll = math.radians(70)
    # 第一次摔倒
    m._check_fall(0.0, 0.0, 0.35, roll, 0.0, 1.0)
    m._check_fall(0.0, 0.0, 0.35, roll, 0.0, 1.7)
    # 恢复
    m._check_fall(0.0, 0.0, 0.35, 0.0, 0.0, 2.0)
    # 第二次摔倒
    m._check_fall(0.0, 0.0, 0.35, roll, 0.0, 3.0)
    m._check_fall(0.0, 0.0, 0.35, roll, 0.0, 3.7)

    assert len(m.falls) == 2, '应记 2 次摔倒，得到 %d' % len(m.falls)
    assert m.falls[0]['time'] < m.falls[1]['time'], '摔倒时间应递增'
    print('  ✓ 摔倒→恢复→再摔倒 -> 2 次，时间递增 (%.1fs, %.1fs)'
          % (m.falls[0]['time'], m.falls[1]['time']))


def test_max_tilt_tracked():
    """最大倾角应记录全程极值，即使没到摔倒阈值"""
    m = make_monitor()
    # 20°（不摔倒）和 30°（不摔倒），但都比 0 大
    m._check_fall(0.0, 0.0, 0.35, math.radians(20), 0.0, 1.0)
    m._check_fall(0.0, 0.0, 0.35, 0.0, math.radians(-30), 1.5)

    assert approx(m.max_tilt_deg, 30.0, 1e-4), \
        '最大倾角应记 30°，得到 %.2f' % m.max_tilt_deg
    assert len(m.falls) == 0, '未超阈值不应记摔倒'
    print('  ✓ 最大倾角跟踪 -> %.1f°（未摔倒但记录了极值）' % m.max_tilt_deg)


def test_min_z_tracked():
    """最低高度应记录全程极小值"""
    m = make_monitor()
    m._check_fall(0.0, 0.0, 0.35, 0.0, 0.0, 1.0)
    m._check_fall(0.0, 0.0, 0.28, 0.0, 0.0, 1.5)
    m._check_fall(0.0, 0.0, 0.31, 0.0, 0.0, 2.0)

    assert approx(m.min_z, 0.28, 1e-6), \
        '最低高度应记 0.28，得到 %.3f' % m.min_z
    print('  ✓ 最低高度跟踪 -> %.3f m' % m.min_z)


def test_extremes_not_disturbed_by_fall():
    """摔倒时极值也应正确更新（摔倒那一刻通常是极值）"""
    m = make_monitor()
    roll = math.radians(80)          # 远超 45° 阈值
    m._check_fall(0.0, 0.0, 0.60, roll, 0.0, 1.0)
    m._check_fall(0.0, 0.0, 0.60, roll, 0.0, 1.7)
    m._check_fall(0.0, 0.0, 0.05, roll, 0.0, 2.0)

    assert len(m.falls) >= 1, '应至少记 1 次摔倒'
    assert approx(m.max_tilt_deg, 80.0, 1e-4), \
        '最大倾角应为 80°，得到 %.2f' % m.max_tilt_deg
    assert approx(m.min_z, 0.05, 1e-6), \
        '最低高度应为 0.05，得到 %.3f' % m.min_z
    print('  ✓ 摔倒同时更新极值 (tilt=%.0f°, min_z=%.3f m)'
          % (m.max_tilt_deg, m.min_z))


def test_grace_period_no_false_fall():
    """
    ★ 回归测试（实测踩过的假阳性）：
    机器人刚 spawn 落地、控制器还没把它撑起来时，基座高度只有 ~0.12 m，
    低于 FALL_HEIGHT_M(0.15)。改动前会被误判成「一上来就摔了」。
    起立宽限期生效后，这种低位状态不应记为摔倒。
    """
    m = make_monitor(stood_up=False)     # 还没站好
    # 蜷腿落地阶段：z 一直在 0.12 附近，持续 5 秒
    for i in range(11):
        m._check_fall(0.0, 0.0, 0.120, 0.0, 0.0, i * 0.5)

    assert not m.armed(), '还没站好就不该开始判摔'
    assert len(m.falls) == 0, \
        '起立宽限期内不应记摔倒，实际记了 %d 次' % len(m.falls)
    print('  ✓ 起立宽限期不误判（低位 5s 未记摔倒）')


def test_grace_period_arms_then_detects():
    """
    站好（z 超过 STANDUP_HEIGHT_M）之后，宽限期结束，
    此后再出现低位就应该正常判为摔倒。
    """
    m = make_monitor(stood_up=False)
    # 蜷腿 -> 撑起来（0.35 > 0.25 阈值）
    m._check_fall(0.0, 0.0, 0.120, 0.0, 0.0, 0.5)
    m._check_fall(0.0, 0.0, 0.350, 0.0, 0.0, 1.0)

    assert m.armed(), '高度到 0.35 后应开始判摔'
    assert approx(m.standup_time, 1.0, 1e-6), \
        '起立时刻应记为 1.0s，得到 %s' % m.standup_time

    # 站好后真的摔下去
    m._check_fall(0.0, 0.0, 0.050, 0.0, 0.0, 2.0)
    m._check_fall(0.0, 0.0, 0.050, 0.0, 0.0, 2.7)
    assert len(m.falls) == 1, '站好后低位应记 1 次摔倒，得到 %d' % len(m.falls)
    print('  ✓ 站好后正常判摔（起立@%.1fs，摔倒@%.1fs）'
          % (m.standup_time, m.falls[0]['time']))


def test_grace_period_timeout():
    """
    一直站不起来（永远低位）：等满 STANDUP_TIMEOUT_S 后强制开始判摔，
    这样「起立失败」也能被记录，而不是永远假装没事。
    """
    m = make_monitor(stood_up=False)
    m._check_fall(0.0, 0.0, 0.120, 0.0, 0.0, ar.STANDUP_TIMEOUT_S + 0.1)
    assert m.armed(), '超时后应强制开始判摔'
    print('  ✓ 起立超时后强制开始判摔（%.0fs）' % ar.STANDUP_TIMEOUT_S)


def main():
    print('=' * 56)
    print('  摔倒判定逻辑单元测试 (不依赖 ROS/Gazebo)')
    print('=' * 56)
    print('阈值配置: 倾角>%.0f°  高度<%.2f m  确认时间%.1fs'
          % (ar.FALL_ROLL_PITCH_DEG, ar.FALL_HEIGHT_M, ar.FALL_CONFIRM_TIME))
    print('-' * 56)

    tests = [
        test_quat_identity,
        test_quat_roll_90,
        test_quat_pitch_60,
        test_standing_not_fall,
        test_tilt_detected,
        test_low_height_detected,
        test_brief_tilt_not_fall,
        test_multiple_falls,
        test_max_tilt_tracked,
        test_min_z_tracked,
        test_extremes_not_disturbed_by_fall,
        test_grace_period_no_false_fall,
        test_grace_period_arms_then_detects,
        test_grace_period_timeout,
    ]

    passed = 0
    failed = 0
    for t in tests:
        try:
            t()
            passed += 1
        except AssertionError as e:
            failed += 1
            print('  ✗ %s 失败: %s' % (t.__name__, e))
        except Exception as e:
            failed += 1
            print('  ✗ %s 异常: %s' % (t.__name__, e))

    print('-' * 56)
    print('  结果: %d 通过, %d 失败' % (passed, failed))
    print('=' * 56)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
