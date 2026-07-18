#!/bin/bash
set -eo pipefail

export HOME=/tmp/ros-home
export ROS_HOME=/tmp/ros-home

mkdir -p /tmp/ros-home /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix 2>/dev/null || true

source /usr/lib64/ros-jazzy/setup.bash

echo "=== Robot Demo: Viz pod starting ==="

# --- Xvfb virtual framebuffer ---
if nvidia-smi &>/dev/null 2>&1; then
  export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
fi
Xvfb :99 -screen 0 1366x768x24 -ac +extension GLX +render -noreset &
XVFB_PID=$!
unset __EGL_VENDOR_LIBRARY_FILENAMES
sleep 3

export DISPLAY=:99
openbox &
sleep 1

# --- noVNC ---
echo "[VNC] Starting x11vnc + noVNC on port 6080"
# -noxdamage: poll for screen changes instead of relying on XDamage extension.
# Required for OpenGL/llvmpipe content which doesn't signal XDamage properly.
x11vnc -display :99 -nopw -rfbport 5900 -listen 0.0.0.0 -forever -quiet -noxdamage -ncache 0 &
X11VNC_PID=$!
sleep 2
websockify --web /usr/share/novnc 6080 localhost:5900 &
NOVNC_PID=$!

# --- TF relay: merge /robot_1/tf + /robot_2/tf → /tf for RViz ───────────────
echo "[TF] Starting tf_relay (merging robot_1 + robot_2 TF into /tf)"
python3 /usr/local/lib/tf_relay.py &
TF_RELAY_PID=$!

# --- Wait for /robot_1/map to arrive (confirms SLAM + Zenoh are working) -----
echo "[RViz] Waiting for /robot_1/map topic from Nav2 pod via Zenoh..."
for i in $(seq 1 120); do
  if { timeout 4 ros2 topic info /robot_1/map 2>/dev/null || true; } | grep -q "Publisher count: [1-9]"; then
    echo "[RViz] /robot_1/map detected (${i}x3 s waited)"
    break
  fi
  echo "[RViz]   ... no /robot_1/map yet (${i}/120)"
  sleep 3
done

# --- RViz2 ---
echo "[RViz] Starting RViz2 with nav2_demo config"
LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe \
  ros2 run rviz2 rviz2 -d /home/ros/rviz/nav2_demo.rviz &
RVIZ_PID=$!

echo "=== Viz pod ready ==="
echo "  noVNC: port 6080  (RViz2 showing both robots)"

wait -n ${RVIZ_PID} ${NOVNC_PID} ${X11VNC_PID} || true
echo "A child process exited — shutting down"
kill ${RVIZ_PID} ${NOVNC_PID} ${X11VNC_PID} ${TF_RELAY_PID} ${XVFB_PID} 2>/dev/null || true
