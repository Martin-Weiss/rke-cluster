#!/bin/bash
RKE2_VERSIONS="v1.19.7+rke2r1 v1.20.4+rke2r1"
for RKE2_VERSION in $RKE2_VERSIONS; do
	mkdir -p $RKE2_VERSION
	wget -N "https://github.com/rancher/rke2/releases/download/$RKE2_VERSION/rke2.linux-amd64.tar.gz" -O $RKE2_VERSION/rke2.linux-amd64.tar.gz
done
wget -N "https://raw.githubusercontent.com/rancherlabs/support-tools/master/collection/rancher/v2.x/logs-collector/rancher2_logs_collector.sh"
chmod +x rancher2_logs_collector.sh
