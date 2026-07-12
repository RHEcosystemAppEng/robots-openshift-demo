#!/bin/bash
set -eo pipefail

export HOME=/tmp/ros-home
export ROS_HOME=/tmp/ros-home

mkdir -p /tmp/ros-home

source /usr/lib64/ros-jazzy/setup.bash

echo "=== Robot Demo: Nav2 pod starting ==="

# ── 1. Publish odom→base_footprint TF from /odom ─────────────────────────────
# ros_gz_bridge drops this TF because Gazebo Harmonic DiffDrive encodes
# child_frame_id in Pose.header.data rather than Pose.name.
echo "[TF] Starting odom→base_footprint TF broadcaster"
python3 /usr/local/lib/odom_to_tf.py &
sleep 2

# ── 2. Wait for real /scan data from Gazebo via Zenoh ────────────────────────
# The zenoh-bridge creates a ghost DDS publisher immediately on startup, making
# Publisher count: 1 appear even when no data flows.  Check actual message rate.
# Keep a persistent background subscriber alive so the Zenoh lazy route stays
# established — repeated short-lived subscribers reset the route each time.
# Keep a persistent /scan subscriber alive for the entire session.
# If the only subscriber disappears even briefly, the Zenoh lazy route tears
# down before SLAM re-subscribes, permanently stopping scan data flow.
echo "[Nav2] Subscribing to /scan to hold Zenoh route open (lifetime of pod)..."
ros2 topic echo /scan > /dev/null 2>&1 &
SCAN_ECHO_PID=$!
# intentionally NOT killed — stays alive until the pod exits

echo "[Nav2] Waiting for real /scan data from Gazebo via Zenoh..."
for i in $(seq 1 120); do
  # 'timeout' exits 124 (SIGTERM) which with pipefail would override grep's
  # success exit code; wrap with || true so grep's result is what counts.
  if { timeout 4 ros2 topic hz /scan 2>/dev/null || true; } | grep -q "average rate"; then
    echo "[Nav2] /scan data confirmed flowing (${i}x3 s waited)"
    break
  fi
  echo "[Nav2]   ... no /scan data yet (${i}/120)"
  sleep 3
done
# SCAN_ECHO_PID left running intentionally — see comment above

# ── 3. Static TF: bridge URDF frame to Gazebo scoped sensor frame ─────────────
# Gazebo publishes scan with frame_id 'turtlebot3_waffle/base_scan/lidar'.
# The URDF uses 'base_scan'. Publish an identity static TF to connect them.
echo "[TF] Publishing static TF: base_scan -> turtlebot3_waffle/base_scan/lidar"
ros2 run tf2_ros static_transform_publisher \
  --frame-id base_scan \
  --child-frame-id "turtlebot3_waffle/base_scan/lidar" &
sleep 2

# ── 4. SLAM Toolbox ───────────────────────────────────────────────────────────
echo "[SLAM] Starting slam_toolbox async_slam_toolbox_node"
ros2 run slam_toolbox async_slam_toolbox_node \
  --ros-args \
  --params-file /home/ros/nav2/slam_params.yaml \
  -p use_sim_time:=true &
SLAM_PID=$!
sleep 3

echo "[SLAM] Configuring slam_toolbox lifecycle..."
ros2 lifecycle set /slam_toolbox configure --spin-time 30 2>&1 || true

echo "[SLAM] Waiting for slam_toolbox inactive state..."
for i in $(seq 1 30); do
  STATE=$(ros2 lifecycle get /slam_toolbox 2>/dev/null | grep -o "inactive\|active\|unconfigured" | head -1)
  if [ "${STATE}" = "inactive" ] || [ "${STATE}" = "active" ]; then
    echo "[SLAM] State: ${STATE} after ${i}x2 s"
    break
  fi
  echo "[SLAM]   ... state=${STATE:-unknown} (${i}/30)"
  sleep 2
done

echo "[SLAM] Activating slam_toolbox lifecycle..."
ros2 lifecycle set /slam_toolbox activate --spin-time 30 2>&1 || true

# Wait for the full TF chain map→odom→base_footprint to be stable.
# Checking /map topic alone is insufficient — SLAM publishes the topic
# before map→odom TF is ready, causing global_costmap to fail during Nav2
# planner_server activation.
echo "[SLAM] Waiting for map→base_footprint TF (confirms SLAM is publishing TF)..."
for i in $(seq 1 120); do
  if { timeout 5 ros2 run tf2_ros tf2_echo map base_footprint 2>/dev/null || true; } | grep -q "Translation"; then
    echo "[SLAM] map→base_footprint TF is live (${i}x3 s waited)"
    break
  fi
  echo "[SLAM]   ... TF not ready yet (${i}/120)"
  sleep 3
done

# ── 5. Nav2 bringup (custom launch: core nodes only) ─────────────────────────
echo "[Nav2] Starting nav2_bringup"
python3 - <<'PYEOF' &
import sys
from launch import LaunchService
import importlib.util

spec = importlib.util.spec_from_file_location("nav2_launch", "/usr/local/lib/nav2_launch.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

ls = LaunchService(argv=["params_file:=/home/ros/nav2/nav2_params.yaml", "use_sim_time:=true"])
ls.include_launch_description(mod.generate_launch_description())
sys.exit(ls.run())
PYEOF
NAV2_PID=$!

echo "[Nav2] Waiting for Nav2 to become active (up to 3 min)..."
for i in $(seq 1 36); do
  if ros2 node list 2>/dev/null | grep -q "bt_navigator"; then
    echo "[Nav2] Nav2 is active (${i}x5 s)"
    break
  fi
  echo "[Nav2]   ... waiting (${i}/36)"
  sleep 5
done

# ── 6. Patrol mission ─────────────────────────────────────────────────────────
echo "[Patrol] Starting patrol.py"
python3 /home/ros/patrol/patrol.py &
PATROL_PID=$!

echo "=== Nav2 pod ready ==="

wait -n ${SLAM_PID} ${NAV2_PID} ${PATROL_PID} || true
echo "A child process exited -- shutting down"
kill ${SLAM_PID} ${NAV2_PID} ${PATROL_PID} 2>/dev/null || true
