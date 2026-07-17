#!/usr/bin/env python3
"""Autonomous patrol with 2D Goal Pose interrupt support.

The robot patrols back-and-forth using direct cmd_vel commands while the full
SLAM + Nav2 stack runs. When the user clicks '2D Goal Pose' in RViz, patrol
pauses automatically so Nav2 can navigate to the goal. Patrol resumes when
Nav2 finishes (success, abort, or cancel).

Nav2's BT navigator handles /goal_pose natively — we just yield cmd_vel.
"""

import math
import time
import threading

import rclpy
from rclpy.executors import MultiThreadedExecutor
from action_msgs.msg import GoalStatus, GoalStatusArray
from geometry_msgs.msg import Twist, PoseStamped
from nav2_simple_commander.robot_navigator import BasicNavigator

_paused = threading.Event()
_nav_seen_active = False
_nav_lock = threading.Lock()


def _on_goal_pose(msg):
    global _nav_seen_active
    with _nav_lock:
        _nav_seen_active = False  # reset before the new goal becomes active
    _paused.set()


def _on_action_status(msg):
    global _nav_seen_active
    if not _paused.is_set():
        return
    with _nav_lock:
        active = any(
            g.status in (GoalStatus.STATUS_ACCEPTED, GoalStatus.STATUS_EXECUTING)
            for g in msg.status_list
        )
        if active:
            _nav_seen_active = True
        elif _nav_seen_active and msg.status_list:
            # Saw the goal go active; now it is terminal — navigation is done
            _nav_seen_active = False
            _paused.clear()


def drive(pub, linear_x, angular_z, duration, dt=0.1):
    """Publish velocity for duration seconds; return False if interrupted."""
    msg = Twist()
    msg.linear.x = linear_x
    msg.angular.z = angular_z
    t0 = time.time()
    while time.time() - t0 < duration:
        if _paused.is_set():
            pub.publish(Twist())  # stop before yielding
            return False
        pub.publish(msg)
        time.sleep(dt)
    pub.publish(Twist())
    return True


def main():
    rclpy.init()
    nav = BasicNavigator()
    pub = nav.create_publisher(Twist, "/cmd_vel", 10)

    # Detect when user sends a 2D Goal Pose from RViz
    nav.create_subscription(PoseStamped, "/goal_pose", _on_goal_pose, 10)
    # Detect when Nav2 finishes navigating to that goal
    nav.create_subscription(
        GoalStatusArray,
        "/navigate_to_pose/_action/status",
        _on_action_status,
        10,
    )

    # Spin in background so callbacks fire while drive() sleeps
    executor = MultiThreadedExecutor()
    executor.add_node(nav)
    threading.Thread(target=executor.spin, daemon=True).start()

    nav.waitUntilNav2Active(localizer="slam_toolbox")
    nav.get_logger().info("Nav2 active — continuous patrol + 2D Goal Pose support")
    nav.get_logger().info("Click '2D Goal Pose' in RViz to send a Nav2 goal; patrol resumes after.")

    SPEED = 0.22
    LEG_DIST = 2.0
    LEG_TIME = LEG_DIST / SPEED   # ~9 s per leg
    TURN_TIME = math.pi / 0.5     # 180° at 0.5 rad/s ≈ 6 s

    loop = 0
    while rclpy.ok():
        if _paused.is_set():
            nav.get_logger().info("Nav2 goal active — patrol paused, yielding cmd_vel")
            while _paused.is_set() and rclpy.ok():
                time.sleep(0.3)
            nav.get_logger().info("Nav2 goal complete — resuming patrol")
            continue

        loop += 1
        nav.get_logger().info(f"Patrol loop #{loop} — {LEG_DIST}m north, turn, return")

        if not drive(pub, SPEED, 0.0, LEG_TIME): continue   # north
        if not drive(pub, 0.0, 0.5, TURN_TIME): continue    # turn 180°
        if not drive(pub, SPEED, 0.0, LEG_TIME): continue   # south
        if not drive(pub, 0.0, 0.5, TURN_TIME): continue    # turn 180°

    rclpy.shutdown()


if __name__ == "__main__":
    main()
