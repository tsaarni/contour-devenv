# Development environment for Contour

This project contains Vagrant based environment for developing and testing [Contour](https://projectcontour.io/).


## Preparations


Build `httpbin` container as it will be used in the tests as a backend service

```bash
docker build -t httpbin:latest docker/httpbin
```

Generate certificates and keys

```bash
mkdir -p ~/certs
cfssl genkey -initca configs/cfssl-csr-root-ca-server.json | cfssljson -bare ~/certs/server-root
cfssl genkey -initca configs/cfssl-csr-root-ca-client.json  | cfssljson -bare ~/certs/client-root
cfssl gencert -ca ~/certs/server-root.pem -ca-key ~/certs/server-root-key.pem configs/cfssl-csr-endentity-httpbin.json | cfssljson -bare ~/certs/httpbin
cfssl gencert -ca ~/certs/server-root.pem -ca-key ~/certs/server-root-key.pem configs/cfssl-csr-endentity-ingress-server.json | cfssljson -bare ~/certs/ingress-server
```

Create secrets with the certificates and keys

```bash
kubectl create secret generic httpbin-cert --from-file=$HOME/certs/httpbin.pem --from-file=$HOME/certs/httpbin-key.pem --from-file=$HOME/certs/client-root.pem
kubectl create secret tls ingress-server-cert --cert=$HOME/certs/ingress-server.pem --key=$HOME/certs/ingress-server-key.pem
kubectl create secret generic ingress-ca-cert --from-file=ca.crt=$HOME/certs/server-root.pem
```


Deploy contour and scale to 1 replicas for ease of troubleshooting

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcontour/contour/release-1.0/examples/render/contour.yaml
kubectl -n projectcontour scale deployment/contour --replicas=1
```


Alternatively run a local version

```bash
export DOCKER_HOST=tcp://localhost:2375
cd $CONTOUR_GIT_REPO
docker build -t localhost/contour:latest .
```

```bash
sed -i 's!image: docker.io/projectcontour/contour.*!image: localhost/contour:latest!' contour.yaml
kubectl apply -f contour.yaml
kubectl -n projectcontour scale deployment/contour --replicas=1
```


NOTE: not working currently, add manually to /etc/hosts instead

Assign hostname with [external-dns](https://github.com/kubernetes-sigs/external-dns)

```bash
kubectl -n projectcontour annotate service envoy "external-dns.alpha.kubernetes.io/hostname=host1.external.com"
```


Deploy `httpbin` as a backend service

```bash
kubectl apply -f httpbin-backend.yaml
```


Send requests to test TLS

```bash
http --verify=$HOME/certs/server-root.pem https://host1.external.com/status/418

echo Q | openssl s_client -connect host1.external.com:443 -servername host1.external.com | openssl x509 -text -noout
```

## Troubleshooting

### Contour

Contour logs

```bash
kubectl -n projectcontour logs $(kubectl -n projectcontour get pod -l app=contour -o jsonpath='{.items[0].metadata.name}') -f
```

Check status

```bash
kubectl get httpproxy,ingressroute
```


Debug API https://projectcontour.io/docs/master/troubleshooting/

```bash
kubectl -n projectcontour port-forward pod/$(kubectl -n projectcontour get pod -l app=contour -o jsonpath='{.items[0].metadata.name}') 6060
http localhost:6060/debug/dag | dot -Tpng -o dag.png

```

### Envoy

Envoy logs

```bash
kubectl -n projectcontour logs $(kubectl -n projectcontour get pod -l app=envoy -o jsonpath='{.items[0].metadata.name}') -f
```

Admin interface operations https://www.envoyproxy.io/docs/envoy/latest/operations/admin

```bash
kubectl -n projectcontour port-forward pod/$(kubectl -n projectcontour get pod -l app=envoy -o jsonpath='{.items[0].metadata.name}') 9001
http localhost:9001/help
```


```bash
kubectl -n projectcontour scale deployment/contour --replicas=0 && kubectl -n projectcontour scale deployment/contour --replicas=1
```
