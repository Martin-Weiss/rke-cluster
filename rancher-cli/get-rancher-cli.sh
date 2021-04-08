#!/bin/bash
wget -N https://github.com/rancher/cli/releases/download/v2.4.10/rancher-linux-amd64-v2.4.10.tar.xz
tar xvf rancher-linux-amd64-v2.4.10.tar.xz
cp rancher-v2.4.10/rancher rancher
echo "rancher" > .gitignore
echo "rancher-linux-amd64-v2.4.10.tar.xz" >> .gitignore
echo "rancher-v2.4.10" >>.gitignore
