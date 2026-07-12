# Robot Demo on OpenShift

A ROS 2 / Gazebo simulation demo running on OpenShift with GPU acceleration, Zenoh bridging, and Nav2 autonomous navigation. See [PROPOSAL.md](PROPOSAL.md) for the full design rationale and phased roadmap.

---

## Overview

This demo runs a TurtleBot3 Waffle robot in a Gazebo Harmonic simulation, performs SLAM to build a map of the environment, and uses Nav2 to navigate autonomously — all inside an OpenShift cluster. Communication between pods is handled by the Zenoh pub/sub router and the zenoh-bridge-ros2dds sidecar, which replaces the standard DDS multicast that does not work across Kubernetes pod network boundaries.

**Stack:**
- ROS 2 Humble
- Gazebo Harmonic (GPU-accelerated via NVIDIA GPU Operator)
- Nav2 (SLAM Toolbox + Navigation2)
- Zenoh 1.0.4 + zenoh-bridge-ros2dds 1.0.4
- OpenShift 4.12+ / Kubernetes
- Kustomize for multi-robot overlays

---

## Prerequisites

| Requirement | Notes |
|---|---|
| OpenShift 4.12+ | GPU nodes required for Gazebo rendering |
| NVIDIA GPU Operator | Installed and healthy on the GPU node pool |
| `oc` CLI | Logged in with `cluster-admin` or project admin rights |
| `podman` | For building and pushing images locally |
| `make` | GNU Make 4.x |
| `quay.io` account | Or any OCI-compatible registry |

Verify GPU operator status before deploying:

```bash
oc get pod -n nvidia-gpu-operator
oc describe node <gpu-node> | grep nvidia.com/gpu
```

---

## Quick Start

### 1. Build the images

```bash
# Build with the default registry (quay.io/jianrzha)
make build

# Or point at your own org
make build REGISTRY=quay.io/myteam
```

### 2. Push the images

```bash
podman login quay.io
make push

# Or
make push REGISTRY=quay.io/myteam
```

### 3. Grant the required SCC

The `eclipse/zenoh` and `eclipse/zenoh-bridge-ros2dds` images run as a non-root UID that is not in the OpenShift default SCC range. Grant the `nonroot` SCC to the service account:

```bash
oc adm policy add-scc-to-user nonroot \
  -z robot-demo \
  -n robot-demo
```

> **Why this is needed:** Zenoh images declare `USER 1000` and drop all capabilities, which is fine, but OpenShift's `restricted` SCC rejects any image that pins a specific UID rather than using the project-assigned UID range. The `nonroot` SCC allows UID 1000 while keeping all privilege restrictions in place.

### 4. Deploy

```bash
make deploy
```

This runs `oc apply -k k8s/base/` and creates the namespace, service account, configmaps, deployments, services, and routes.

### 5. Get the routes

```bash
oc get route -n robot-demo
```

You will see routes for the noVNC desktop (Gazebo visualization) and GzWeb. Copy the noVNC URL and open it in a browser.

### 6. Verify the simulation is running

Open the noVNC URL in a browser. You should see the Gazebo world with a TurtleBot3 Waffle. Nav2 starts automatically; the robot will begin building a SLAM map within ~30 seconds.

---

## Architecture

See [PROPOSAL.md](PROPOSAL.md) for the full design. At a high level, three pods cooperate:

```
┌──────────────────────┐        Zenoh        ┌──────────────────────┐
│   gazebo-sim pod     │◄───────router───────►│   robot-nav pod      │
│                      │      (port 7447)      │                      │
│  [gazebo]            │                      │  [nav2]              │
│  [zenoh-bridge]      │                      │  [zenoh-bridge]      │
└──────────────────────┘                      └──────────────────────┘
                                  ▲
                                  │
                       ┌──────────────────┐
                       │  zenoh-router    │
                       │  (eclipse/zenoh) │
                       └──────────────────┘
```

**Zenoh bridge pattern:** Each pod that runs ROS 2 nodes also runs a `zenoh-bridge-ros2dds` sidecar container. The sidecar discovers local ROS 2 topics via DDS on `localhost` and forwards them to the central Zenoh router. This replaces multicast DDS, which cannot cross Kubernetes pod network boundaries.

