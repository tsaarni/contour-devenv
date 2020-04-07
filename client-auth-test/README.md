# Manual end-to-end test procedure for external client certificate validation with Contour and Envoy

These instructions are related to PR https://github.com/projectcontour/contour/pull/2410

## Setup

Create configuration file for kind cluster:

```bash
cat >kind-cluster-config.yaml <<EOF
kind: Cluster
apiVersion: kind.sigs.k8s.io/v1alpha3
kubeadmConfigPatches:
  - |
    apiVersion: kubeadm.k8s.io/v1beta2
    kind: ClusterConfiguration
    metadata:
      name: config
    apiServer:
      extraArgs:
        # change port range so that we can bind privileged ports with NodePort
        # this is needed so that we can use default http and https ports when connecting services
        # with clients such as httpie without having to override HTTP header
        # "Host: host1.external.com:31390" with "Host: host1.external.com"
        service-node-port-range: 80-32767
nodes:
- role: control-plane
- role: worker
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    listenAddress: "127.0.0.101"
  - containerPort: 443
    hostPort: 443
    listenAddress: "127.0.0.101"
EOF
```

Launch the cluster

```bash
kind create cluster --config kind-cluster-config.yaml --name contour
```

Compile and install `certyaml` tool for generating certificate hierarchies:


```bash
GO111MODULE=on go get github.com/tsaarni/certyaml@v0.1.0
```

