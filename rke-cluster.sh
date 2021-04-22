#!/bin/bash 
#
######################################################
# v0.1 25.03.2021 Martin Weiss - Martin.Weiss@suse.com
# v0.2 07.04.2021 Martin Weiss - Martin.Weiss@suse.com
#          	  - added server.txt and settings.txt
# v0.3 08.04.2021 Martin Weiss - Martin.Weiss@suse.com
#		  - added custom CA
# v0.4 15.04.2021 Martin Weiss - Martin.Weiss@suse.com
#		  - adjusted custom CA
#		  - adjusted charts and manifest 
#                   sources
#
# this script is used to create and upgrade rke2
# clusters
# have fun with it and feel free to provide feedback ;-)
#
######################################################
# ------------------------------
# Open ToDo
# ------------------------------
# 
# - manage kubeconfig with rights
# - allow $RKEUSER to manage cri / crictl
# - add a detection on secondary masters to wait until join is possible
#
######################################################

# ------------------------------
# Variables
# ------------------------------

SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"
SETTINGS=$SCRIPTPATH/settings.txt
source $SETTINGS

######################################################

# detect cluster and set version
function _DETECT_CLUSTER {
	DOMAIN="$(grep $(hostname) $SERVERTXT|cut -f2 -d ",")"
	RKE2_VERSION="$(grep $(hostname) $SERVERTXT|cut -f3 -d ",")"
        STAGE="$(grep $(hostname) $SERVERTXT|cut -f4 -d ",")"
        CLUSTER="$(grep $(hostname) $SERVERTXT|cut -f5 -d ",")"
        NODETYPE="$(grep $(hostname) $SERVERTXT|cut -f6 -d ",")"
	USERNAME="$(grep $(hostname) $SERVERTXT|cut -f7 -d ",")"
	PASSWORD="$(grep $(hostname) $SERVERTXT|cut -f8 -d ",")"
	CREDS="$(echo -n $USERNAME:$PASSWORD|base64)"
	echo CLUSTER is $CLUSTER
	echo NODETYPE is $NODETYPE
	echo STAGE is $STAGE
	echo RKE2_VERSION is $RKE2_VERSION
}

# end o variables

function _INSTALL_RKE2 {
	# hoping to replace this with an RPM for SLES 15 SP2, soon
	echo "Install RKE2 from Tarball"
	# this part should be part of the SUSE RPM for RKE2 once we have it
	sudo tar xzvf $RKECLUSTERDIR/$RKE2_VERSION/rke2.linux-amd64.tar.gz -C /usr/local 2>&1 >/dev/null;
	# for security based on rke2 docs
	# probably etcd user is only required on master?
	if [ $NODETYPE == "master1" ] || [ $NODETYPE == "master" ] ; then
		echo "creating etcd user on a master node"
		sudo useradd -r -c "etcd user" -s /sbin/nologin -M etcd 2>&1 >/dev/null
	else
		echo "not creating etcd user as we are not on a master node"
	fi
	sudo cp -f /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
	sudo systemctl restart systemd-sysctl 2>&1 >/dev/null
	# copy systemd unit files to etc due to "reboot not starting the service in case /usr/local is not part of the root filesystem"
	sudo cp /usr/local/lib/systemd/system/rke2-agent.service /etc/systemd/system/rke2-agent.service
	sudo cp /usr/local/lib/systemd/system/rke2-server.service /etc/systemd/system/rke2-server.service
	sudo systemctl daemon-reload;
	# ensure firewalld is stopped and disabled as this is not compatible with canal
	sudo systemctl disable --now firewalld;
	# install iptables because it is used in rke2-killall.sh
	# install nfs-client for nfs-client-provisioner and longhorn and open-iscsi for longhorn
	sudo zypper -n in iptables nfs-client open-iscsi
	# create target dir for configs of rke2
	sudo mkdir -p /etc/rancher/rke2
	# workaround in v1.19.7+rke2r1 for authentication for base images from on-premise registry with authentication
	# in case the registry does not have a SAN in the SSL certificate GODEBUG=x509ignoreCN=0 needs to be added to the environment
	# configure in /etc/default/rke2-server and /etc/default/rke2-agent or in /etc/sysconfig/rke2-server and /etc/sysconfig/rke2-agent
	sudo bash -c 'cat << EOF > /etc/default/rke2-server
HOME=/root
GODEBUG=x509ignoreCN=0
EOF'
	sudo bash -c 'cat << EOF > /etc/default/rke2-agent
HOME=/root
GODEBUG=x509ignoreCN=0
EOF'
}

