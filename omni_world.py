#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
omni_world.py —— 程序化生成各种 Gazebo 测试场景（.world 文件）

为什么需要它：
  手写 .world 每个场景都要几十行，想加"20 个场景"就要写上千行。
  这里用参数化 + 随机种子，一条命令就能生成一个场景，且可复现。

用法：
    python3 omni_world.py --list                      # 列出所有内置场景
    python3 omni_world.py flat        -o /tmp/flat.world
    python3 omni_world.py bumps       -o /tmp/bumps.world
    python3 omni_world.py stairs      -o /tmp/stairs.world
    python3 omni_world.py rough       -o /tmp/rough.world --seed 7
    python3 omni_world.py maze        -o /tmp/maze.world
    python3 omni_world.py slope       -o /tmp/slope.world --angle 12
    python3 omni_world.py corridor    -o /tmp/c.world --width 0.6
    python3 omni_world.py mixed       -o /tmp/mixed.world --seed 3
    python3 omni_world.py random      -o /tmp/r.world --seed 42

设计说明（重要）：
  - 场景尺寸围绕 dmgo 的实际能力设计：站高约 0.35 m，正常步高约 0.12 m。
    所以"可通过的障碍"高度控制在 0.03~0.10 m，
    "会摔倒的"障碍做到 0.25 m 以上。
  - 所有地形都没有使用 mesh / 外部模型，只用 box / cylinder / sphere，
    这样不依赖 Gazebo 的模型数据库，离线也能加载。
  - generate_urdf 与 spawn 逻辑不在本文件里，见 run_scene.sh 和 launch/scene.launch。