[Certyaml](https://github.com/tsaarni/certyaml) is a small tool I hacked together quickly. Currently it is barely usable.

Create configuration file declaring required CAs and end-entity certificates for the test cases:


```bash
cat >certs.yaml <<EOF
subject: cn=client-root-ca-1
---
subject: cn=client-root-ca-2
---
subject: cn=ingress-root-ca
---
subject: cn=ingress
issuer: cn=ingress-root-ca
sans:
- DNS:not-protected.127-0-0-101.nip.io
- DNS:protected.127-0-0-101.nip.io
- DNS:protected-tcpproxy.127-0-0-101.nip.io
- DNS:protected-tcpproxy-passthrough.127-0-0-101.nip.io
- DNS:protected-permitinsecure.127-0-0-101.nip.io
---
subject: cn=trusted-client-1
issuer: cn=client-root-ca-1
key_usage:
- KeyEncipherment
- DigitalSignature
---
subject: cn=trusted-client-2
issuer: cn=client-root-ca-2
key_usage:
- KeyEncipherment
- DigitalSignature
---
subject: cn=untrusted-client
ca: false
key_usage:
- KeyEncipherment
- DigitalSignature
EOF
```

Generate certificates and keys:

```bash
mkdir -p certs
certyaml --destination certs certs.yaml
```

Upload the certificates and keys as secrets to the cluster:

```bash
kubectl create secret tls ingress --cert=certs/ingress.pem --key=certs/ingress-key.pem --dry-run -o yaml | kubectl apply -f -
cat certs/client-root-ca-1.pem certs/client-root-ca-2.pem | kubectl create secret generic client-root-ca --from-file=ca.crt=/dev/stdin --dry-run -o yaml | kubectl apply -f -
```

Build and deploy a version of Contour with the client certificate validation API enabled:

```bash
git clone https://github.com/projectcontour/contour.git
cd contour
git fetch origin pull/2410/head:client-cert-auth
git checkout client-cert-auth
make container
docker tag projectcontour/contour:[BUILD_VERSION] projectcontour/contour:latest
kind load docker-image projectcontour/contour:latest --name contour
sed 's!image: docker.io/projectcontour/contour.*!image: docker.io/projectcontour/contour:latest!' examples/render/contour.yaml | kubectl apply -f -

# wait until everything is Running
kubectl -n projectcontour get pods
```

Deploy two backend services used in the test case:

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin-protected
  labels:
    app: httpbin-protected
spec:
  selector:
    matchLabels:
      app: httpbin-protected
  template:
    metadata:
      labels:
        app: httpbin-protected
    spec:
      containers:
      - name: httpbin
        image: tsaarni/httpbin:latest
        ports:
          - containerPort: 80
        env:
          - name: X_SERVER_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
        command: ["/bin/sh"]
        args:
          - "-c"
          - "gunicorn -b 0.0.0.0:80 --access-logfile - httpbin:app -k gevent"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin-not-protected
  labels:
    app: httpbin-not-protected
spec:
  selector:
    matchLabels:
      app: httpbin-not-protected
  template:
    metadata:
      labels:
        app: httpbin-not-protected
    spec:
      containers:
      - name: httpbin
        image: tsaarni/httpbin:latest
        ports:
          - containerPort: 80
        env:
          - name: X_SERVER_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
        command: ["/bin/sh"]
        args:
          - "-c"
          - "gunicorn -b 0.0.0.0:80 --access-logfile - httpbin:app -k gevent"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin-passthrough
  labels:
    app: httpbin-passthrough
spec:
  selector:
    matchLabels:
      app: httpbin-passthrough
  template:
    metadata:
      labels:
        app: httpbin-passthrough
    spec:
      containers:
      - name: httpbin-passthrough
        image: tsaarni/httpbin:latest
        ports:
          - containerPort: 443
        env:
          - name: X_SERVER_NAME
            valueFrom:
              fieldRef:
                fieldPath: metadata.name
        volumeMounts:
        - mountPath: /run/secrets/certs/
          name: httpbin-cert
          readOnly: true
        - mountPath: /run/secrets/ca/
          name: client-ca-bundle
          readOnly: true
        command: ["/bin/sh"]
        # Configure Gunicorn HTTP server to terminate TLS
        #   - server certificate and key
        #   - require client certificate and validate against trusted CA cert
        #     --cert-reqs 0 == ssl.CERT_NONE
        #     --cert-reqs 1 == ssl.CERT_OPTIONAL
        #     --cert-reqs 2 == ssl.CERT_REQUIRED
        args:
          - "-c"
          - "gunicorn -b 0.0.0.0:443 --access-logfile - --cert-reqs 2 --certfile /run/secrets/certs/tls.crt --keyfile /run/secrets/certs/tls.key --ca-certs /run/secrets/ca/ca.crt httpbin:app -k gevent"
      volumes:
      - name: httpbin-cert
        secret:
          secretName: ingress
      - name: client-ca-bundle
        secret:
          secretName: client-root-ca
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin-protected
  labels:
    app: httpbin-protected
spec:
  ports:
  - name: http
    port: 80
  selector:
    app: httpbin-protected
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin-not-protected
  labels:
    app: httpbin-not-protected
spec:
  ports:
  - name: http
    port: 80
  selector:
    app: httpbin-not-protected
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin-passthrough
  labels:
    app: httpbin-passthrough
spec:
  ports:
  - name: https
    port: 443
  selector:
    app: httpbin-passthrough
EOF
```

The backend service is forked version of [httpbin](https://github.com/tsaarni/httpbin) with the addition of `X-Server-Name` response header that can be set in Deployment to reflect the Pod name.
This way we can be sure which backend service the response is originating from.


Define the `HTTPProxies` for the test cases:

```bash
kubectl apply -f - <<EOF
apiVersion: projectcontour.io/v1
kind: HTTPProxy
metadata:
  name: https-with-client-auth
spec:
  virtualhost:
    fqdn: protected.127-0-0-101.nip.io
    tls:
      secretName: ingress
      clientValidation:
        caSecret: client-root-ca
  routes:
    - services:
        - name: httpbin-protected
          port: 80
---
apiVersion: projectcontour.io/v1
kind: HTTPProxy
metadata:
  name: https-without-client-auth
spec:
  virtualhost:
    fqdn: not-protected.127-0-0-101.nip.io
    tls:
      secretName: ingress
  routes:
    - services:
        - name: httpbin-not-protected
          port: 80
---
apiVersion: projectcontour.io/v1
kind: HTTPProxy
metadata:
  name: no-tls
spec:
  virtualhost:
    fqdn: no-tls.127-0-0-101.nip.io
  routes:
    - services:
        - name: httpbin-not-protected
          port: 80
---
apiVersion: projectcontour.io/v1
kind: HTTPProxy
metadata:
  name: tcpproxy-tls-with-client-auth
spec:
  virtualhost:
    fqdn: protected-tcpproxy.127-0-0-101.nip.io
    tls:
      secretName: ingress
      clientValidation:
        caSecret: client-root-ca
  tcpproxy:
    services:
      - name: httpbin-protected
        port: 80
---
apiVersion: projectcontour.io/v1
kind: HTTPProxy
metadata:
  name: tcpproxy-passthrough-with-client-auth
spec:
  virtualhost:
    fqdn: protected-tcpproxy-passthrough.127-0-0-101.nip.io
    tls:
      passthrough: true
      clientValidation:
        caSecret: client-root-ca
  tcpproxy:
    services:
      - name: httpbin-passthrough
        port: 443
---
apiVersion: projectcontour.io/v1
kind: HTTPProxy
metadata:
  name: https-with-client-auth-permitinsecure
spec:
  virtualhost:
    fqdn: protected-permitinsecure.127-0-0-101.nip.io
    tls:
      secretName: ingress
      clientValidation:
        caSecret: client-root-ca
  routes:
    - services:
        - name: httpbin-protected
          port: 80
      permitInsecure: true
EOF

# check that status is valid
kubectl get httpproxies
```

## Test cases

Run the test cases:

```bash
# test case: successful authentication using two different client certificates from trusted CA bundle
#   - should respond with 200
#   - x-server-name header should reflect the pod name of httpbin-protected
curl -Ss -D - --cacert certs/ingress-root-ca.pem --cert certs/trusted-client-1.pem --key certs/trusted-client-1-key.pem https://protected.127-0-0-101.nip.io/get
curl -Ss -D - --cacert certs/ingress-root-ca.pem --cert certs/trusted-client-2.pem --key certs/trusted-client-2-key.pem https://protected.127-0-0-101.nip.io/get

# test case: unsuccessful authentication with client certificate from untrusted CA
#    - should give TLS error: alert unknown ca
curl -Ss -D - --cacert certs/ingress-root-ca.pem --cert certs/untrusted-client.pem --key certs/untrusted-client-key.pem https://protected.127-0-0-101.nip.io/get

# test case: successful unauthenticated request
#    - should respond with 200
#    - x-server-name header should reflect the pod name of httpbin-not-protected
curl -Ss -D - --cacert certs/ingress-root-ca.pem https://not-protected.127-0-0-101.nip.io/get

# test case: unsuccessful SNI bypass - request to protected vhost via unauthenticated vhost
#    - should repond with 404
curl -Ss -D - --cacert certs/ingress-root-ca.pem https://not-protected.127-0-0-101.nip.io/get -H Host:protected.127-0-0-101.nip.io -H Host:protected.127-0-0-101.nip.io

# test case: unsuccessful SNI bypass - request to unprotected vhost via authenticated vhost
#    - should respond with 404
curl -Ss -D - --cacert certs/ingress-root-ca.pem --cert certs/trusted-client-1.pem --key certs/trusted-client-1-key.pem https://protected.127-0-0-101.nip.io/get -H Host:not-protected.127-0-0-101.nip.io

# test case: unsuccessful authentication without SNI
#    - should return write:errno=0
openssl s_client -quiet -CAfile certs/ingress-root-ca.pem -cert certs/trusted-client-1.pem -key certs/trusted-client-1-key.pem -connect protected.127-0-0-101.nip.io:443 -noservername

# test case: successful authentication with tcpproxy in TLS termination mode
#    - should respond with 200
#    - server header should reflect that response comes from gunicorn instead of envoy
curl -Ss -D - --cacert certs/ingress-root-ca.pem --cert certs/trusted-client-1.pem --key certs/trusted-client-1-key.pem https://protected-tcpproxy.127-0-0-101.nip.io/get

# test case: unsuccessful authentication with tcpproxy in TLS termination mode
#   - should give TLS error: alert unknown ca
curl -Ss -D - --cacert certs/ingress-root-ca.pem --cert certs/untrusted-client.pem --key certs/untrusted-client-key.pem https://protected-tcpproxy.127-0-0-101.nip.io/get
```

## Teardown

Clean up by deleting the cluster

```bash
kind delete cluster --name contour
```
