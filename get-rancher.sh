#!/bin/bash
VERSIONS="2.5.5 2.5.7 2.5.8 2.5.9"
helm-cli/helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update
for VERSION in $VERSIONS; do
#	wget -N https://github.com/rancher/rancher/rancher-$VERSION.tgz -P charts -o rancher-v$VERSION.tgz
	if [ ! -f helm-cli/helm ]; then
	      echo "get helm client first to helm-cli/helm"
	      exit 1
        fi
	if [ ! -f charts/rancher-v$VERSION.tgz ] && [ ! -f charts/rancher-$VERSION.tgz ]; then
		echo "downloading rancher-v$VERSION.tgz"
		helm-cli/helm fetch rancher-stable/rancher --version $VERSION -d charts
		mv charts/rancher-$VERSION.tgz charts/rancher-v$VERSION.tgz
	else 
		echo "rancher-v$VERSION.tgz already exists"
	fi
done