"""

from __future__ import print_function

import argparse
import inspect
import math
import os
import random
import sys

HEADER = '''<?xml version="1.0" ?>
<!-- 由 omni_world.py 自动生成: scene={scene} seed={seed} -->
<sdf version="1.5">
  <world name="{scene}">
    <physics type="ode">
      <type>world</type>
      <max_step_size>0.001</max_step_size>
      <real_time_update_rate>1000</real_time_update_rate>
      <iters>500</iters>
    </physics>
    <include><uri>model://sun</uri></include>
    <include><uri>model://ground_plane</uri></include>
'''

FOOTER = '''
  </world>
</sdf>
'''

MATERIALS = ['Gazebo/Grey', 'Gazebo/DarkGrey', 'Gazebo/Brown', 'Gazebo/Orange',
             'Gazebo/Red', 'Gazebo/Blue', 'Gazebo/Green', 'Gazebo/Wood']


# ---------------------------------------------------------------- 基础构件

def box(name, x, y, z, sx, sy, sz, roll=0.0, pitch=0.0, yaw=0.0,
        mu=1.0, material='Gazebo/Grey', static=True):
    """一个长方体。sz 是【总高】，z 是【中心高度】。"""
    st = 'true' if static else 'false'
    return '''    <model name="{name}">
      <static>{st}</static>
      <pose>{x:.3f} {y:.3f} {z:.3f} {r:.4f} {p:.4f} {yaw:.4f}</pose>
      <link name="link">
        <collision name="collision">
          <geometry><box><size>{sx:.3f} {sy:.3f} {sz:.3f}</size></box></geometry>
          <surface><friction><ode><mu>{mu}</mu><mu2>{mu}</mu2></ode></friction></surface>
        </collision>
        <visual name="visual">
          <geometry><box><size>{sx:.3f} {sy:.3f} {sz:.3f}</size></box></geometry>
          <material><script><uri>file://media/materials/scripts/gazebo.material</uri>
            <name>{mat}</name></script></material>
        </visual>
      </link>
    </model>
'''.format(name=name, st=st, x=x, y=y, z=z, sx=sx, sy=sy, sz=sz,
           r=roll, p=pitch, yaw=yaw, mu=mu, mat=material)


def cylinder(name, x, y, z, radius, length, mu=1.0, material='Gazebo/Grey', static=True):
    """圆柱。z 是【中心高度】，length 是总长（竖直方向）。"""
    st = 'true' if static else 'false'
    return '''    <model name="{name}">
      <static>{st}</static>
      <pose>{x:.3f} {y:.3f} {z:.3f} 0 0 0</pose>
      <link name="link">
        <collision name="collision">
          <geometry><cylinder><radius>{r:.3f}</radius><length>{l:.3f}</length></cylinder></geometry>
          <surface><friction><ode><mu>{mu}</mu><mu2>{mu}</mu2></ode></friction></surface>
        </collision>
        <visual name="visual">
          <geometry><cylinder><radius>{r:.3f}</radius><length>{l:.3f}</length></cylinder></geometry>
          <material><script><uri>file://media/materials/scripts/gazebo.material</uri>
            <name>{mat}</name></script></material>
        </visual>
      </link>
    </model>
'''.format(name=name, st=st, x=x, y=y, z=z, r=radius, l=length, mu=mu, mat=material)


def sphere(name, x, y, z, radius, mu=1.0, material='Gazebo/Grey', static=True):
    """球体（单个圆滑障碍点，狗踩上去容易滑）。"""
    st = 'true' if static else 'false'
    return '''    <model name="{name}">
      <static>{st}</static>
      <pose>{x:.3f} {y:.3f} {z:.3f} 0 0 0</pose>
      <link name="link">
        <collision name="collision">
          <geometry><sphere><radius>{r:.3f}</radius></sphere></geometry>
          <surface><friction><ode><mu>{mu}</mu><mu2>{mu}</mu2></ode></friction></surface>
        </collision>
        <visual name="visual">
          <geometry><sphere><radius>{r:.3f}</radius></sphere></geometry>
          <material><script><uri>file://media/materials/scripts/gazebo.material</uri>
            <name>{mat}</name></script></material>
        </visual>
      </link>
    </model>
'''.format(name=name, st=st, x=x, y=y, z=z, r=radius, mu=mu, mat=material)


def marker(name, x, y, radius=0.4, color='Gazebo/Green'):
    """地面上的圆形标记（起点/终点），纯视觉无碰撞。"""
    return '''    <model name="{name}">
      <static>true</static>
      <pose>{x:.3f} {y:.3f} 0.005 0 0 0</pose>
      <link name="link">
        <visual name="visual">
          <geometry><cylinder><radius>{r:.3f}</radius><length>0.01</length></cylinder></geometry>
          <material><script><uri>file://media/materials/scripts/gazebo.material</uri>
            <name>{c}</name></script></material>
        </visual>
      </link>
    </model>
'''.format(name=name, x=x, y=y, r=radius, c=color)


# ---------------------------------------------------------------- 各场景生成器

def scene_flat(rng, **kw):
    """纯平地 + 起终点标记。所有对比实验的基准组。"""
    return [marker('start', 0.0, 0.0, 0.3, 'Gazebo/Blue'),
            marker('goal', 5.0, 0.0, 0.4, 'Gazebo/Green')]


def scene_bumps(rng, height=0.05, count=10, spacing=0.6, **kw):
    """
    等间距矮坎（bump）。用 --height 调高度做"通过性阶梯"：
      0.03 -> 轻松过
      0.06 -> trot 需要明显抬腿
      0.10 -> 接近极限，容易绊倒
    """
    out = []
    for i in range(count):
        out.append(box('bump_%d' % i, 1.5 + i * spacing, 0.0,
                       height / 2.0, 0.12, 1.0, height,
                       material='Gazebo/Orange'))
    out.append(marker('goal', 1.5 + count * spacing, 0.0, 0.4, 'Gazebo/Green'))
    return out


def scene_stairs(rng, rise=0.06, run=0.30, count=8, **kw):
    """连续台阶。rise 是关键参数：0.06 较易，0.10 已很难。"""
    out = []
    for i in range(count):
        top = (i + 1) * rise
        out.append(box('stair_%d' % i, run * (i + 0.5), 0.0, top / 2.0,
                       run, 1.2, top, material='Gazebo/DarkGrey'))
    return out


def scene_rough(rng, count=14, max_h=0.06, **kw):
    """随机散布的碎石块（高度/尺寸/朝向都随机），测不平地面适应。"""
    out = []
    for i in range(count):
        h = rng.uniform(0.02, max_h)
        out.append(box('rock_%d' % i,
                       rng.uniform(1.5, 9.0), rng.uniform(-0.8, 0.8), h / 2.0,
                       rng.uniform(0.15, 0.4), rng.uniform(0.15, 0.4), h,
                       yaw=rng.uniform(0, math.pi),
                       material=rng.choice(MATERIALS)))
    return out


def scene_maze(rng, corridors=4, **kw):
    """之字形走廊：上下挡板交错，必须左右绕行才能通过。"""
    out = []
    for i in range(corridors):
        x0 = 1.5 + i * 1.5
        out.append(box('maze_a_%d' % i, x0, 0.7, 0.25, 1.2, 0.1, 0.5,
                       material='Gazebo/Blue'))
        out.append(box('maze_b_%d' % i, x0 + 0.75, -0.7, 0.25, 1.2, 0.1, 0.5,
                       material='Gazebo/Blue'))
    return out


def scene_gap(rng, gap=0.18, **kw):
    """
    沟壑：用两块抬高地面夹一条缝实现（中间是空的）。
    狗腿长约 0.3 m，gap≈0.18 是关键测试点。
    """
    out = [box('ground_a', 1.0, 0.0, -0.025, 3.0, 2.0, 0.05,
               material='Gazebo/Brown')]
    b_x = 2.5 + gap + 1.5
    out.append(box('ground_b', b_x, 0.0, -0.025, 3.0, 2.0, 0.05,
                   material='Gazebo/Brown'))
    out.append(marker('goal', b_x, 0.0, 0.4, 'Gazebo/Green'))
    return out


def scene_slope(rng, angle=10.0, length=3.0, **kw):
    """斜坡：上坡 -> 平台 -> 下坡。angle 单位为度。"""
    rad = math.radians(angle)
    out = []
    # 上坡：pitch 取负 = 沿 +x 方向向上翘
    out.append(box('ramp_up', 1.0 + length * math.cos(rad) / 2.0, 0.0,
                   length * math.sin(rad) / 2.0 + 0.025,
                   length, 1.5, 0.05, pitch=-rad, mu=1.2, material='Gazebo/Wood'))
    top_x = 1.0 + length * math.cos(rad)
    top_z = length * math.sin(rad)
    out.append(box('platform', top_x + 0.5, 0.0, top_z + 0.025,
                   1.0, 1.5, 0.05, mu=1.2, material='Gazebo/Wood'))
    out.append(box('ramp_down', top_x + 1.0 + length * math.cos(rad) / 2.0, 0.0,
                   top_z - length * math.sin(rad) / 2.0 + 0.025,
                   length, 1.5, 0.05, pitch=rad, mu=1.2, material='Gazebo/Wood'))
    return out


def scene_corridor(rng, width=0.6, length=6.0, **kw):
    """窄走廊：两侧墙，width 可调，测贴墙行走与侧向碰撞。"""
    out = []
    for side, sign in (('l', 1.0), ('r', -1.0)):
        out.append(box('wall_%s' % side, 1.0 + length / 2.0,
                       sign * (width / 2.0 + 0.05), 0.25,
                       length, 0.1, 0.5, material='Gazebo/Grey'))
    return out


def scene_stepping(rng, count=8, h=0.05, **kw):
    """
    错落"踏步石"：左右交替 +/-0.25 m，逼狗主动调整落脚点。
    比 rough 更结构化，专门测落脚点规划。
    """
    out = []
    for i in range(count):
        y = 0.25 if i % 2 == 0 else -0.25
        out.append(box('stone_%d' % i, 1.5 + i * 0.55, y, h / 2.0,
                       0.35, 0.35, h, material='Gazebo/DarkGrey'))
    return out


def scene_pillars(rng, count=12, **kw):
    """密集圆柱阵：必须绕行，测侧向避障。"""
    out = []
    for i in range(count):
        out.append(cylinder('pole_%d' % i,
                            rng.uniform(1.2, 7.0), rng.uniform(-0.9, 0.9),
                            0.3, 0.06, 0.6, material='Gazebo/Red'))
    return out


def scene_boxes(rng, **kw):
    """阶梯升高的箱子（0.05/0.10/0.20/0.30 m），是"能不能过"的能力分界线。"""
    out = []
    for i, h in enumerate([0.05, 0.10, 0.20, 0.30]):
        out.append(box('box_%d' % i, 1.5 + i * 0.8, 0.0, h / 2.0,
                       0.25, 0.8, h, material=MATERIALS[i % len(MATERIALS)]))
    return out


def scene_dynamic(rng, count=5, **kw):
    """
    可推动的动态障碍（static=false）：撞上去会被推开，
    用来测试抗扰动 —— 外力作用下狗会不会被推倒。
    """
    out = []
    for i in range(count):
        out.append(box('dyn_box_%d' % i, 2.0 + i * 0.9,
                       rng.uniform(-0.4, 0.4), 0.2,
                       0.2, 0.2, 0.4, mu=0.6, static=False,
                       material='Gazebo/Orange'))
    return out


def scene_mixed(rng, difficulty=0.5, **kw):
    """
    混合地形：按 difficulty(0~1) 随机组合各种地形。
    最常用的"综合考核"场景，配合不同 --seed 生成一批测试集。
    """
    out = []
    x = 1.5
    kinds = ['bumps', 'rough', 'steps', 'slope', 'corridor', 'pillars', 'gap']
    n = int(3 + difficulty * 4)
    for i in range(n):
        kind = rng.choice(kinds)
        if kind == 'bumps':
            h = 0.03 + difficulty * 0.07
            for j in range(4):
                out.append(box('mx_bump_%d_%d' % (i, j), x + j * 0.6, 0.0,
                               h / 2.0, 0.12, 1.0, h,
                               material='Gazebo/Orange'))
            x += 3.0
        elif kind == 'rough':
            for j in range(5):
                h = rng.uniform(0.02, 0.03 + difficulty * 0.05)
                out.append(box('mx_rough_%d_%d' % (i, j),
                               x + rng.uniform(0, 1.5), rng.uniform(-0.7, 0.7),
                               h / 2.0, rng.uniform(0.15, 0.3),
                               rng.uniform(0.15, 0.3), h,
                               yaw=rng.uniform(0, math.pi),
                               material=rng.choice(MATERIALS)))
            x += 2.0
        elif kind == 'steps':
            h = 0.04 + difficulty * 0.05
            for j in range(3):
                out.append(box('mx_step_%d_%d' % (i, j), x + j * 0.35, 0.0,
                               (j + 1) * h / 2.0, 0.35, 1.0, (j + 1) * h,
                               material='Gazebo/DarkGrey'))
            x += 1.5
        elif kind == 'slope':
            ang = 6 + difficulty * 8
            for m in scene_slope(rng, angle=ang, length=1.5):
                out.append(m)
            x += 3.5
        elif kind == 'corridor':
            w = 0.9 - difficulty * 0.3
            out.append(box('mx_wl_%d' % i, x + 1.0, w / 2.0 + 0.05, 0.25,
                           2.0, 0.1, 0.5, material='Gazebo/Grey'))
            out.append(box('mx_wr_%d' % i, x + 1.0, -(w / 2.0 + 0.05), 0.25,
                           2.0, 0.1, 0.5, material='Gazebo/Grey'))
            x += 2.5
        elif kind == 'pillars':
            for j in range(4):
                out.append(cylinder('mx_pole_%d_%d' % (i, j),
                                    x + rng.uniform(0, 1.5),
                                    rng.uniform(-0.6, 0.6),
                                    0.3, 0.06, 0.6, material='Gazebo/Red'))
            x += 2.0
        elif kind == 'gap':
            g = 0.10 + difficulty * 0.12
            for m in scene_gap(rng, gap=g):
                out.append(m)
            x += 5.0
    out.append(marker('goal', min(x, 20.0), 0.0, 0.4, 'Gazebo/Green'))
    return out


def scene_random(rng, difficulty=0.5, count=25, **kw):
    """完全随机的地形块（位置/尺寸/朝向全随机），用于压力测试。"""
    out = []
    for i in range(count):
        kind = rng.choice(['box', 'cyl', 'sph'])
        x = rng.uniform(1.5, 14.0)
        y = rng.uniform(-1.2, 1.2)
        h = rng.uniform(0.02, 0.03 + difficulty * 0.12)
        if kind == 'box':
            out.append(box('r_box_%d' % i, x, y, h / 2.0,
                           rng.uniform(0.15, 0.5), rng.uniform(0.15, 0.5), h,
                           yaw=rng.uniform(0, math.pi),
                           material=rng.choice(MATERIALS)))
        elif kind == 'cyl':
            out.append(cylinder('r_cyl_%d' % i, x, y, h / 2.0,
                                rng.uniform(0.05, 0.12), h,
                                material=rng.choice(MATERIALS)))
        else:
            out.append(sphere('r_sph_%d' % i, x, y, h / 2.0,
                              rng.uniform(0.04, 0.09),
                              material=rng.choice(MATERIALS)))
    return out


SCENES = {
    'flat':     (scene_flat,     '纯平地（基准组）'),
    'bumps':    (scene_bumps,    '等间距矮坎（可调高度做通过性测试）'),
    'stairs':   (scene_stairs,   '连续台阶（可调 rise/run）'),
    'rough':    (scene_rough,    '随机碎石不平地面'),
    'maze':     (scene_maze,     '之字形走廊，测转向'),
    'gap':      (scene_gap,      '沟壑，测越沟能力'),
    'slope':    (scene_slope,    '斜坡+平台+下坡'),
    'corridor': (scene_corridor, '窄走廊，测贴墙行走'),
    'stepping': (scene_stepping, '错落踏步石，测落脚规划'),
    'pillars':  (scene_pillars,  '密集圆柱阵，测侧向避障'),
    'boxes':    (scene_boxes,    '阶梯升高箱子，能力分界线'),
    'dynamic':  (scene_dynamic,  '可推动的动态障碍，测抗扰动'),
    'mixed':    (scene_mixed,    '混合地形，综合考核'),
    'random':   (scene_random,   '完全随机地形，压力测试'),
}


def build(scene, seed=None, **kw):
    """按场景名生成 world XML 字符串。"""
    if scene not in SCENES:
        raise KeyError(scene)
    rng = random.Random(seed)
    fn = SCENES[scene][0]
    # 只把该生成器真正接受的参数传进去（多余的忽略，避免 TypeError）
    sig = inspect.signature(fn)
    params = {k: v for k, v in kw.items()
              if v is not None and k in sig.parameters and k != 'rng'}
    bodies = fn(rng, **params)
    return HEADER.format(scene=scene, seed=seed) + ''.join(bodies) + FOOTER


def main():
    ap = argparse.ArgumentParser(
        description='生成 Gazebo 测试场景 (.world)',
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('scene', nargs='?', help='场景名')
    ap.add_argument('-o', '--output', help='输出 .world 路径（省略则打印到 stdout）')
    ap.add_argument('--seed', type=int, default=None, help='随机种子（保证可复现）')
    ap.add_argument('--difficulty', type=float, default=0.5,
                    help='难度 0~1（mixed/random 用），默认 0.5')
    ap.add_argument('--height', type=float, default=None, help='坎高/台阶高度 (m)')
    ap.add_argument('--angle', type=float, default=None, help='坡度 (度)')
    ap.add_argument('--gap', type=float, default=None, help='沟宽 (m)')
    ap.add_argument('--width', type=float, default=None, help='走廊宽 (m)')
    ap.add_argument('--count', type=int, default=None, help='障碍数量')
    ap.add_argument('--list', action='store_true', help='列出所有场景')
    args = ap.parse_args()

    if args.list or not args.scene:
        print('可用场景 (共 %d 个):' % len(SCENES))
        print('-' * 62)
        for name in sorted(SCENES):
            print('  %-10s %s' % (name, SCENES[name][1]))
        print('-' * 62)
        print('示例:')
        print('  python3 omni_world.py bumps --height 0.08 -o /tmp/bumps.world')
        print('  python3 omni_world.py mixed --seed 3 --difficulty 0.7 -o /tmp/m.world')
        print('  python3 omni_world.py random --seed 42 -o /tmp/r.world')
        return 0

    # --height 在不同场景里含义不同，做一次映射
    kw = {'difficulty': args.difficulty}
    scene = args.scene
    if args.height is not None:
        if scene == 'bumps':
            kw['height'] = args.height
        elif scene == 'stairs':
            kw['rise'] = args.height
        elif scene == 'stepping':
            kw['h'] = args.height
        else:
            kw['max_h'] = args.height
    if args.angle is not None:
        kw['angle'] = args.angle
    if args.gap is not None:
        kw['gap'] = args.gap
    if args.width is not None:
        kw['width'] = args.width
    if args.count is not None:
        kw['count'] = args.count

    try:
        xml = build(scene, seed=args.seed, **kw)
    except KeyError:
        print('未知场景: %s（用 --list 查看）' % scene, file=sys.stderr)
        return 1

    if not args.output:
        sys.stdout.write(xml)
        return 0

    outdir = os.path.dirname(os.path.abspath(args.output))
    if outdir and not os.path.isdir(outdir):
        os.makedirs(outdir)
    with open(args.output, 'w') as f:
        f.write(xml)
    print('[omni_world] %s -> %s (%d 个模型)'
          % (scene, args.output, xml.count('<model ')))
    return 0


if __name__ == '__main__':
    sys.exit(main())
