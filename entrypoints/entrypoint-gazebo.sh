#!/bin/bash
set -eo pipefail

export HOME=/tmp/ros-home
export ROS_HOME=/tmp/ros-home
export GZ_HOME=/tmp/ros-home
export GZ_CACHE_PATH=/tmp/ros-home/.gz

mkdir -p /tmp/ros-home /tmp/ros-home/.gz /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix 2>/dev/null || true

source /usr/lib64/ros-jazzy/setup.bash

echo "=== Robot Demo: Gazebo pod starting ==="

# --- GPU detection ---
if nvidia-smi &>/dev/null 2>&1; then
  echo "[GPU] NVIDIA GPU detected — using hardware rendering"
  export LIBGL_ALWAYS_SOFTWARE=0
  export WORLD_FILE=${WORLD_FILE:-/home/ros/worlds/tb3_waffle_gpu.sdf}
  export NVIDIA_VISIBLE_DEVICES=${NVIDIA_VISIBLE_DEVICES:-all}
  export NVIDIA_DRIVER_CAPABILITIES=${NVIDIA_DRIVER_CAPABILITIES:-graphics,compute,utility}
  # Tell OGRE2's GLX path to use NVIDIA's driver when rendering to Xvfb (:99).
  # OGRE2 uses GLX (not EGL) when DISPLAY is set; __EGL_VENDOR_LIBRARY_FILENAMES
  # has no effect on the GUI renderer. This is the same technique used by
  # lokeshrangineni/ros2-openshift-demo to get MinimalScene working on GPU nodes.
  export __NV_PRIME_RENDER_OFFLOAD=1
  export __GLX_VENDOR_LIBRARY_NAME=nvidia
  GPU_MODE=true
else
  echo "[GPU] No GPU found — using llvmpipe software rendering"
  export LIBGL_ALWAYS_SOFTWARE=1
  export GALLIUM_DRIVER=llvmpipe
  export WORLD_FILE=${WORLD_FILE:-/home/ros/worlds/tb3_waffle_cpu.sdf}
  GPU_MODE=false
fi

# --- Spawn pose: patch the world SDF for multi-robot positioning ---
SPAWN_X=${GZ_SPAWN_POSE_X:--3.0}
SPAWN_Y=${GZ_SPAWN_POSE_Y:--3.0}
SPAWN_THETA=${GZ_SPAWN_POSE_THETA:-0.0}
ROBOT_LABEL=${ROBOT_NAME:-robot_1}
echo "[Robot] ${ROBOT_LABEL} spawning at (${SPAWN_X}, ${SPAWN_Y}, theta=${SPAWN_THETA})"

# Only patch if any pose param is explicitly overridden (avoids a redundant copy for robot 1)
if [ "${SPAWN_X}" != "-3.0" ] || [ "${SPAWN_Y}" != "-3.0" ] || [ "${SPAWN_THETA}" != "0.0" ]; then
  WORLD_TMP=/tmp/ros-home/world_instance.sdf
  cp "${WORLD_FILE}" "${WORLD_TMP}"
  sed -i "s|<pose>-3.0 -3.0 0.0 0 0 0</pose>|<pose>${SPAWN_X} ${SPAWN_Y} 0.0 0 0 ${SPAWN_THETA}</pose>|" "${WORLD_TMP}"
  export WORLD_FILE="${WORLD_TMP}"
  echo "[Robot] World SDF patched: ${WORLD_FILE}"
fi

# --- noVNC display stack (both GPU and CPU modes) ---
# On GPU nodes, NVIDIA's EGL ICD crashes Xvfb if it initialises as the EGL
# backend. Scope __EGL_VENDOR_LIBRARY_FILENAMES to Mesa only for the Xvfb
# launch, then immediately unset so Gazebo itself gets the full NVIDIA ICD.
# Credit: lokeshrangineni/ros2-openshift-demo uses the same technique.
echo "[Display] Starting Xvfb + noVNC on :99 / port 6080"
export XAUTHORITY=/tmp/ros-home/.Xauthority
XCOOKIE=$(python3 -c "import secrets; print(secrets.token_hex(16))")
xauth add :99 . "${XCOOKIE}"

if [ "${GPU_MODE}" = "true" ]; then
  export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
fi
Xvfb :99 -screen 0 1280x720x24 -auth "${XAUTHORITY}" +extension GLX +render -noreset &
XVFB_PID=$!
unset __EGL_VENDOR_LIBRARY_FILENAMES   # restore so Gazebo gets NVIDIA EGL

sleep 3
export DISPLAY=:99
openbox &
sleep 1
x11vnc -display :99 -auth "${XAUTHORITY}" -nopw -listen 0.0.0.0 -forever -bg -quiet
websockify --web /usr/share/novnc 6080 localhost:5900 &
NOVNC_PID=$!

# --- Landing page HTTP server on port 8080 ---
echo "[HTTP] Serving landing page on port 8080"
cd /home/ros/www && python3 -m http.server 8080 &
HTTP_PID=$!

# --- Gazebo Harmonic simulation server ---
# On GPU nodes: use --headless-rendering for GPU lidar ray-casting.
# On CPU nodes: llvmpipe renders the sensor, no GPU needed.
# The combined gz sim -r (server+GUI) crashes with MinimalScene on both
# GPU (gz-gui-vendor-0.0.5 QML bug) and CPU (same crash with llvmpipe).
# Server-only is the stable approach; RViz viz pod provides visualization.
echo "[Gazebo] Starting gz sim server: ${WORLD_FILE}"
if [ "${GPU_MODE}" = "true" ]; then
  gz sim -s -r --headless-rendering "${WORLD_FILE}" &
else
  gz sim -s -r "${WORLD_FILE}" &
fi
GZ_SERVER_PID=$!
GUI_PID=${GZ_SERVER_PID}
sleep 10

# --- ros_gz_bridge ---
echo "[Bridge] Starting ros_gz_bridge"
ros2 run ros_gz_bridge parameter_bridge \
  --ros-args \
  -p config_file:=/home/ros/gz-bridge/bridge.yaml &
BRIDGE_PID=$!
sleep 3

# --- robot_state_publisher ---
echo "[RSP] Starting robot_state_publisher"
URDF_FILE=$(find /usr/lib64/ros-jazzy /usr/share -name "turtlebot3_waffle.urdf" 2>/dev/null | head -1 || true)
if [ -n "${URDF_FILE}" ]; then
  ros2 run robot_state_publisher robot_state_publisher \
    --ros-args -p robot_description:="$(cat "${URDF_FILE}")" &
  RSP_PID=$!
else
  echo "[RSP] Warning: turtlebot3_waffle.urdf not found — skipping robot_state_publisher"
fi

echo "=== Gazebo pod ready ==="
echo "  Robot:        ${ROBOT_LABEL}"
echo "  Simulation:   ${WORLD_FILE}"
echo "  Landing page: port 8080"
[ "${GPU_MODE}" = "false" ] && echo "  noVNC:        port 6080"

wait -n ${GZ_SERVER_PID} ${BRIDGE_PID} ${HTTP_PID} || true
echo "A child process exited — shutting down"
kill ${GZ_SERVER_PID} ${BRIDGE_PID} ${HTTP_PID} 2>/dev/null || true
[ -n "${XVFB_PID}" ] && kill ${XVFB_PID} 2>/dev/null || true
