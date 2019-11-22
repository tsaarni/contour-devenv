#!/bin/bash -ex

export KUBECONFIG=/etc/kubernetes/admin.conf
cd /vagrant

# install tools
apt-get install -y httpie

curl -fsSL https://github.com/cloudflare/cfssl/releases/download/v1.4.1/cfssl_1.4.1_linux_amd64 -o /usr/local/bin/cfssl
curl -fsSL https://github.com/cloudflare/cfssl/releases/download/v1.4.1/cfssljson_1.4.1_linux_amd64  -o /usr/local/bin/cfssljson
chmod +x /usr/local/bin/cfssl*

cat <<EOF >>/etc/hosts
127.0.0.1 host1.external.com
127.0.0.1 host2.external.com
EOF