**Topic isolation (multi-robot):** Each robot's bridge is given a `ROS_NAMESPACE` environment variable (`/robot_1`, `/robot_2`, etc.). The bridge prefixes every bridged topic with that namespace, so `/scan` becomes `/robot_1/scan`, preventing topic collisions between robots sharing the same router.

---

## Pods and Images

| Pod | Image | Role |
|---|---|---|
| `zenoh-router` | `eclipse/zenoh:1.0.4` | Central message bus — all bridges connect here on port 7447 |
| `gazebo-sim` | `quay.io/jianrzha/robot-demo-gazebo:latest` | Gazebo Harmonic simulation + noVNC desktop + zenoh-bridge sidecar |
| `robot-nav` | `quay.io/jianrzha/robot-demo-nav2:latest` | Nav2 (SLAM Toolbox + Navigation2) + zenoh-bridge sidecar |

---

## Verification Commands

### Check that the scan topic is flowing

```bash
# Exec into the robot-nav pod and echo /scan
oc exec -n robot-demo -it deploy/robot-nav -c nav2 -- \
  bash -c "source /opt/ros/humble/setup.bash && ros2 topic echo /scan --once"
```

### Check the SLAM map topic

```bash
oc exec -n robot-demo -it deploy/robot-nav -c nav2 -- \
  bash -c "source /opt/ros/humble/setup.bash && ros2 topic hz /map"
```

You should see a rate around 0.1–1 Hz while SLAM is running.

### Check Zenoh router connectivity

```bash
# Router logs — look for "Session opened" lines from both bridges
oc logs -n robot-demo deploy/zenoh-router --tail=50

# Gazebo bridge logs
oc logs -n robot-demo deploy/gazebo-sim -c zenoh-bridge --tail=30

# Nav2 bridge logs
oc logs -n robot-demo deploy/robot-nav -c zenoh-bridge --tail=30
```

### Check pod status

```bash
oc get pods -n robot-demo -w
```

All pods should reach `Running` with `2/2` or `1/1` containers ready.

### Check Nav2 is active

```bash
oc exec -n robot-demo -it deploy/robot-nav -c nav2 -- \
  bash -c "source /opt/ros/humble/setup.bash && ros2 node list"
```

Expected nodes include `/slam_toolbox`, `/controller_server`, `/planner_server`, `/bt_navigator`.

---

## Registry Switch

To use your own registry instead of `quay.io/jianrzha`:

```bash
make build push REGISTRY=quay.io/<your-org>
```

Then update the image references in `k8s/base/` deployments to match, or pass the registry as a kustomize image override. For example, add to your own overlay's `kustomization.yaml`:

```yaml
images:
  - name: quay.io/jianrzha/robot-demo-gazebo
    newName: quay.io/<your-org>/robot-demo-gazebo
    newTag: latest
  - name: quay.io/jianrzha/robot-demo-nav2
    newName: quay.io/<your-org>/robot-demo-nav2
    newTag: latest
```

---

## GPU-Optional Dev Mode (llvmpipe Software Rendering)

If you do not have a GPU node, Gazebo can fall back to Mesa's `llvmpipe` software renderer. Performance is very low (~2–5 FPS) but sufficient for functional testing.

Create a kustomize patch (e.g., `k8s/overlays/cpu-dev/patch-cpu.yaml`) that removes the GPU resource requests and sets the world file:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gazebo-sim
  namespace: robot-demo
spec:
  template:
    spec:
      containers:
        - name: gazebo
          env:
            - name: WORLD_FILE
              value: /home/ros/worlds/turtlebot3_house_cpu.sdf
            - name: LIBGL_ALWAYS_SOFTWARE
              value: "1"
            - name: GALLIUM_DRIVER
              value: llvmpipe
      tolerations: []
```

And in the overlay `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: robot-demo
resources:
  - ../../base
patches:
  - path: patch-cpu.yaml
```

Deploy with:

```bash
oc apply -k k8s/overlays/cpu-dev/
```

The `WORLD_FILE` env var is read by `entrypoint-gazebo.sh` to select a lighter SDF without GPU-heavy physics plugins.

---

## Multi-Robot (Phase 2)

The `k8s/multi-robot/` overlay adds a second TurtleBot3 to the same Gazebo world. Robot 1 uses the existing base deployments; Robot 2 gets its own `gazebo-sim-robot-2` and `robot-nav-robot-2` Deployments.

```bash
oc apply -k k8s/multi-robot/
```

After rollout, verify both robots' scan topics are active:

```bash
# Robot 1
oc exec -n robot-demo -it deploy/gazebo-sim -c gazebo -- \
  bash -c "source /opt/ros/humble/setup.bash && ros2 topic hz /robot_1/scan"

