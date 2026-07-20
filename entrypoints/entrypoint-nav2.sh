#!/bin/bash
set -eo pipefail

export HOME=/tmp/ros-home
export ROS_HOME=/tmp/ros-home

mkdir -p /tmp/ros-home

source /usr/lib64/ros-jazzy/setup.bash

# ROBOT_NAME controls TF frame prefix: robot_1/odom, robot_1/base_footprint, etc.
# ROBOT_MODEL is the Gazebo model name for the static lidar TF frame.
ROBOT_NAME=${ROBOT_NAME:-robot_1}
ROBOT_MODEL=${ROBOT_MODEL:-turtlebot3_waffle}

echo "=== Robot Demo: Nav2 pod starting (${ROBOT_NAME}) ==="

# ── 1. Publish robot_N/odom→robot_N/base_footprint TF from /odom ─────────────
echo "[TF] Starting odom→base_footprint TF broadcaster (${ROBOT_NAME})"
ROBOT_NAME=${ROBOT_NAME} python3 /usr/local/lib/odom_to_tf.py &
sleep 2

# ── 2. Topic relay: /robot_N/* ↔ bare topics ────────────────────────────────
# zenoh-bridge-ros2dds 1.9.0 does not support ros_namespace config.
# This relay bridges between Zenoh-routed /robot_N/* topics and the bare
# topic names that SLAM, Nav2, and patrol expect (e.g. /scan, /odom, /tf).
echo "[Relay] Starting topic_relay for ${ROBOT_NAME}"
ROBOT_NAME=${ROBOT_NAME} python3 /usr/local/lib/topic_relay.py &
RELAY_PID=$!
sleep 2

# ── 3. Wait for real /scan data from Gazebo via Zenoh ────────────────────────
# The relay subscribes to /${ROBOT_NAME}/scan from Zenoh and republishes as /scan.
echo "[Nav2] Subscribing to /scan to hold Zenoh route open..."
ros2 topic echo /scan > /dev/null 2>&1 &
SCAN_ECHO_PID=$!

echo "[Nav2] Waiting for real /scan data..."
for i in $(seq 1 200); do
  if { timeout 4 ros2 topic hz /scan 2>/dev/null || true; } | grep -q "average rate"; then
    echo "[Nav2] /scan data confirmed flowing (${i}x3 s waited)"
    break
  fi
  echo "[Nav2]   ... no /scan data yet (${i}/120)"
  sleep 3
done

# ── 4. Static TF: bridge URDF frame to Gazebo scoped sensor frame ─────────────
# Gazebo publishes scan with frame_id '<model>/base_scan/lidar'.
# robot_state_publisher (with frame_prefix) publishes '<robot_name>/base_scan'.
# Connect them with a static identity transform.
echo "[TF] Publishing static TF: ${ROBOT_NAME}/base_scan -> ${ROBOT_MODEL}/base_scan/lidar"
ros2 run tf2_ros static_transform_publisher \
  --frame-id "${ROBOT_NAME}/base_scan" \
  --child-frame-id "${ROBOT_MODEL}/base_scan/lidar" &

# Alias for bt_navigator compatibility: it uses robot_base_frame 'base_footprint'
# but SLAM publishes robot_N/base_footprint. Bridge them with an identity TF.
echo "[TF] Publishing alias TF: ${ROBOT_NAME}/base_footprint -> base_footprint"
ros2 run tf2_ros static_transform_publisher \
  --frame-id "${ROBOT_NAME}/base_footprint" \
  --child-frame-id "base_footprint" &
sleep 2

# ── 5. robot_state_publisher with per-robot frame prefix ──────────────────────
# Publishes URDF joint TF as robot_N/base_link, robot_N/base_scan, etc.
# Publishes /robot_N/robot_description for RViz RobotModel display.
echo "[RSP] Starting robot_state_publisher (frame_prefix=${ROBOT_NAME}/)"
URDF_FILE=$(find /usr/lib64/ros-jazzy /usr/share -name "turtlebot3_waffle.urdf" 2>/dev/null | head -1 || true)
if [ -n "${URDF_FILE}" ]; then
  ros2 run robot_state_publisher robot_state_publisher \
    --ros-args \
    -p robot_description:="$(cat "${URDF_FILE}")" \
    -p frame_prefix:="${ROBOT_NAME}/" \
    --remap /robot_description:=/${ROBOT_NAME}/robot_description &
  RSP_PID=$!
else
  echo "[RSP] Warning: turtlebot3_waffle.urdf not found — skipping robot_state_publisher"
  RSP_PID=0
fi
sleep 2

# ── 6. SLAM Toolbox (with per-robot frame names via envsubst) ─────────────────
echo "[SLAM] Generating slam_params.yaml for ${ROBOT_NAME} (initial pose: ${SLAM_INITIAL_X},${SLAM_INITIAL_Y})"
SLAM_INITIAL_X=${SLAM_INITIAL_X:-0.0} \
SLAM_INITIAL_Y=${SLAM_INITIAL_Y:-0.0} \
SLAM_INITIAL_YAW=${SLAM_INITIAL_YAW:-0.0} \
ROBOT_NAME=${ROBOT_NAME} \
  envsubst '${ROBOT_NAME}${SLAM_INITIAL_X}${SLAM_INITIAL_Y}${SLAM_INITIAL_YAW}' \
  < /home/ros/nav2/slam_params.yaml > /tmp/ros-home/slam_params.yaml

echo "[SLAM] Starting slam_toolbox async_slam_toolbox_node"
ros2 run slam_toolbox async_slam_toolbox_node \
  --ros-args \
  --params-file /tmp/ros-home/slam_params.yaml \
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

echo "[SLAM] Waiting for map→${ROBOT_NAME}/base_footprint TF..."
for i in $(seq 1 120); do
  if { timeout 5 ros2 run tf2_ros tf2_echo map "${ROBOT_NAME}/base_footprint" 2>/dev/null || true; } | grep -q "Translation"; then
    echo "[SLAM] map→${ROBOT_NAME}/base_footprint TF is live (${i}x3 s waited)"
    break
  fi
  echo "[SLAM]   ... TF not ready yet (${i}/120)"
  sleep 3
done

# ── 7. Nav2 bringup (parameterized via envsubst) ─────────────────────────────
echo "[Nav2] Generating nav2_params.yaml for ${ROBOT_NAME}"
ROBOT_NAME=${ROBOT_NAME} envsubst < /home/ros/nav2/nav2_params.yaml \
  > /tmp/ros-home/nav2_params.yaml

echo "[Nav2] Starting nav2_bringup"
python3 - <<'PYEOF' &
import sys
from launch import LaunchService
import importlib.util

spec = importlib.util.spec_from_file_location("nav2_launch", "/usr/local/lib/nav2_launch.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

ls = LaunchService(argv=["params_file:=/tmp/ros-home/nav2_params.yaml", "use_sim_time:=true"])
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

# ── 8. Patrol mission ─────────────────────────────────────────────────────────
echo "[Patrol] Starting patrol.py (${ROBOT_NAME})"
ROBOT_NAME=${ROBOT_NAME} python3 /home/ros/patrol/patrol.py &
PATROL_PID=$!

echo "=== Nav2 pod ready (${ROBOT_NAME}) ==="

wait -n ${SLAM_PID} ${NAV2_PID} ${PATROL_PID} ${RELAY_PID} || true
echo "A child process exited -- shutting down"
kill ${SLAM_PID} ${NAV2_PID} ${PATROL_PID} ${RELAY_PID} 2>/dev/null || true