function _PREPARE_RKE2_SERVER_CONFIG {
	echo "Create server config.yaml"
	# adjust CIRD to networks not used for services in the local infrastructure
	# needs also adjustment in kube-proxy and canal deployments!
	sudo bash -c 'cat << EOF > /etc/rancher/rke2/config.yaml
write-kubeconfig-mode: "0640"
server: https://%%CLUSTER%%.%%DOMAIN%%:9345
cluster-cidr: "%%CLUSTERCIDR%%"
service-cidr: "%%SERVICECIDR%%"
cluster-dns: "%%CLUSTERDNS%%"
cloud-provider-name: vsphere
cloud-provider-config: /etc/rancher/rke2/vsphere.conf
private-registry: /etc/rancher/rke2/registries.yaml
agent-token: %%CLUSTER%%-token-asfebwadg
token: %%CLUSTER%%-token-asfebwadg
system-default-registry: %%REGISTRY%%/%%STAGE%%/docker.io
profile: cis-1.5
tls-san:
  - "%%CLUSTER%%.%%DOMAIN%%"
node-label:
  - "cluster=%%CLUSTER%%"
EOF'
	if grep ",$CLUSTER," $SERVERTXT |grep ',worker,'; then
		echo "Add node-taint NoExecute on master because we have workers"
		sudo bash -c 'cat << EOF >> /etc/rancher/rke2/config.yaml
node-taint:
  - "CriticalAddonsOnly=true:NoExecute"
EOF'
	else
		echo "Do NOT add node-taint NoExecute on Rancher master because we do NOT have workers"
	fi
}

function _PREPARE_RKE2_AGENT_CONFIG {
	echo "Create agent config.yaml"
        sudo bash -c 'cat << EOF > /etc/rancher/rke2/config.yaml
cloud-provider-name: vsphere
cloud-provider-config: /etc/rancher/rke2/vsphere.conf
private-registry: /etc/rancher/rke2/registries.yaml
token: %%CLUSTER%%-token-asfebwadg
system-default-registry: %%REGISTRY%%/%%STAGE%%/docker.io
server: https://%%CLUSTER%%.%%DOMAIN%%:9345
profile: cis-1.5
node-label:
  - "cluster=%%CLUSTER%%"
EOF'
}

function _PREPARE_RKE2_CLOUD_CONFIG {
	if [ -f $RKECLUSTERDIR/vsphere.conf ]; then
		echo "Create vsphere.conf as it exists"
		sudo cp -a $RKECLUSTERDIR/vsphere.conf /etc/rancher/rke2/vsphere.conf
	else
		echo "no vsphere.conf so not creating it"
	fi
}

function _PREPARE_REGISTRIES_YAML {
	# required for registry mapping (missing namespace mapping feature compared to crio!!)
	# required for global registry authentication for the cluster
	echo "Prepare Registries YAML"
	sudo cp $RKECLUSTERDIR/registries.yaml /etc/rancher/rke2/
        sudo sed -i "s/%%STAGE%%/$STAGE/g" /etc/rancher/rke2/registries.yaml
        sudo sed -i "s/%%USERNAME%%/$USERNAME/g" /etc/rancher/rke2/registries.yaml
        sudo sed -i "s/%%PASSWORD%%/$PASSWORD/g" /etc/rancher/rke2/registries.yaml
        sudo sed -i "s/%%REGISTRY%%/$REGISTRY/g" /etc/rancher/rke2/registries.yaml
}

function _PREPARE_DOCKER_CREDENTIALS {
	# for v1.19.7+rke2r1 to pull the base images with authentication from on-premise registry
	echo "Prepare Docker Credentials"
	sudo mkdir -p /root/.docker
	sudo cp $RKECLUSTERDIR/config.json /root/.docker/config.json
        sudo sed -i "s/%%REGISTRY%%/$REGISTRY/g" /root/.docker/config.json
	sudo sed -i "s/%%CREDS%%/$CREDS/g" /root/.docker/config.json
}

