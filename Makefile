## robot-demo – build, push, and deploy targets
## Default target: help

ORG           ?= jianrzha
VERSION       ?= latest
PLATFORM      ?= linux/amd64
NAMESPACE     ?= robot-demo
ZENOH_ORG     ?= ecosystem-appeng
ZENOH_VERSION ?= 1.9.0

IMAGE_GAZEBO        = quay.io/$(ORG)/robot-demo-gazebo:$(VERSION)
IMAGE_NAV2          = quay.io/$(ORG)/robot-demo-nav2:$(VERSION)
IMAGE_VIZ           = quay.io/$(ORG)/robot-demo-viz:$(VERSION)
IMAGE_ZENOH_ROUTER  = quay.io/$(ZENOH_ORG)/zenoh-router:$(ZENOH_VERSION)
IMAGE_ZENOH_BRIDGE  = quay.io/$(ZENOH_ORG)/zenoh-bridge-ros2dds:$(ZENOH_VERSION)

# ── Default target ────────────────────────────────────────────────────────────
.DEFAULT_GOAL := help

.PHONY: help build build-gazebo build-nav2 push push-gazebo push-nav2 \
        deploy undeploy mirror-zenoh set-image

# ── Auto-generated help (reads ## comments on targets) ───────────────────────
help: ## Show this help message
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n\nTargets:\n"} \
	     /^[a-zA-Z_-]+:.*##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

# ── Build ─────────────────────────────────────────────────────────────────────
build: build-gazebo build-nav2 build-viz ## Build all container images

build-gazebo: ## Build the Gazebo + noVNC image
	podman build --no-cache --platform $(PLATFORM) -f Containerfile.gazebo -t $(IMAGE_GAZEBO) .

build-nav2: ## Build the SLAM Toolbox + Nav2 image
	podman build --no-cache --platform $(PLATFORM) -f Containerfile.nav2 -t $(IMAGE_NAV2) .

build-viz: ## Build the RViz2 visualization image
	podman build --no-cache --platform $(PLATFORM) -f Containerfile.viz -t $(IMAGE_VIZ) .

# ── Push ──────────────────────────────────────────────────────────────────────
push: push-gazebo push-nav2 push-viz ## Push all images to the registry

push-gazebo: ## Push the Gazebo image
	podman push $(IMAGE_GAZEBO)

push-nav2: ## Push the Nav2 image
	podman push $(IMAGE_NAV2)

push-viz: ## Push the RViz2 visualization image
	podman push $(IMAGE_VIZ)

# ── Deploy / undeploy ─────────────────────────────────────────────────────────
deploy: ## Apply k8s/base/ manifests and print route URLs
	oc apply -f k8s/base/namespace.yaml
	@oc wait --for=jsonpath='{.status.phase}'=Active namespace/$(NAMESPACE) --timeout=30s
	oc apply -f k8s/base/
	@echo ""
	@echo "Routes in namespace $(NAMESPACE):"
	@oc get route -n $(NAMESPACE)

undeploy: ## Delete the $(NAMESPACE) namespace and all its resources
	oc delete namespace $(NAMESPACE)

restart-demo: ## Restart Gazebo + Nav2 simultaneously (required after any pod restart)
	@echo "Scaling both pods to 0..."
	oc scale deployment/gazebo-sim deployment/robot-nav -n $(NAMESPACE) --replicas=0
	@echo "Waiting 30 s for clean teardown..."
	@sleep 30
	@echo "Starting both pods together..."
	oc scale deployment/gazebo-sim deployment/robot-nav -n $(NAMESPACE) --replicas=1
	@echo "Done. Both pods starting simultaneously — Zenoh routes establish cleanly."
	@echo "Allow ~8 min for SLAM boot + Nav2 activation + first patrol."

# ── Zenoh mirroring ───────────────────────────────────────────────────────────
mirror-zenoh: ## Mirror Zenoh images from quay.io/ecosystem-appeng to quay.io/$(ORG)
	skopeo copy \
	    docker://$(IMAGE_ZENOH_ROUTER) \
	    docker://quay.io/$(ORG)/zenoh-router:$(ZENOH_VERSION)
	skopeo copy \
	    docker://$(IMAGE_ZENOH_BRIDGE) \
	    docker://quay.io/$(ORG)/zenoh-bridge-ros2dds:$(ZENOH_VERSION)

# ── CI image pinning ──────────────────────────────────────────────────────────
set-image: ## Sed-replace :latest tags in k8s/base/ with :$(VERSION) (for CI)
	sed -i 's|quay.io/$(ORG)/robot-demo-gazebo:latest|$(IMAGE_GAZEBO)|g' k8s/base/*.yaml
	sed -i 's|quay.io/$(ORG)/robot-demo-nav2:latest|$(IMAGE_NAV2)|g'     k8s/base/*.yaml
