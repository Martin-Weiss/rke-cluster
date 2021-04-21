#!/bin/bash
RKE2_VERSIONS="v1.19.7+rke2r1 v1.19.8+rke2r1 v1.19.9+rke2r1 v1.20.4+rke2r1 v1.20.5+rke2r1 v1.20.5-alpha1+rke2r2 v1.20.6-rc2+rke2r1"
for RKE2_VERSION in $RKE2_VERSIONS; do
	mkdir -p $RKE2_VERSION
	if [ ! -f "$RKE2_VERSION/rke2.linux-amd64.tar.gz" ]; then
		wget "https://github.com/rancher/rke2/releases/download/$RKE2_VERSION/rke2.linux-amd64.tar.gz" -O $RKE2_VERSION/rke2.linux-amd64.tar.gz
	fi
	echo "rke2.linux-amd64.tar.gz" > $RKE2_VERSION/.gitignore
done

# Logcolector
wget -N "https://raw.githubusercontent.com/rancherlabs/support-tools/master/collection/rancher/v2.x/logs-collector/rancher2_logs_collector.sh"
chmod +x rancher2_logs_collector.sh

# 1.20.4 and 1.20.5 workaround
RKE2_VERSIONS="v1.20.4+rke2r1 v1.20.5+rke2r1"
for RKE2_VERSION in $RKE2_VERSIONS; do
	mkdir -p $RKE2_VERSION
	if [ ! -f "$RKE2_VERSION/rke2-images.linux-amd64.tar.zst" ]; then
		wget -N "https://github.com/rancher/rke2/releases/download/$RKE2_VERSION/rke2-images.linux-amd64.tar.zst" -O $RKE2_VERSION/rke2-images.linux-amd64.tar.zst
	fi
	echo "rke2.linux-amd64.tar.gz" > $RKE2_VERSION/.gitignore
        echo "rke2-images.linux-amd64.tar.zst" >> $RKE2_VERSION/.gitignore
        echo "rke2-images.linux-amd64.tar.gz" >> $RKE2_VERSION/.gitignore
done
