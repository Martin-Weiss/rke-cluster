#!/bin/bash
#VERSIONS="2.5.12 2.6.4 2.6.5 2.6.6 2.6.7 2.6.8 2.6.9 2.7.0"
#VERSIONS="2.7.0"
#VERSIONS="2.7.1"
#VERSIONS="2.7.2"
#VERSIONS="2.7.3"
#VERSIONS="2.7.4"
#VERSIONS="2.7.5"
#VERSIONS="2.7.6"
VERSIONS="2.7.9"
for VERSION in $VERSIONS; do
#	wget -N https://github.com/rancher/rancher/rancher-$VERSION.tgz -P charts -o rancher-v$VERSION.tgz
	if [ ! -f helm-cli/helm ]; then
	      echo "get helm client first to helm-cli/helm"
	      exit 1
        fi
	if [ ! -f charts/rancher-v$VERSION.tgz ] && [ ! -f charts/rancher-$VERSION.tgz ]; then
		# add helm chart repos
		helm-cli/helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update
		helm-cli/helm repo add rancher-latest https://releases.rancher.com/server-charts/latest --force-update
		helm-cli/helm repo add rancher-prime https://charts.rancher.com/server-charts/prime --force-update
		echo "downloading rancher-v$VERSION.tgz"
		#helm-cli/helm fetch rancher-stable/rancher --version $VERSION -d charts
		helm-cli/helm fetch rancher-prime/rancher --version $VERSION -d charts
		if [ ! $? == 0 ]; then
			echo "version $VERSION not in stable so fetching from latest"
			helm-cli/helm fetch rancher-latest/rancher --version $VERSION -d charts
		fi
		mv charts/rancher-$VERSION.tgz charts/rancher-v$VERSION.tgz
	else 
		echo "rancher-v$VERSION.tgz already exists"
	fi
done
