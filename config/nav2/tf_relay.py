#!/usr/bin/env python3
"""TF relay for the shared viz pod: merges per-robot /tf and /tf_static into one.

Each nav2 pod's Zenoh bridge (ros_namespace: /robot_N) routes its /tf as
/robot_N/tf in Zenoh. The viz pod's bridge (no namespace) exposes these as
/robot_1/tf and /robot_2/tf on local DDS. RViz subscribes to /tf.

This node subscribes to /robot_1/tf, /robot_2/tf, /robot_1/tf_static,
/robot_2/tf_static and republishes all transforms to /tf and /tf_static so
RViz has a single unified TF tree showing both robots.

ROBOT_NAMES env var controls which robots to relay (default: "robot_1,robot_2").
"""

import os
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, DurabilityPolicy, ReliabilityPolicy, HistoryPolicy
from tf2_msgs.msg import TFMessage


class TFRelay(Node):
    def __init__(self):
        super().__init__("tf_relay")

        robot_names = os.environ.get("ROBOT_NAMES", "robot_1,robot_2").split(",")
        robot_names = [r.strip() for r in robot_names if r.strip()]

        volatile_qos = QoSProfile(
            reliability=ReliabilityPolicy.RELIABLE,
            history=HistoryPolicy.KEEP_LAST,
            depth=100,
        )
        latched_qos = QoSProfile(
            reliability=ReliabilityPolicy.RELIABLE,
            durability=DurabilityPolicy.TRANSIENT_LOCAL,
            history=HistoryPolicy.KEEP_LAST,
            depth=100,
        )

        self._tf_pub = self.create_publisher(TFMessage, "/tf", volatile_qos)
        self._tf_static_pub = self.create_publisher(TFMessage, "/tf_static", latched_qos)

        for robot in robot_names:
            self.create_subscription(
                TFMessage, f"/{robot}/tf",
                self._make_tf_cb(robot),
                volatile_qos,
            )
            self.create_subscription(
                TFMessage, f"/{robot}/tf_static",
                self._make_tf_static_cb(robot),
                latched_qos,
            )

        self.get_logger().info(f"tf_relay: merging TF from {robot_names} → /tf and /tf_static")

    def _make_tf_cb(self, robot: str):
        def cb(msg: TFMessage):
            self._tf_pub.publish(msg)
        return cb

    def _make_tf_static_cb(self, robot: str):
        def cb(msg: TFMessage):
            self._tf_static_pub.publish(msg)
        return cb


def main():
    rclpy.init()
    node = TFRelay()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
