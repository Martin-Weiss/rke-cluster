#!/bin/bash
VERSION=2.6.7
wget -N https://github.com/rancher/cli/releases/download/v$VERSION/rancher-linux-amd64-v$VERSION.tar.xz
tar xvf rancher-linux-amd64-v$VERSION.tar.xz
cp rancher-v$VERSION/rancher rancher
echo "rancher" > .gitignore
echo "rancher-linux-amd64-v$VERSION.tar.xz" >> .gitignore
echo "rancher-v$VERSION" >>.gitignore
