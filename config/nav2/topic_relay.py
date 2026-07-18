#!/usr/bin/env python3
"""Bidirectional topic relay for multi-robot namespace isolation.

zenoh-bridge-ros2dds 1.9.0 does not support ros_namespace config.
This relay runs inside each nav2 pod and bridges between:
  - /robot_N/* topics (what Zenoh sees in the shared router)
  - bare topics like /scan, /odom, /tf (what SLAM, Nav2, and patrol expect)

Inbound (Gazebo → nav2 internals via Zenoh):
  /robot_N/scan         → /scan
  /robot_N/odom         → /odom
  /robot_N/joint_states → /joint_states

Outbound (nav2 internals → Zenoh → viz / Gazebo):
  /cmd_vel   → /robot_N/cmd_vel   (motor commands to Gazebo)
  /tf        → /robot_N/tf        (TF frames for tf_relay in viz pod)
  /tf_static → /robot_N/tf_static
  /map       → /robot_N/map       (SLAM map for viz pod)
  /plan      → /robot_N/plan      (Nav2 path for viz pod)

ROBOT_NAME env var selects the prefix (default: robot_1).
"""

import os
import rclpy
from rclpy.node import Node
from rclpy.qos import (QoSProfile, ReliabilityPolicy, DurabilityPolicy,
                        HistoryPolicy)
from geometry_msgs.msg import Twist
from nav_msgs.msg import OccupancyGrid, Path, Odometry
from sensor_msgs.msg import LaserScan, JointState
from tf2_msgs.msg import TFMessage

VOLATILE = QoSProfile(
    reliability=ReliabilityPolicy.RELIABLE,
    history=HistoryPolicy.KEEP_LAST,
    depth=100,
)
BEST_EFFORT = QoSProfile(
    reliability=ReliabilityPolicy.BEST_EFFORT,
    history=HistoryPolicy.KEEP_LAST,
    depth=10,
)
LATCHED = QoSProfile(
    reliability=ReliabilityPolicy.RELIABLE,
    durability=DurabilityPolicy.TRANSIENT_LOCAL,
    history=HistoryPolicy.KEEP_LAST,
    depth=100,
)


class TopicRelay(Node):
    def __init__(self, robot_name: str):
        super().__init__("topic_relay")
        n = robot_name

        # ── Inbound: /robot_N/* → bare topic ────────────────────────────────
        scan_pub = self.create_publisher(LaserScan, "/scan", BEST_EFFORT)
        self.create_subscription(LaserScan, f"/{n}/scan",
                                 lambda m: scan_pub.publish(m), BEST_EFFORT)

        odom_pub = self.create_publisher(Odometry, "/odom", BEST_EFFORT)
        self.create_subscription(Odometry, f"/{n}/odom",
                                 lambda m: odom_pub.publish(m), BEST_EFFORT)

        js_pub = self.create_publisher(JointState, "/joint_states", VOLATILE)
        self.create_subscription(JointState, f"/{n}/joint_states",
                                 lambda m: js_pub.publish(m), VOLATILE)

        # ── Outbound: bare topic → /robot_N/* ───────────────────────────────
        cmd_pub = self.create_publisher(Twist, f"/{n}/cmd_vel", VOLATILE)
        self.create_subscription(Twist, "/cmd_vel",
                                 lambda m: cmd_pub.publish(m), VOLATILE)

        tf_pub = self.create_publisher(TFMessage, f"/{n}/tf", VOLATILE)
        self.create_subscription(TFMessage, "/tf",
                                 lambda m: tf_pub.publish(m), VOLATILE)

        tf_static_pub = self.create_publisher(TFMessage, f"/{n}/tf_static", LATCHED)
        self.create_subscription(TFMessage, "/tf_static",
                                 lambda m: tf_static_pub.publish(m), LATCHED)

        map_pub = self.create_publisher(OccupancyGrid, f"/{n}/map", LATCHED)
        self.create_subscription(OccupancyGrid, "/map",
                                 lambda m: map_pub.publish(m), LATCHED)

        plan_pub = self.create_publisher(Path, f"/{n}/plan", VOLATILE)
        self.create_subscription(Path, "/plan",
                                 lambda m: plan_pub.publish(m), VOLATILE)

        self.get_logger().info(
            f"topic_relay: /{n}/* ↔ bare topics active"
        )


def main():
    rclpy.init()
    robot_name = os.environ.get("ROBOT_NAME", "robot_1")
    node = TopicRelay(robot_name)
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
