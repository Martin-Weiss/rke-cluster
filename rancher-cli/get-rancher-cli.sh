#!/bin/bash
VERSION=2.6.0
wget -N https://github.com/rancher/cli/releases/download/v$VERSION/rancher-linux-amd64-v$VERSION.tar.xz
tar xvf rancher-linux-amd64-v$VERSION.tar.xz
cp rancher-v2.$VERSION/rancher rancher
echo "rancher" > .gitignore
echo "rancher-linux-amd64-v$VERSION.tar.xz" >> .gitignore
echo "rancher-v$VERSION" >>.gitignore
