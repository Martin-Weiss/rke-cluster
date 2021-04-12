#!/bin/bash
curl -L -o kubectl-cert-manager.tar.gz https://github.com/jetstack/cert-manager/releases/download/v1.3.0/kubectl-cert_manager-linux-amd64.tar.gz
tar xzf kubectl-cert-manager.tar.gz
echo "kubectl-cert-manager.tar.gz" > .gitignore
echo "kubectl-cert_manager" >>.gitignore
echo "LICENSES" >>.gitignore
