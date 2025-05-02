# Configure Tilt to use local k3d cluster and apply K8s YAMLs
default_registry = 'localhost:53882'
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
      sync('./fern-reporter', '/app'),  #Sync source from inside context
      run('go build -o server', trigger=['**/*.go'])
    ])

# Build the React/Vite frontend image with live updates
docker_build('fern-ui', './fern-ui',
    dockerfile='./fern-ui/Dockerfile',
    live_update=[
      sync('./fern-ui', '/app'),
      run('npm install', trigger=['package.json', 'package-lock.json']),
    ])


# Define resources and port-forwarding
k8s_resource('postgres', port_forwards=5432)
k8s_resource('fern-reporter', port_forwards=8080)
k8s_resource('fern-ui', port_forwards='9091:5173')