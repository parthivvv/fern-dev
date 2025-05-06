#!/bin/bash

set -e

# Configuration variables
FERN_UI_REPO="https://github.com/guidewire-oss/fern-ui.git"  # Replace with actual repo URL
FERN_REPORTER_REPO="https://github.com/guidewire-oss/fern-reporter.git"  # Replace with actual repo URL
WORK_DIR="$HOME/fern-dev"
K3D_CLUSTER_NAME="mycluster"
REGISTRY_PORT="5000"
TILT_VERSION="0.33.0"  # Latest as of 2025, adjust if needed
K3D_VERSION="v5.7.4"   # Latest as of 2025, adjust if needed

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Function to print messages
log() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

# Check for required tools
check_requirements() {
    log "Checking for required tools..."
    for cmd in git curl docker kubectl; do
        if ! command -v "$cmd" &> /dev/null; then
            error "$cmd is required but not installed."
        fi
    done
}

# Install k3d
install_k3d() {
    if ! command -v k3d &> /dev/null; then
        log "Installing k3d..."
        curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | TAG=${K3D_VERSION} bash
        if ! command -v k3d &> /dev/null; then
            error "Failed to install k3d."
        fi
    fi
}

# Install Tilt
install_tilt() {
    if ! command -v tilt &> /dev/null; then
        log "Installing Tilt..."
        curl -fsSL https://github.com/tilt-dev/tilt/releases/download/v${TILT_VERSION}/tilt.${TILT_VERSION}.linux.x86_64.tar.gz | tar -xzv tilt
        sudo mv tilt /usr/local/bin/tilt
        if ! command -v tilt &> /dev/null; then
            error "Failed to install Tilt."
        fi
    fi
}

# Create directory structure
setup_directories() {
    log "Setting up directory structure..."
    mkdir -p "$WORK_DIR"
    mkdir -p "$WORK_DIR/k8s"
    cd "$WORK_DIR"
}

# Clone repositories
clone_repos() {
    log "Cloning repositories..."
    if [ ! -d "fern-ui" ]; then
        git clone "$FERN_UI_REPO" fern-ui || error "Failed to clone fern-ui repository."
    fi
    if [ ! -d "fern-reporter" ]; then
        git clone "$FERN_REPORTER_REPO" fern-reporter || error "Failed to clone fern-reporter repository."
    fi
}

# Create Kubernetes YAMLs
create_k8s_yamls() {
    log "Creating Kubernetes YAML files..."

    # fern-ui-deployment.yaml
    cat > k8s/fern-ui-deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fern-ui
  labels:
    app: fern-ui
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fern-ui
  template:
    metadata:
      labels:
        app: fern-ui
    spec:
      containers:
      - name: fern-ui
        image: fern-ui:dev
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 5173  # Vite's default dev port
        env:
        - name: VITE_API_URL
          value: "http://fern-reporter:8080"
EOF

    # fern-ui-service.yaml
    cat > k8s/fern-ui-service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: fern-ui
spec:
  selector:
    app: fern-ui
  ports:
  - port: 9091
    targetPort: 5173
EOF

    # fern-reporter-deployment.yaml
    cat > k8s/fern-reporter-deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fern-reporter
  labels:
    app: fern-reporter
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fern-reporter
  template:
    metadata:
      labels:
        app: fern-reporter
    spec:
      containers:
      - name: fern-reporter
        image: fern-reporter:dev
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8080
        env:
        - name: DB_URL
          value: "postgres://fern:fern@postgres:5432/fern?sslmode=disable"
EOF

    # fern-reporter-service.yaml
    cat > k8s/fern-reporter-service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: fern-reporter
spec:
  selector:
    app: fern-reporter
  ports:
  - port: 8080
    targetPort: 8080
EOF

    # postgres-deployment.yaml
    cat > k8s/postgres-deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  labels:
    app: postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:15-alpine
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_USER
          value: "devuser"
        - name: POSTGRES_PASSWORD
          value: "devpass"
        - name: POSTGRES_DB
          value: "devdb"
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
      volumes:
      - name: postgres-data
        persistentVolumeClaim:
          claimName: postgres-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

    # postgres-service.yaml
    cat > k8s/postgres-service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector:
    app: postgres
  ports:
  - port: 5432
    targetPort: 5432
EOF
}