function _ADMIN_PREPARE {
	echo "Prepare Admin Tools"
	# take helm3 from caasp 4.5 channels - needs to be replaced with helm3 delivery from "somewhere else"
	#  sudo zypper -n in helm3
	# use helm from binary
	sudo zypper -n rm helm3
	sudo bash -c "if [ -f $RKECLUSTERDIR/helm-cli/helm ]; then cp $RKECLUSTERDIR/helm-cli/helm /usr/local/bin; chmod +x /usr/local/bin/helm; fi"
	# profile settings for kubeconfig, crictl and binaries
	# also hope that this will be part of the RPM
	sudo bash -c 'cat << EOF > /etc/profile.local
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml
export PATH=\$PATH:/var/lib/rancher/rke2/bin
EOF'
	# bash completion
	# add bash compltion for kubectl and helm
	# should both also be part of the RPM
	# need to wait until binary is extracted from rke2 binary
	while [ ! -f /var/lib/rancher/rke2/bin/kubectl ]; do
		echo "waiting on /var/lib/rancher/rke2/bin/kubectl to be available"
		sleep 1
	done
	# adding cert-manager kubectl extension
	sudo bash -c "if [ -f $RKECLUSTERDIR/cert-manager-cli/kubectl-cert_manager ]; then cp $RKECLUSTERDIR/cert-manager-cli/kubectl-cert_manager /usr/local/bin; chmod +x /usr/local/bin/kubectl-cert_manager; fi"
	# bash completion for kubectl and helm
	sudo bash -c '/var/lib/rancher/rke2/bin/kubectl completion bash > /usr/share/bash-completion/completions/kubectl'
	# rme based helm
	#  sudo bash -c '/usr/bin/helm completion bash > /usr/share/bash-completion/completions/helm'
	# helm from binary
	sudo bash -c '/usr/local/bin/helm completion bash > /usr/share/bash-completion/completions/helm'
	# set rights for bash-completion
	sudo chmod 644 /usr/share/bash-completion/completions/kubectl
	sudo chmod 644 /usr/share/bash-completion/completions/helm
	# kube config
	# prepare kubeconfig for user root and $RKEUSER in case environment is not set
	# have to wait until kubeconfig is created by rke2-server service
	while [ ! -f /etc/rancher/rke2/rke2.yaml ]; do
		echo "waiting on /etc/rancher/rke2/rke2.yaml to be available"
		sleep 1
	done
	mkdir -p /home/$RKEUSER/.kube
	if [ ! -f /home/$RKEUSER/.kube/config ]; then
		ln -s /etc/rancher/rke2/rke2.yaml /home/$RKEUSER/.kube/config 2>&1 >/dev/null
	fi
	sudo chown $RKEUSER:users /home/$RKEUSER/.kube
	sudo mkdir -p /root/.kube
	sudo bash -c "if [ ! -f /root/.kube/config ]; then ln -s /etc/rancher/rke2/rke2.yaml /root/.kube/config 2>&1 >/dev/null; fi"
	# give $RKEUSER group access to kubeconfig
	sudo chgrp $RKEGROUP /etc/rancher/rke2/rke2.yaml
	# export already during initial deployment as profile.local is not executed in current session
	export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
	export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml
	export PATH=$PATH:/var/lib/rancher/rke2/bin
}

function _AGENT_PREPARE {
	echo "Prepare Agent Tools"
	# prepare profile settings for admin tools
	# this should also be part of the RPM
	sudo bash -c 'cat << EOF > /etc/profile.local
export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml
export PATH=\$PATH:/var/lib/rancher/rke2/bin
EOF'
        # export already during initial deployment as profile.local is not executed in current session
        export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml
        export PATH=$PATH:/var/lib/rancher/rke2/bin
}

