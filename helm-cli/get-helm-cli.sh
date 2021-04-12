#!/bin/bash
curl -L -o helm-linux-amd64.tar.gz https://get.helm.sh/helm-v3.5.3-linux-amd64.tar.gz
tar xzf helm-linux-amd64.tar.gz
mv linux-amd64/helm .
rm -rf linux-amd64
echo "helm-linux-amd64.tar.gz" > .gitignore
echo "helm" >>.gitignore