# Create Tiltfile
create_tiltfile() {
    log "Creating Tiltfile..."
    cat > Tiltfile << 'EOF'
# Configure Tilt to use local k3d cluster and apply K8s YAMLs
default_registry = 'localhost:5000'

k8s_yaml('k8s/postgres-deployment.yaml')
k8s_yaml('k8s/postgres-service.yaml')
k8s_yaml('k8s/fern-reporter-deployment.yaml')
k8s_yaml('k8s/fern-reporter-service.yaml')
k8s_yaml('k8s/fern-ui-deployment.yaml')
k8s_yaml('k8s/fern-ui-service.yaml')

# Build the Go backend image with live code updates
docker_build('fern-reporter', './fern-reporter',
    dockerfile='./fern-reporter/Dockerfile-local',
    live_update=[
        sync('./fern-reporter', '/app'),
        run('go build -o fern', trigger=['**/*.go'])
    ])

# Build the React/Vite frontend image with live updates
docker_build('fern-ui', './fern-ui',
    dockerfile='./fern-ui/Dockerfile',
    live_update=[
        sync('./fern-ui', '/app/refine'),
        run('npm install', trigger=['package.json', 'package-lock.json']),
    ])

# Define resources and port-forwarding
k8s_resource('postgres', port_forwards=5432)
k8s_resource('fern-reporter', port_forwards=8080)
k8s_resource('fern-ui', port_forwards='9091:5173')
EOF
}

# Create Dockerfiles
create_dockerfiles() {
    log "Creating Dockerfiles..."

    # fern-reporter Dockerfile-local
    cat > fern-reporter/Dockerfile-local << 'EOF'
# Stage 1: Build
FROM --platform=${BUILDPLATFORM} golang:1.24-bookworm AS build-env

ARG TARGETOS
ARG TARGETARCH

ENV CGO_ENABLED=0 \
    GO111MODULE=on

RUN apt-get update && apt-get install -y ca-certificates git gcc libc6-dev

WORKDIR /app

COPY go.mod go.sum ./
RUN GOPROXY=https://goproxy.io go mod tidy && GOPROXY=https://goproxy.io go mod download

COPY . .
COPY config/config.yaml ./
RUN mkdir ./migrations
COPY pkg/db/migrations ./migrations/

RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -o fern .

# Stage 2: Runtime image
FROM --platform=${TARGETPLATFORM} debian:bookworm-slim
WORKDIR /app

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=build-env /app/fern /app/
COPY --from=build-env /app/config.yaml /app/
RUN mkdir /app/migrations
COPY --from=build-env /app/migrations /app/migrations/

EXPOSE 8080
ENTRYPOINT ["/app/fern"]
EOF

    # fern-ui Dockerfile
    cat > fern-ui/Dockerfile << 'EOF'
FROM --platform=${BUILDPLATFORM} node:18-slim AS base

WORKDIR /app/refine
COPY package.json package-lock.json ./
RUN npm install

COPY . .
RUN npm run build

EXPOSE 5173
CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0", "--port", "5173"]
EOF


# Setup k3d cluster
setup_k3d_cluster() {
    log "Setting up k3d cluster..."
    k3d cluster delete "$K3D_CLUSTER_NAME" || true
    k3d cluster create "$K3D_CLUSTER_NAME" \
        --registry-create myregistry \
        --port "${REGISTRY_PORT}:5000@server:0" \
        --api-port 6443 \
        --servers 1 \
        --agents 0
    log "Waiting for cluster to be ready..."
    sleep 10
    kubectl cluster-info
}

# Run Tilt
run_tilt() {
    log "Starting Tilt..."
    tilt up
}

main() {
    check_requirements
    install_k3d
    install_tilt
    setup_directories
    clone_repos
    create_k8s_yamls
    create_tiltfile
    create_dockerfiles
    setup_k3d_cluster
    run_tilt
}

main