function _CONFIGURE_CUSTOM_CA {
        # server-ca.crt and key need to be copied only if not exist in target and if exist in source
        # only required on first master as others get it via registration against 9345
        # added first experiment for rancher and cert-manager using custom CA
        if [ -f $CA_CRT ] && [ -f $CA_KEY ] && [ "$FIRSTMASTER" == "1" ]; then
	        sudo mkdir -p /var/lib/rancher/rke2/server/tls
                echo 'custom CA exists and target CA does not exist - so copy custom one'
                sudo cp -a $CA_CRT /var/lib/rancher/rke2/server/tls/server-ca.crt
                sudo cp -a $CA_KEY /var/lib/rancher/rke2/server/tls/server-ca.key
                sudo chmod 644 /var/lib/rancher/rke2/server/tls/server-ca.crt
                sudo chmod 600 /var/lib/rancher/rke2/server/tls/server-ca.key
	fi
        if [ -f $CA_CRT ] && [ -f $CA_KEY ] ; then
                echo 'base 64 encoding and cluster-issuer preparation'
                TLS_CRT_B64=$(sudo cat $CA_CRT|base64 -w0)
                TLS_KEY_B64=$(sudo cat $CA_KEY|base64 -w0)
                if [ -f $RKECLUSTERDIR/manifests/cluster-issuer.yaml.private-ca ]; then
                        sudo sed -i "s/%%CLUSTER%%/$CLUSTER/g" $RKECLUSTERDIR/manifests/cluster-issuer.yaml.private-ca
                        sudo sed -i "s/%%TLS_CRT%%/$TLS_CRT_B64/g" $RKECLUSTERDIR/manifests/cluster-issuer.yaml.private-ca
                        sudo sed -i "s/%%TLS_KEY%%/$TLS_KEY_B64/g" $RKECLUSTERDIR/manifests/cluster-issuer.yaml.private-ca
                        sudo mv $RKECLUSTERDIR/manifests/cluster-issuer.yaml.private-ca $RKECLUSTERDIR/manifests/cluster-issuer.yaml
                fi
                if [ -f  $RKECLUSTERDIR/manifests/rancher.yaml.private-ca ]; then
                        sudo sed -i "s/%%TLS_CRT%%/$TLS_CRT_B64/g" $RKECLUSTERDIR/manifests/rancher.yaml.private-ca
                        sudo mv $RKECLUSTERDIR/manifests/rancher.yaml.private-ca $RKECLUSTERDIR/manifests/rancher.yaml
                fi
        else
                echo 'no custom CA exists or target CA already there - do not copy CA'
                if [ -f $RKECLUSTERDIR/manifests/cluster-issuer.yaml.self-signed-ca ]; then
                        sudo mv  $RKECLUSTERDIR/manifests/cluster-issuer.yaml.self-signed-ca  $RKECLUSTERDIR/manifests/cluster-issuer.yaml
                fi
                if [ -f $RKECLUSTERDIR/manifests/rancher.yaml.self-signed-ca  ]; then
                        sudo mv $RKECLUSTERDIR/manifests/rancher.yaml.self-signed-ca $RKECLUSTERDIR/manifests/rancher.yaml
                fi
        fi
}

function _FIX_1_20_DEPLOYMENT {
        # have to adopt 1.20.4 / 1.20.5 workaround before starting the cluster
        if [ "$RKE2_VERSION" == "v1.20.4+rke2r1" ] || [ "$RKE2_VERSION" == "v1.20.5+rke2r1" ]; then
	        # change in system-default-registry does not allow namespace anymore
        	sudo sed -i "s/^system-default-registry:.*/system-default-registry: $REGISTRY/g" /etc/rancher/rke2/config.yaml
	        # due to missing namespacee support for initial images have to use tarball
	        sudo mkdir -p /var/lib/rancher/rke2/agent/images
 	        sudo cp -a $RKECLUSTERDIR/$RKE2_VERSION/rke2-images.linux-amd64.tar.zst /var/lib/rancher/rke2/agent/images
	        if grep airgap-extra-registry /etc/rancher/rke2/config.yaml || [ $WORKER == "0" ]; then
	                echo "airgap-extra-registry already set or we are on a master"
	        else
	                echo "adding airgap-extra-registry as workaround for not setting proper image tags on workers"
                	sudo bash -c "echo airgap-extra-registry: $REGISTRY >> /etc/rancher/rke2/config.yaml"
        	fi
        fi
}

function _FIX_1_20_6 {
        # this version should have working registry rewrite
        # removing system-default-registry!
        if [ "$RKE2_VERSION" == "v1.20.6+rke2r1" ] ; then
        	sudo sed -i "/^system-default-registry:.*/d" /etc/rancher/rke2/config.yaml
	        # todo: remove rancher system-default registry when on rancher cluster, too!
        fi
}

