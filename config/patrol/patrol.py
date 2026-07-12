#!/usr/bin/env python3
"""Autonomous patrol using velocity commands with SLAM + Nav2 running.

Nav2's path planner is unreliable for repeated north-south trips because
SLAM + costmap state accumulates between runs, blocking previously-clear paths.

This patrol demonstrates the full stack (GPU lidar → SLAM → Nav2 → Zenoh → RViz)
using direct velocity commands for movement — reliable in all conditions.

Nav2 remains fully activated and available for on-demand goals via
RViz's '2D Goal Pose' button, which works well for single-goal navigation.
"""

import math
import time

import rclpy
from geometry_msgs.msg import Twist
from nav2_simple_commander.robot_navigator import BasicNavigator


def drive(pub, linear_x, angular_z, duration, dt=0.1):
    """Publish velocity for `duration` seconds."""
    msg = Twist()
    msg.linear.x = linear_x
    msg.angular.z = angular_z
    t0 = time.time()
    while time.time() - t0 < duration:
        pub.publish(msg)
        time.sleep(dt)
    # Stop
    msg.linear.x = 0.0
    msg.angular.z = 0.0
    pub.publish(msg)


def main():
    rclpy.init()
    nav = BasicNavigator()
    pub = nav.create_publisher(Twist, "/cmd_vel", 10)

    nav.get_logger().info("Waiting for Nav2 to be active...")
    nav.waitUntilNav2Active(localizer="slam_toolbox")
    nav.get_logger().info("Nav2 active — starting velocity-based patrol")
    nav.get_logger().info("Nav2 is fully available for '2D Goal Pose' goals in RViz")

    # Patrol parameters
    SPEED = 0.22          # m/s (TurtleBot3 Waffle comfortable speed)
    LEG_DIST = 2.0        # metres per straight leg
    LEG_TIME = LEG_DIST / SPEED   # ~9 seconds per leg
    TURN_TIME = math.pi / 0.5     # 180° turn at 0.5 rad/s = ~6 seconds

    loop = 0
    while rclpy.ok():
        loop += 1
        nav.get_logger().info(f"Patrol loop #{loop} — drive {LEG_DIST}m north, turn, return")

        # Drive north
        nav.get_logger().info(f"  Driving {LEG_DIST}m north...")
        drive(pub, SPEED, 0.0, LEG_TIME)
        nav.get_logger().info("  North reached — turning 180°")

        # Turn 180°
        drive(pub, 0.0, 0.5, TURN_TIME)

        # Drive south (back)
        nav.get_logger().info(f"  Driving {LEG_DIST}m back...")
        drive(pub, SPEED, 0.0, LEG_TIME)
        nav.get_logger().info("  Home reached — turning 180°")

        # Turn 180° to face north again
        drive(pub, 0.0, 0.5, TURN_TIME)

        nav.get_logger().info(f"Patrol loop #{loop} complete")

    rclpy.shutdown()


if __name__ == "__main__":
    main()
