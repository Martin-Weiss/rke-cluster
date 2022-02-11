#!/bin/bash
RKE2_VERSIONS="v1.19.7+rke2r1 v1.19.8+rke2r1 v1.19.9+rke2r1 v1.19.10+rke2r1 v1.19.11+rke2r1 v1.19.12+rke2r1 v1.19.13+rke2r1 v1.19.14+rke2r1 v1.19.16+rke2r1 v1.20.4+rke2r1 v1.20.5+rke2r1 v1.20.6+rke2r1 v1.20.7+rke2r1 v1.20.7+rke2r2 v1.20.8+rke2r1 v1.20.9+rke2r1 v1.20.10+rke2r1 v1.20.11+rke2r1 v1.20.11+rke2r2 v1.20.12+rke2r1 v1.20.13+rke2r1 v1.20.15+rke2r1 v1.21.2+rke2r1 v1.21.3+rke2r1 v1.21.4+rke2r3 v1.21.5+rke2r1 v1.21.6+rke2r1 v1.21.7+rke2r1 v1.21.7+rke2r2 v1.21.9+rke2r1"

for RKE2_VERSION in $RKE2_VERSIONS; do
	mkdir -p $RKE2_VERSION
	if [ ! -f "$RKE2_VERSION/rke2.linux-amd64.tar.gz" ]; then
		wget "https://github.com/rancher/rke2/releases/download/$RKE2_VERSION/rke2.linux-amd64.tar.gz" -O $RKE2_VERSION/rke2.linux-amd64.tar.gz
	fi
	echo "rke2.linux-amd64.tar.gz" > $RKE2_VERSION/.gitignore
        if [ ! -f "$RKE2_VERSION/kubectl" ] ; then
                K8S_VERSION=$(echo $RKE2_VERSION|cut -f1 -d "+")
                wget "https://storage.googleapis.com/kubernetes-release/release/$K8S_VERSION/bin/linux/amd64/kubectl" -O $RKE2_VERSION/kubectl
        fi
        echo "kubectl" >> $RKE2_VERSION/.gitignore
done

# Logcolector
wget -N "https://raw.githubusercontent.com/rancherlabs/support-tools/master/collection/rancher/v2.x/logs-collector/rancher2_logs_collector.sh"
chmod +x rancher2_logs_collector.sh

# 1.20.4 and 1.20.5 workaround for pulling images not working
# v1.20.15+rke2r1 v1.21.9+rke2r1 pulling images from portus not working
RKE2_VERSIONS="v1.20.4+rke2r1 v1.20.5+rke2r1 v1.20.15+rke2r1 v1.21.9+rke2r1"
for RKE2_VERSION in $RKE2_VERSIONS; do
	mkdir -p $RKE2_VERSION
	if [ ! -f "$RKE2_VERSION/rke2-images.linux-amd64.tar.zst" ]; then
		wget -N "https://github.com/rancher/rke2/releases/download/$RKE2_VERSION/rke2-images.linux-amd64.tar.zst" -O $RKE2_VERSION/rke2-images.linux-amd64.tar.zst
	fi
	echo "rke2.linux-amd64.tar.gz" > $RKE2_VERSION/.gitignore
        echo "rke2-images.linux-amd64.tar.zst" >> $RKE2_VERSION/.gitignore
        echo "rke2-images.linux-amd64.tar.gz" >> $RKE2_VERSION/.gitignore
	echo "kubectl" >> $RKE2_VERSION/.gitignore
done