function _CILIUM_NOT_CANAL {
	if echo $RKE2_VERSION |grep "v1.20.6" && [ -f $RKECLUSTERDIR/manifests/rke2-cilium.yaml ]; then
		echo "Cilium Yaml exists and cluster version is 1.20.6"
		sudo sed -i "/^disable: rke2-canal/d" /etc/rancher/rke2/config.yaml
		sudo bash -c 'echo "disable: rke2-canal" >>/etc/rancher/rke2/config.yaml'
		sudo rm $RKECLUSTERDIR/manifests/rke2-canal*.yaml /var/lib/rancher/rke2/server/manifests/rke2-canal*.yaml
	else
		echo "Cilium Yaml does not exist or cluster version is not v1.20.6"
		sudo rm $RKECLUSTERDIR/manifests/rke2-cilium*.yaml*
	fi
}

function _COPY_MANIFESTS_AND_CHARTS {
		echo "Copy default manifests and charts to master"
		# all masters need all static charts as we can not download them from helm repo that has self-signed certificate
		# all masters should have the same
		# also delete stuff that is not required anymore
		# during upgrades we might deliver "other" charts - depending on dependencies and upgrade procedures
		# create target directories
		sudo mkdir -p /var/lib/rancher/rke2/server/manifests
		sudo mkdir -p /var/lib/rancher/rke2/server/static/charts
		# copy static charts
		sudo rsync -a --delete $RKECLUSTERDIR/charts/* /var/lib/rancher/rke2/server/static/charts
		# delete old yaml files during changes & upgrades
		sudo rm $RKECLUSTERDIR/manifests/*.yaml*
		# copy all manifest templates
		sudo cp -a $RKECLUSTERDIR/manifests/all/*.yaml* $RKECLUSTERDIR/manifests/
		# copy rancher deployment or downstream deployments
		if [ $CLUSTER == $RANCHERCLUSTER ]; then
			echo "cluster is $RANCHERCLUSTER"
			sudo cp -a $RKECLUSTERDIR/manifests/$RANCHERCLUSTER/*.yaml* $RKECLUSTERDIR/manifests/
			sudo cp -a $RKECLUSTERDIR/manifests/$CLUSTER/* $RKECLUSTERDIR/manifests/
		else
			echo "cluster is downstream cluster"
			sudo cp -a $RKECLUSTERDIR/manifests/downstream/*.yaml* $RKECLUSTERDIR/manifests/
			sudo cp -a $RKECLUSTERDIR/manifests/$CLUSTER/*.yaml* $RKECLUSTERDIR/manifests/
		fi
		# replace canal with cilium in case cilium yaml exists
		_CILIUM_NOT_CANAL
	        sudo sed -i "s/%%STAGE%%/$STAGE/g" $RKECLUSTERDIR/manifests/*.yaml*
        	sudo sed -i "s/%%DOMAIN%%/$DOMAIN/g" $RKECLUSTERDIR/manifests/*.yaml*
	        sudo sed -i "s/%%CLUSTER%%/$CLUSTER/g" $RKECLUSTERDIR/manifests/*.yaml*
	        sudo sed -i "s/%%REGISTRY%%/$REGISTRY/g" $RKECLUSTERDIR/manifests/*.yaml*
        	sudo sed -i "s#%%CLUSTERCIDR%%#$CLUSTERCIDR#g" $RKECLUSTERDIR/manifests/*.yaml*
        	sudo sed -i "s#%%SERVICECIDR%%#$SERVICECIDR#g" $RKECLUSTERDIR/manifests/*.yaml*
        	sudo sed -i "s/%%CLUSTERDNS%%/$CLUSTERDNS/g" $RKECLUSTERDIR/manifests/*.yaml*
		# cluster specific yaml files
		for FILE in $(sudo ls $RKECLUSTERDIR/manifests/*.$CLUSTER); do sudo mv $FILE $(echo $FILE|sed "s/\.$CLUSTER//g"); done
		# in case we have a custom CA
		_CONFIGURE_CUSTOM_CA
                # helm image changes after 1.19.7
                if [ ! "$RKE2_VERSION" == "v1.19.7+rke2r1" ] ; then
			sudo sed -i 's/klipper-helm:v0.4.3/klipper-helm:v0.4.3-build20210225/g' $RKECLUSTERDIR/manifests/*.yaml*
		fi
		# just to the first master for the moment as the recognition on "identical" is not based on file content / md5sum or similar
		if [ "$FIRSTMASTER" == "1" ]; then
			echo "copy manifests only on first master until we have better solution to apply only once"
			# try to ensure all files have the same timestamp to apply only once
			sudo touch -d "2021-04-16 11:53" $RKECLUSTERDIR/manifests/*.yaml
			sudo cp -a $RKECLUSTERDIR/manifests/*.yaml /var/lib/rancher/rke2/server/manifests
		fi
}

function _ADJUST_CLUSTER_IDENTITY {
		# replace placeholders in config.yaml template
                sudo sed -i "s/%%CLUSTER%%/$CLUSTER/g" /etc/rancher/rke2/config.yaml
                sudo sed -i "s/%%DOMAIN%%/$DOMAIN/g" /etc/rancher/rke2/config.yaml
                sudo sed -i "s/%%REGISTRY%%/$REGISTRY/g" /etc/rancher/rke2/config.yaml
        	sudo sed -i "s/%%STAGE%%/$STAGE/g" /etc/rancher/rke2/config.yaml
        	sudo sed -i "s#%%CLUSTERCIDR%%#$CLUSTERCIDR#g" /etc/rancher/rke2/config.yaml
        	sudo sed -i "s#%%SERVICECIDR%%#$SERVICECIDR#g" /etc/rancher/rke2/config.yaml
        	sudo sed -i "s/%%CLUSTERDNS%%/$CLUSTERDNS/g" /etc/rancher/rke2/config.yaml
		if [ -f /etc/rancher/rke2/vsphere.conf ]; then 
			echo "adjust vsphere.conf as it exists"
	                sudo sed -i "s/%%CLUSTER%%/$CLUSTER/g" /etc/rancher/rke2/vsphere.conf
		else
			echo "no vsphere.conf so removing cloud config from config.yaml"
			sudo sed -i '/cloud-provider-name: vsphere/d' /etc/rancher/rke2/config.yaml
			sudo sed -i '/cloud-provider-config: \/etc\/rancher\/rke2\/vsphere.conf/d' /etc/rancher/rke2/config.yaml
		fi
}

function _JOIN_CLUSTER {
        if [ $NODETYPE == "master1" ] ; then
                echo "We are on the first master"
		FIRSTMASTER=1
		MASTER=1
		WORKER=0
                _PREPARE_RKE2_SERVER_CONFIG
                _PREPARE_RKE2_CLOUD_CONFIG
		_COPY_MANIFESTS_AND_CHARTS
		_ADJUST_CLUSTER_IDENTITY
                _FIX_1_20_DEPLOYMENT
                _FIX_1_20_6
                sudo sed -i "/^server/d" /etc/rancher/rke2/config.yaml
                sudo systemctl enable rke2-server.service 2>&1 >/dev/null;
                sudo systemctl restart rke2-server.service 2>&1 >/dev/null;
                _ADMIN_PREPARE
		echo "Verify with:  sudo journalctl -u rke2-server -f"
	elif [ $NODETYPE == "master" ] ; then
                echo "We are on a secondary master"
		FIRSTMASTER=0
		MASTER=1
		WORKER=0
                _PREPARE_RKE2_SERVER_CONFIG
                _PREPARE_RKE2_CLOUD_CONFIG
		_COPY_MANIFESTS_AND_CHARTS
		_ADJUST_CLUSTER_IDENTITY
                _FIX_1_20_DEPLOYMENT
                _FIX_1_20_6
                sudo systemctl enable rke2-server.service 2>&1 >/dev/null;
                sudo systemctl restart rke2-server.service 2>&1 >/dev/null;
                _ADMIN_PREPARE
		echo "Verify with:  sudo journalctl -u rke2-server -f"
        elif [ $NODETYPE == "worker" ] ; then
                echo "We are on a worker"
		FIRSTMASTER=0
		MASTER=0
		WORKER=1
                _PREPARE_RKE2_AGENT_CONFIG
                _PREPARE_RKE2_CLOUD_CONFIG
		_ADJUST_CLUSTER_IDENTITY
                _FIX_1_20_DEPLOYMENT
                _FIX_1_20_6
                sudo systemctl enable rke2-agent.service 2>&1 >/dev/null;
                sudo systemctl restart rke2-agent.service 2>&1 >/dev/null;
		_AGENT_PREPARE
		echo "Verify with:  sudo journalctl -u rke2-agent -f"
	fi
}

function _MAIN {
	_DETECT_CLUSTER
	_INSTALL_RKE2
	_PREPARE_REGISTRIES_YAML 
	_PREPARE_DOCKER_CREDENTIALS 
	_JOIN_CLUSTER
	echo "Done"
}

_MAIN
