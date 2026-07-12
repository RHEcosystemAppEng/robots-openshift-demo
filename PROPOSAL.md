# Robot Demo on OpenShift — Architecture Proposal

**Stack:** Fedora 43 · ROS2 Jazzy · Gazebo Harmonic · Zenoh DDS Bridge  
**Phase 1:** Single TurtleBot3 Waffle with GPU lidar + SLAM + autonomous patrol  
**Phase 2:** Multi-robot fleet (same architecture, Kustomize overlays)

---

## Reference Work

This proposal builds on two existing repositories:

| Repository | Branch / Path | What we take from it |
|---|---|---|
| [jianrongzhang89/ros2-zenoh-demo](https://github.com/jianrongzhang89/ros2-zenoh-demo/tree/ros2-zenoh-gpu-slam/k8s) | `ros2-zenoh-gpu-slam / k8s/` | GPU lidar SDF pattern, SLAM Toolbox config, Nav2 params, patrol mission, OpenShift YAML structure, init-container TCP probe, `restricted-v2` SCC approach |
| [lokeshrangineni/ros2-openshift-demo](https://github.com/lokeshrangineni/ros2-openshift-demo/tree/main/examples/distributed-zenoh) | `examples/distributed-zenoh/` | Fedora 43 base image, COPR `tavie/ros2` repo, noVNC display stack, GPU-optional llvmpipe fallback, entrypoint script pattern |

---

## Architecture: Phase 1 (Single Robot)

```
                        Browser
                           │
            ┌──────────────┴──────────────┐
            ▼                             ▼
    Route: gzweb (HTTPS)         Route: novnc (WSS)
    landing page                  Gazebo GUI via noVNC
            │                             │
    Svc: gzweb:8080              Svc: novnc:6080
            └──────────────┬──────────────┘
                           │
              ┌────────────────────────────────────┐
              │          Pod: gazebo-sim            │
              │                                     │
              │  [gazebo]                           │
              │   Xvfb :99 → x11vnc → websockify   │
              │   gz sim -r tb3_waffle_gpu.sdf      │
              │   robot_state_publisher (URDF)      │
              │   ros_gz_bridge (scan/odom/tf/clock)│
              │   python3 -m http.server 8080       │
              │          │ DDS (LOCALHOST only)     │
              │  [zenoh-bridge-ros2dds] sidecar     │
              └──────────────┬──────────────────────┘
                             │ Zenoh TCP/7447
                   Svc: zenoh-router:7447
                             │
              Deployment: zenoh-router
              (eclipse/zenoh daemon, 1–2 replicas)
                             │ Zenoh TCP/7447
              ┌────────────────────────────────────┐
              │          Pod: robot-nav             │
              │                                     │
              │  [nav2]                             │
              │   slam_toolbox (online async)       │
              │   nav2_bringup (DWB + BT + smoother)│
              │   patrol.py (nav2_simple_commander) │
              │          │ DDS (LOCALHOST only)     │
              │  [zenoh-bridge-ros2dds] sidecar     │
              └────────────────────────────────────┘
```

### Data Flows

| Direction | Topics | Path |
|---|---|---|
| Gazebo → Nav2 | `/scan`, `/odom`, `/tf`, `/tf_static`, `/clock`, `/imu` | gz sim → ros_gz_bridge → DDS → zenoh-bridge → Zenoh TCP → zenoh-router → zenoh-bridge → DDS → slam_toolbox + nav2 |
| Nav2 → Gazebo | `/cmd_vel` | nav2 → DDS → zenoh-bridge → Zenoh TCP → zenoh-router → zenoh-bridge → DDS → ros_gz_bridge → gz sim |
| Browser visual | Gazebo GUI frames | Xvfb → x11vnc (5900) → websockify (6080) → Route → noVNC in browser |

---

## Architecture: Phase 2 (Multi-Robot Fleet)

Each robot gets its own `gazebo-sim` + `robot-nav` Deployment pair, connected to a **shared central Zenoh router**. Robots are isolated by ROS2 topic namespace prefix (`/robot_1/scan`, `/robot_2/scan`, etc.) — not by separate domain IDs — so the router serves the whole fleet and fleet-level monitoring is straightforward.

```
              Deployment: zenoh-router  (scale replicas for throughput)
                    │
       ┌────────────┼────────────┐
       │            │            │
 Pod: robot-1-sim  Pod: robot-2-sim  …  Pod: robot-N-sim
 (ROBOT_NAME=robot_1)  (ROBOT_NAME=robot_2)
       │            │
 Pod: robot-1-nav  Pod: robot-2-nav
 (all topics under /robot_1/…)   (all topics under /robot_2/…)
```

Robot instances share the same Gazebo **world** (warehouse SDF); each spawns at a distinct initial pose passed via `GZ_SPAWN_POSE_X/Y/THETA` env vars.

---

## Container Images

Two separate images, both based on **Fedora 43** via the COPR `tavie/ros2` repository.

### Image 1: `robot-demo-gazebo`

**Full name:** `quay.io/jianrzha/robot-demo-gazebo:latest`  
**Built from:** `Containerfile.gazebo`

| Layer | Contents |
|---|---|
| Base | `registry.fedoraproject.org/fedora:43` |
| COPR | `tavie/ros2` (ROS2 Jazzy + Gazebo Harmonic for Fedora) |
| ROS2 packages | `ros-jazzy-ros-base`, `ros-jazzy-ros-gz-bridge`, `ros-jazzy-ros-gz-sim`, `ros-jazzy-gz-sim-vendor`, `ros-jazzy-nav2-minimal-tb3-sim`, `ros-jazzy-robot-state-publisher` |
| GPU / Mesa | `mesa-libGL`, `mesa-libEGL`, `mesa-dri-drivers`, `mesa-vulkan-drivers` |
| Display stack | `xorg-x11-server-Xvfb`, `x11vnc`, `novnc`, `python3-websockify`, `openbox` |
| Infra | `python3`, Gazebo symlink workarounds for Fedora packaging paths |
| OpenShift | UID 1001, GID 0, group-writable `/tmp/ros-home` |
| Entrypoint | `entrypoints/entrypoint-gazebo.sh` (selected via `command:` in Deployment) |

**What it runs:**
1. GPU detection → set `LIBGL_ALWAYS_SOFTWARE` / `GALLIUM_DRIVER=llvmpipe` if no NVIDIA present
2. `Xvfb :99` virtual framebuffer (1280×720)
3. `openbox` + `x11vnc` + `websockify` (noVNC on port 6080)
4. `python3 -m http.server 8080` serving `www/` (landing page with noVNC link)
5. `gz sim -r -s --headless-rendering tb3_waffle_gpu.sdf` (server, no display needed)
6. `ros_gz_bridge parameter_bridge` (bidirectional topic translation)
7. `robot_state_publisher` (publishes `/tf_static` for TurtleBot3 URDF joints)
8. `gz sim -g` GUI client (connects to server, renders into Xvfb)

### Image 2: `robot-demo-nav2`

**Full name:** `quay.io/jianrzha/robot-demo-nav2:latest`  
**Built from:** `Containerfile.nav2`

| Layer | Contents |
|---|---|
| Base | `registry.fedoraproject.org/fedora:43` |
| COPR | `tavie/ros2` |
| ROS2 packages | `ros-jazzy-ros-base`, `ros-jazzy-navigation2`, `ros-jazzy-nav2-bringup`, `ros-jazzy-nav2-simple-commander`, `ros-jazzy-slam-toolbox`, `ros-jazzy-rmw-cyclonedds-cpp`, `python3-numpy` |
| OpenShift | UID 1001, GID 0, group-writable `/tmp/ros-home` |
| Entrypoint | `entrypoints/entrypoint-nav2.sh` |

**What it runs:**
1. Waits for Zenoh router (init container TCP probe)
2. `slam_toolbox` — online async mode, builds map in real time from `/scan`
3. `nav2_bringup` — DWB local planner, NavFn global planner, BT navigator, velocity smoother, collision monitor (`use_sim_time: true`)
4. `patrol.py` — nav2_simple_commander waypoint patrol loop (4-waypoint warehouse route)

### Third-party images (not built in this repo)

| Image | Used by | Notes |
|---|---|---|
| `eclipse/zenoh:1.x.x` | `zenoh-router` Deployment | Pinned version tag — not `:latest` |
| `eclipse/zenoh-bridge-ros2dds:1.x.x` | sidecar in all app pods | Pinned; `1.x.x` must match the `zenoh` router version |

---

## GPU and Hardware Requirements

### Why GPU lidar?

TurtleBot3 Waffle uses a 360° LDS-01 planar lidar. In Gazebo Harmonic the default `gpu_lidar` sensor type routes ray-casting through the OGRE2 rendering pipeline on the GPU, producing realistic depth data at simulation speed. Without a GPU the same sensor can be declared as `lidar` (CPU ray-casting) but runs ~10× slower, making SLAM and Nav2 timing unreliable at real-time factors > 0.3.

The Gazebo SDF (`config/worlds/tb3_waffle_gpu.sdf`) declares the TurtleBot3 lidar as:
```xml
<sensor name="lidar" type="gpu_lidar">
  ...
  <horizontal><samples>360</samples></horizontal>
</sensor>
```

### GPU node requirements

| GPU | Instance type | VRAM | Notes |
|---|---|---|---|
| NVIDIA A10G | AWS `g5.2xlarge` | 24 GB | Tested in reference repo |
| NVIDIA L40S | AWS `g6e.2xlarge` | 48 GB | Higher throughput for multi-robot |
| Any CUDA 12+ GPU | bare-metal | ≥ 8 GB | On-prem OpenShift clusters |

OpenShift GPU prerequisites:
- NVIDIA GPU Operator installed
- Node labeled and tainted with `nvidia.com/gpu.present=true`
- Deployment tolerates `nvidia.com/gpu` and requests `nvidia.com/gpu: "1"` on the `gazebo` container

### CPU-only fallback (development mode)

The `entrypoint-gazebo.sh` detects GPU availability at runtime:
```bash
if nvidia-smi &>/dev/null; then
  export LIBGL_ALWAYS_SOFTWARE=0
else
  export LIBGL_ALWAYS_SOFTWARE=1
  export GALLIUM_DRIVER=llvmpipe
  # downgrade to cpu_ray sensor via GZ_SIM_WORLD override
  export GZ_WORLD=tb3_waffle_cpu.sdf
fi
```
A second world file (`config/worlds/tb3_waffle_cpu.sdf`) uses `type="lidar"` for development on clusters without GPU nodes. SLAM still functions; expect RTF ≈ 0.2–0.4.

---

## Zenoh Configuration

### Topology: central router + client sidecars

```
gazebo-sim pod                         robot-nav pod
┌──────────────────────┐              ┌──────────────────────┐
│ zenoh-bridge sidecar │◄── TCP/7447 ─► zenoh-bridge sidecar │
│  mode: client        │              │  mode: client        │
│  connect: zenoh-     │              │  connect: zenoh-     │
│    router:7447       │              │    router:7447       │
└──────────────────────┘              └──────────────────────┘
             │                                   │
             └──────────────┬────────────────────┘
                            ▼
                   Deployment: zenoh-router
                   Service: zenoh-router:7447
                   (eclipse/zenoh, listen 0.0.0.0:7447)
```

Both sidecars connect as `client` to the central router. The router is the only pod that listens; it requires no peer discovery. Adding robot N means adding two more pods that also connect as clients — no topology change.

### Key Zenoh settings

| Setting | Value | Reason |
|---|---|---|
| `scouting.multicast.enabled` | `false` | Kubernetes CNI does not route multicast between pods |
| `transport.unicast.lowlatency` | `true` | Reduces `/clock` forwarding jitter for `use_sim_time` |
| `connect.endpoints` | `["tcp/zenoh-router:7447"]` | Kubernetes DNS resolves the Service name |
| retry | exponential 1 s → 16 s, no exit | Nav2 pod tolerates Gazebo starting later |

---

## OpenShift Compliance

All pods target the `restricted-v2` SCC — no custom SecurityContextConstraints needed.

| Requirement | How met |
|---|---|
| Non-root UID | UID 1001 created in Containerfile; `runAsUser: 1001` in pod spec |
| GID 0 group | All writable dirs owned `1001:0`, mode `0775`; `fsGroup: 0` in pod spec |
| No privilege escalation | `allowPrivilegeEscalation: false` on all containers |
| No root capabilities | `capabilities: drop: [ALL]` on all containers |
| Read-only root FS | `readOnlyRootFilesystem: true`; all writes go to `/tmp/ros-home` (emptyDir) |
| Writable scratch space | `emptyDir` volume mounted at `/tmp/ros-home`; entrypoints export `HOME`, `ROS_HOME`, `GZ_HOME`, `GZ_CACHE` pointing here |

---

## Repository Layout

```
robots-openshift-demo/
│
├── Containerfile.gazebo          # robot-demo-gazebo image
├── Containerfile.nav2            # robot-demo-nav2 image
├── Makefile                      # build / push / deploy targets
│
├── entrypoints/
│   ├── entrypoint-gazebo.sh      # GPU detect → Xvfb → noVNC → gz sim → ros_gz_bridge
│   └── entrypoint-nav2.sh        # wait-for-zenoh → slam_toolbox → nav2 → patrol
│
├── config/
│   ├── worlds/
│   │   ├── tb3_waffle_gpu.sdf    # TurtleBot3 Waffle world, gpu_lidar sensor
│   │   └── tb3_waffle_cpu.sdf    # Same world, cpu lidar (dev fallback)
│   ├── nav2/
│   │   ├── slam_params.yaml      # slam_toolbox: online_async, Ceres solver
│   │   └── nav2_params.yaml      # DWB controller, NavFn, BT navigator, costmaps
│   ├── patrol/
│   │   └── patrol.py             # 4-waypoint patrol loop (nav2_simple_commander)
│   ├── zenoh/
│   │   ├── zenoh-router.json5    # router: listen tcp/0.0.0.0:7447, no multicast
│   │   ├── zenoh-gazebo.json5    # client: connect zenoh-router:7447
│   │   └── zenoh-nav2.json5      # client: connect zenoh-router:7447, retry backoff
│   ├── gz-bridge/
│   │   └── bridge.yaml           # ros_gz_bridge topic list (scan, odom, tf, clock, cmd_vel)
│   └── www/
│       └── index.html            # noVNC landing page (auto-connect link)
│
└── k8s/
    ├── base/                     # Phase 1: single robot
    │   ├── namespace.yaml
    │   ├── serviceaccount.yaml
    │   ├── configmap-worlds.yaml        # tb3_waffle_gpu.sdf + tb3_waffle_cpu.sdf
    │   ├── configmap-nav2.yaml          # slam_params.yaml + nav2_params.yaml
    │   ├── configmap-zenoh.yaml         # all three .json5 files
    │   ├── configmap-gz-bridge.yaml     # bridge.yaml
    │   ├── configmap-www.yaml           # index.html
    │   ├── deployment-zenoh-router.yaml
    │   ├── deployment-gazebo.yaml       # 2 containers: gazebo + zenoh-bridge
    │   ├── deployment-nav2.yaml         # 2 containers: nav2 + zenoh-bridge
    │   ├── service-zenoh-router.yaml    # ClusterIP TCP/7447
    │   ├── service-novnc.yaml           # ClusterIP TCP/6080
    │   ├── service-gzweb.yaml           # ClusterIP TCP/8080
    │   ├── route-novnc.yaml             # edge TLS, WSS, timeout 24h
    │   └── route-gzweb.yaml             # edge TLS, HTTPS
    │
    └── multi-robot/              # Phase 2: N robots via Kustomize
        ├── kustomization.yaml
        ├── patch-robot-1.yaml    # name prefix, initial pose, ROBOT_NAME=robot_1
        └── patch-robot-2.yaml    # name prefix, initial pose, ROBOT_NAME=robot_2
```

---

## Makefile Targets

```makefile
REGISTRY   ?= quay.io/jianrzha
# To use team registry: make build REGISTRY=quay.io/myteam
VERSION    ?= latest
PLATFORM   ?= linux/amd64

IMAGE_GAZEBO = $(REGISTRY)/robot-demo-gazebo:$(VERSION)
IMAGE_NAV2   = $(REGISTRY)/robot-demo-nav2:$(VERSION)

build:         ## Build both images
build-gazebo:  ## Build gazebo image only
build-nav2:    ## Build nav2 image only
push:          ## Push both images
deploy:        ## Apply k8s/base/ manifests (oc apply)
undeploy:      ## Delete namespace
mirror-zenoh:  ## skopeo copy pinned zenoh images to $(REGISTRY)
```

Registry switch for the team: `make build push REGISTRY=quay.io/<team-org>`

---

## Deployment Resource Budget (Single Robot)

| Pod | Container | CPU req/limit | RAM req/limit | GPU |
|---|---|---|---|---|
| zenoh-router | zenoh | 100m / 500m | 128Mi / 512Mi | — |
| gazebo-sim | gazebo | 2 / 4 | 4Gi / 8Gi | 1 |
| gazebo-sim | zenoh-bridge | 200m / 500m | 128Mi / 256Mi | — |
| robot-nav | nav2 | 1 / 2 | 2Gi / 4Gi | — |
| robot-nav | zenoh-bridge | 200m / 500m | 128Mi / 256Mi | — |
| **Total** | | **3.5 / 7.5 CPU** | **6.5Gi / 13Gi** | **1 GPU** |

---

## Implementation Phases

### Phase 1: Single Robot (MVP)

| Step | Deliverable |
|---|---|
| 1 | `Containerfile.gazebo` — Fedora 43, GPU/Mesa, display stack, ros_gz packages |
| 2 | `Containerfile.nav2` — Fedora 43, Nav2, SLAM Toolbox |
| 3 | `config/worlds/tb3_waffle_gpu.sdf` — TurtleBot3 Waffle world with `gpu_lidar` sensor |
| 4 | `config/worlds/tb3_waffle_cpu.sdf` — same world with CPU lidar for dev |
| 5 | `entrypoints/entrypoint-gazebo.sh` — GPU detect, Xvfb, noVNC, gz sim, ros_gz_bridge |
| 6 | `entrypoints/entrypoint-nav2.sh` — SLAM, Nav2, patrol |
| 7 | `config/nav2/` — slam_params.yaml, nav2_params.yaml tuned for TurtleBot3 Waffle |
| 8 | `config/zenoh/` — router + two client configs |
| 9 | `k8s/base/` — all manifests (namespace through routes) |
| 10 | `Makefile` — build, push, deploy targets with REGISTRY variable |
| 11 | `README.md` — prerequisites, build, deploy, access instructions |

**Acceptance criteria for Phase 1:**
- Robot spawns in Gazebo warehouse world
- SLAM Toolbox builds a map live; map grows as robot moves
- Nav2 drives the robot autonomously through a 4-waypoint patrol loop
- Gazebo GUI is visible in browser via noVNC Route
- All pods run under `restricted-v2` SCC with no warnings

### Phase 2: Multi-Robot Fleet

| Step | Deliverable |
|---|---|
| 1 | Add `ROBOT_NAME` / `ROBOT_NAMESPACE` env var support to both entrypoints (topic prefix `/$(ROBOT_NAME)/…`) |
| 2 | Patch TurtleBot3 spawn to use `GZ_SPAWN_POSE_X/Y/THETA` env vars |
| 3 | `k8s/multi-robot/` — Kustomize overlays for robot-1 and robot-2 |
| 4 | Scale `zenoh-router` to 2 replicas behind the Service |
| 5 | Optional: replace noVNC with GzWeb for a shared 3D view of all robots |
| 6 | Optional: Prometheus sidecar + Grafana dashboard for fleet telemetry |

---

## Open Questions Resolved

| Question | Decision |
|---|---|
| Robot model | **TurtleBot3 Waffle** — available in Fedora COPR, well-tested Nav2 params, clean URDF/SDF |
| Lidar type | **GPU lidar** (`type="gpu_lidar"` in SDF) with CPU lidar SDF as dev fallback |
| Container registry | **`quay.io/jianrzha/`** default; switch via `REGISTRY=quay.io/<team-org>` in Makefile |
| Navigation approach | **SLAM Toolbox** (online async) — no pre-baked map required, builds map on first run |
| Image strategy | **Two images** (`robot-demo-gazebo`, `robot-demo-nav2`) — separate build/update cycles |

---

## Key Differences from Reference Repositories

| Concern | jianrongzhang89 reference | lokeshrangineni reference | **This project** |
|---|---|---|---|
| Base OS | UBI9 (ROS2), Ubuntu Noble (Gazebo/Nav2) | Fedora 43 | **Fedora 43** throughout |
| Images | 3 images (ros2, gazebo, nav2) | 1 image | **2 images** (gazebo, nav2) |
| Robot | Custom warehouse diff-drive | TurtleBot3 Waffle | **TurtleBot3 Waffle** |
| Lidar | GPU lidar (custom SDF) | CPU lidar (TurtleBot3 default) | **GPU lidar** in TurtleBot3 Waffle SDF |
| Navigation | SLAM + Nav2 + patrol | Nav2 + AMCL (pre-built map) | **SLAM + Nav2 + patrol** |
| Display | GzWeb + websocket | noVNC (VNC) | **noVNC** phase 1, GzWeb optional phase 2 |
| Zenoh topology | Central router + sidecars | Gazebo pod as router + Nav2 as peer | **Central router Deployment + client sidecars** (scales to N robots) |
| Multi-robot | Not implemented | Not implemented | **Kustomize overlays** in phase 2 |
| Registry | quay.io/jianrzha | quay.io/lrangine | **quay.io/jianrzha** (default), switchable |
