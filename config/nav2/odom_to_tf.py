#!/usr/bin/env python3
"""Subscribe to /odom and publish the robot_N/odom→robot_N/base_footprint TF.

ros_gz_bridge's gz.msgs.Pose_V → tf2_msgs/msg/TFMessage conversion reads
child_frame_id from Pose.name, but Gazebo Harmonic DiffDrive puts it in
Pose.header.data["child_frame_id"] — so the bridge drops the transform.
This node bridges that gap.

ROBOT_NAME env var controls the frame prefix (default: robot_1).
"""

import os
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from nav_msgs.msg import Odometry
from geometry_msgs.msg import TransformStamped
from tf2_ros import TransformBroadcaster


class OdomToTF(Node):
    def __init__(self):
        super().__init__("odom_to_tf")
        robot_name = os.environ.get("ROBOT_NAME", "robot_1")
        self._odom_frame = f"{robot_name}/odom"
        self._base_frame = f"{robot_name}/base_footprint"
        self.br = TransformBroadcaster(self)
        qos = QoSProfile(
            reliability=ReliabilityPolicy.BEST_EFFORT,
            history=HistoryPolicy.KEEP_LAST,
            depth=10,
        )
        self.sub = self.create_subscription(Odometry, "/odom", self._cb, qos)
        self.get_logger().info(
            f"odom_to_tf: broadcasting {self._odom_frame}→{self._base_frame} TF"
        )

    def _cb(self, msg: Odometry) -> None:
        t = TransformStamped()
        t.header.stamp = msg.header.stamp
        t.header.frame_id = self._odom_frame
        t.child_frame_id = self._base_frame
        t.transform.translation.x = msg.pose.pose.position.x
        t.transform.translation.y = msg.pose.pose.position.y
        t.transform.translation.z = msg.pose.pose.position.z
        t.transform.rotation = msg.pose.pose.orientation
        self.br.sendTransform(t)


def main():
    rclpy.init()
    node = OdomToTF()
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
