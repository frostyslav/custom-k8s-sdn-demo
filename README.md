# Custom SDN solution for Kubernetes demo

## Start minikube

```bash
minikube start --network-plugin=cni --host-only-cidr='192.168.99.1/24' --extra-config=apiserver.insecure-port=8080 --extra-config=apiserver.insecure-bind-address=0.0.0.0
```

## Prepare Docker images

### Prepare docker env

#### Windows

```powershell
minikube docker-env | Invoke-Expression
```

#### Linux

```bash
eval $(minikube docker-env)
```

### Build Docker images

#### Build cni-driver-downloader

```bash
cd cni-driver
docker build -t cni-driver-downloader .
```

#### Build custom sdn-controller

```bash
cd sdn-controller
docker build -t sdn-controller .
```

## Deploy Kubernetes resources

### Deploy cni-driver-downloader Job

```bash
kubectl apply -f manifests/cni-driver-downloader.yaml
```

### Deploy sdn-controller DaemonSet

```bash
kubectl apply -f manifests/sdn-controller.yaml
```