# Robot 2
oc exec -n robot-demo -it deploy/gazebo-sim-robot-2 -c gazebo -- \
  bash -c "source /opt/ros/humble/setup.bash && ros2 topic hz /robot_2/scan"
```

Each robot gets its own SLAM map published on `/robot_1/map` and `/robot_2/map` respectively.

**Spawn poses:**
- Robot 1: x=-3.0, y=-3.0, theta=0.0
- Robot 2: x=3.0, y=3.0, theta=3.14159 (facing opposite direction)

---

## Troubleshooting

### Gazebo pod is CrashLoopBackOff or stuck in Init

**Symptom:** `oc get pods` shows `gazebo-sim` pod not reaching `Running`.

**Likely cause:** GPU not available on the scheduled node.

```bash
# Check events
oc describe pod -n robot-demo -l app=gazebo-sim

# Check GPU allocations on nodes
oc describe nodes | grep -A5 "nvidia.com/gpu"
```

If the GPU Operator is not installed or no GPU nodes exist, use the cpu-dev overlay described above.

### Nav2 not receiving `/scan` (no laser data)

**Symptom:** SLAM toolbox logs show no incoming scan data; `/scan` topic has no publishers.

**Likely cause:** The Zenoh bridge between `gazebo-sim` and `robot-nav` is not connected.

```bash
# Check the zenoh-router is running
oc get pod -n robot-demo -l app=zenoh-router

# Check bridge in gazebo-sim pod
oc logs -n robot-demo deploy/gazebo-sim -c zenoh-bridge | grep -i "error\|warn\|connect"

# Check bridge in robot-nav pod
oc logs -n robot-demo deploy/robot-nav -c zenoh-bridge | grep -i "error\|warn\|connect"
```

The bridges connect to `zenoh-router:7447`. Confirm the service resolves:

```bash
oc exec -n robot-demo -it deploy/gazebo-sim -c zenoh-bridge -- \
  nc -zv zenoh-router 7447
```

### SLAM not building a map

**Symptom:** `/map` topic exists but the map never fills in (stays empty or all unknown).

**Checklist:**
1. Confirm `/scan` is flowing (see above).
2. Confirm `/tf` and `/tf_static` are flowing — Nav2 needs the `odom -> base_footprint` transform chain.
3. Check SLAM Toolbox logs:
   ```bash
   oc logs -n robot-demo deploy/robot-nav -c nav2 | grep -i "slam\|map\|scan"
   ```
4. Confirm the robot is actually moving — a stationary robot will not build a useful map. Send a goal via the noVNC desktop or via:
   ```bash
   oc exec -n robot-demo -it deploy/robot-nav -c nav2 -- \
     bash -c "source /opt/ros/humble/setup.bash && \
       ros2 action send_goal /navigate_to_pose \
         nav2_msgs/action/NavigateToPose \
         '{pose: {header: {frame_id: map}, pose: {position: {x: 1.0, y: 0.0, z: 0.0}, orientation: {w: 1.0}}}}'"
   ```

### SCC / permission errors at pod startup

**Symptom:** Pod events show `unable to validate against any security context constraint`.

**Fix:** Re-run the SCC grant:

```bash
oc adm policy add-scc-to-user nonroot \
  -z robot-demo \
  -n robot-demo
```

Then delete the failed pods so they reschedule:

```bash
oc delete pod -n robot-demo -l app=zenoh-router
oc delete pod -n robot-demo -l app=gazebo-sim
oc delete pod -n robot-demo -l app=robot-nav
```

---

## Makefile Targets

```bash
make help
```

Key targets:

| Target | Description |
|---|---|
| `make build` | Build Gazebo and Nav2 images with podman |
| `make push` | Push images to the registry |
| `make deploy` | Apply `k8s/base/` via `oc apply -k` |
| `make deploy-multi` | Apply `k8s/multi-robot/` overlay |
| `make undeploy` | Delete all resources in the `robot-demo` namespace |
| `make logs` | Tail logs from all three pods simultaneously |
| `make status` | Show pod and route status |

Pass `REGISTRY=quay.io/<your-org>` to any target that builds or pushes images.
