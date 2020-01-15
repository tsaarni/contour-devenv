# Development environment for Contour and Envoy

This project contains my personal notes and environment for developing and testing [Contour](https://projectcontour.io/) and [Envoy](https://www.envoyproxy.io/)


## Dependencies

[Kind](https://github.com/kubernetes-sigs/kind) is used to run Kubernetes cluster locally.

`httpbin` container is used as a backend service.  There is a fork of `httpbin` [here](https://github.com/tsaarni/httpbin/) with some additional features:

* server-side event streaming for testing long connections
* response header `X-Server-Name` for tracking responses to individual backends

This version of `httpbin` is also available at dockerhub: `tsaarni/httpbin:latest`

Generation of certificates and keys uses [certyaml](https://github.com/tsaarni/certyaml) which issues certificates according to a specification in YAML manifest file.  To install `certyaml`run

    go get -u github.com/tsaarni/certyaml


## Developing

See following documents

* Developing [CONTOUR.txt](CONTOUR.txt)
* Develping [ENVOY.txt](ENVOY.txt)
