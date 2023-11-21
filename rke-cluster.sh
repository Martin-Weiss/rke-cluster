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
# v0.5 14.05.2021 Martin Weiss - Martin.Weiss@suse.com
#		  - added support for ubuntu
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
        USERNAME2="$(grep $(hostname) $SERVERTXT|cut -f9 -d ",")"
        PASSWORD2="$(grep $(hostname) $SERVERTXT|cut -f10 -d ",")"
        S3_ACCESSTOKEN="$(grep $(hostname) $SERVERTXT|cut -f11 -d ",")"
        S3_SECRET="$(grep $(hostname) $SERVERTXT|cut -f12 -d ",")"
        S3_BUCKET="$CLUSTER-etcd-backup"
	CREDS="$(echo -n $USERNAME:$PASSWORD|base64 -w0)"
        CREDS2="$(echo -n $USERNAME2:$PASSWORD2|base64 -w0)"
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
		sudo useradd -r -c "etcd user" -s /sbin/nologin -M etcd >/dev/null 2>&1
		sudo groupadd etcd >/dev/null 2>&1
		sudo usermod -g etcd etcd >/dev/null 2>&1
		sudo chown -R etcd:etcd /var/lib/rancher/rke2/server/db/etcd
	else
		echo "not creating etcd user as we are not on a master node"
	fi
	sudo cp -f /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
	# in case we use cilium as CNI the restart of this service will cause network to stop working - see https://github.com/rancher/rke2/issues/2021
	# so try to workaround with sysctl --system instead
	#sudo systemctl restart systemd-sysctl 2>&1 >/dev/null
	# also this seems to "kill" cilium so changing to "only apply rke2-cis-sysctl.conf"
	#sudo /sbin/sysctl --system 2>&1 >/dev/null
	sudo /sbin/sysctl -p /usr/local/share/rke2/rke2-cis-sysctl.conf
	# copy systemd unit files to etc due to "reboot not starting the service in case /usr/local is not part of the root filesystem"
	sudo cp /usr/local/lib/systemd/system/rke2-agent.service /etc/systemd/system/rke2-agent.service
	sudo cp /usr/local/lib/systemd/system/rke2-server.service /etc/systemd/system/rke2-server.service
	sudo systemctl daemon-reload;
	# ensure firewalld is stopped and disabled as this is not compatible with canal
	sudo systemctl disable --now firewalld;
	# install iptables because it is used in rke2-killall.sh
        # storage-class requirements
        # install nfs-client for nfs-client-provisioner and longhorn and open-iscsi for longhorn and ceph-common for ceph
	if [ -f /usr/bin/zypper ]; then
	        sudo zypper -n in iptables nfs-client open-iscsi ceph-common
	fi
	if [ -f /usr/bin/apt-get ]; then
	        sudo apt-get install iptables nfs-client open-iscsi ceph-common -y
	fi

	# start and enable iscsid (required for longhorn) - realized this problem in RKE2 1.21.2+Longhorn 1.1.2+SLES15SP3
	sudo systemctl enable --now iscsid

        # some deployments deliver PSP with apparmor support (i.e. cert-manager) - so installing it
	if [ -f /usr/bin/zypper ]; then
        	sudo zypper -n in -t pattern apparmor
	fi
	if [ -f /usr/bin/apt-get ]; then
        	sudo apt-get install apparmor -y
	fi
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
profile: cis-1.6
tls-san:
  - "%%CLUSTER%%.%%DOMAIN%%"
node-label:
  - "cluster=%%CLUSTER%%"
etcd-snapshot-schedule-cron: "7 */12 * * *"
etcd-snapshot-retention: 14
etcd-s3: true
etcd-s3-endpoint: %%S3_ENDPOINT%%
etcd-s3-endpoint-ca: /etc/ssl/ca-bundle.pem
etcd-s3-access-key: %%S3_ACCESSTOKEN%%
etcd-s3-secret-key: %%S3_SECRET%%
etcd-s3-bucket: %%S3_BUCKET%%
etcd-s3-region: %%S3_REGION%%
etcd-s3-folder: etcd-snapshots
etcd-s3-timeout: 300s
kubelet-arg: 
  - "config=/etc/rancher/rke2/kubelet-config.yaml"
EOF'
        sudo bash -c 'cat << EOF > /etc/rancher/rke2/kubelet-config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
imageGCHighThresholdPercent: 80
imageGCLowThresholdPercent: 60
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

function _PREPARE_RKE2_PSA_SERVER_CONFIG {
	# only required on server / master not on agent/worker
	# on rke2 1.24 we start enabling PSA and set it to restricted per default
	# some namespaces are ignored based on rke2-pss.yaml - example taken from https://docs.rke2.io/security/pod_security_standardsl
	if echo $RKE2_VERSION |grep "v1.24" ; then
	# add the admission control config file
	# be carefule in case kube-apiserver-arg: is in the config.yaml, already (i.e. due ti ACE)
	sudo bash -c 'cat << EOF >> /etc/rancher/rke2/config.yaml
kube-apiserver-arg:
  - "--admission-control-config-file=/etc/rancher/rke2/rke2-pss.yaml"
EOF'
	# copy default rke2-pss.yaml to target
	sudo cp -a $RKECLUSTERDIR/rke2-pss.yaml /etc/rancher/rke2/rke2-pss.yaml
	fi
	# different in 1.25/1.26/1.27
	if echo $RKE2_VERSION |grep "v1.25" || echo $RKE2_VERSION |grep "v1.26" || echo $RKE2_VERSION |grep "v1.27" ; then
		# change CIS profile to 1.23
		sudo sed -i 's/profile:.*/profile: cis-1.23/g' /etc/rancher/rke2/config.yaml
		# remove admission-control-config-file as RKE2 handles this automatically, now
		sudo sed -i '/admission-control-config-file/d' /etc/rancher/rke2/config.yaml
		# change api to v1 in /etc/rancher/rke2/rke2-pss.yaml if exists (1.24 needs v1beta1 and 1.25 and newer needs v1"
		sudo sed -i 's#pod-security.admission.config.k8s.io/v1beta1#pod-security.admission.config.k8s.io/v1#g' /etc/rancher/rke2/rke2-pss.yaml
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
profile: cis-1.6
node-label:
  - "cluster=%%CLUSTER%%"
  - "role=storage-node"
kubelet-arg: 
  - "config=/etc/rancher/rke2/kubelet-config.yaml"
EOF'
          sudo bash -c 'cat << EOF > /etc/rancher/rke2/kubelet-config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
imageGCHighThresholdPercent: 80
imageGCLowThresholdPercent: 60
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
	sudo sed -i "s/%%USERNAME2%%/$USERNAME2/g" /etc/rancher/rke2/registries.yaml
        sudo sed -i "s/%%PASSWORD2%%/$PASSWORD2/g" /etc/rancher/rke2/registries.yaml
        sudo sed -i "s/%%REGISTRY2%%/$REGISTRY2/g" /etc/rancher/rke2/registries.yaml
        sudo sed -i "s/%%VIRTUAL_REGISTRY%%/$VIRTUAL_REGISTRY/g" /etc/rancher/rke2/registries.yaml
        sudo sed -i "s#%%SINGLENAMESPACE%%#$SINGLENAMESPACE#g" /etc/rancher/rke2/registries.yaml
}

function _PREPARE_DOCKER_CREDENTIALS {
	# for v1.19.7+rke2r1 to pull the base images with authentication from on-premise registry
	echo "Prepare Docker Credentials"
	sudo mkdir -p /root/.docker
	sudo cp $RKECLUSTERDIR/config.json /root/.docker/config.json
        sudo sed -i "s/%%REGISTRY%%/$REGISTRY/g" /root/.docker/config.json
	sudo sed -i "s/%%CREDS%%/$CREDS/g" /root/.docker/config.json
	sudo sed -i "s/%%REGISTRY2%%/$REGISTRY2/g" /root/.docker/config.json
        sudo sed -i "s/%%CREDS2%%/$CREDS2/g" /root/.docker/config.json
}

function _ADMIN_PREPARE {
	echo "Prepare Admin Tools"
	# take helm3 from caasp 4.5 channels - needs to be replaced with helm3 delivery from "somewhere else"
	#  sudo zypper -n in helm3
	# use helm from binary
	if [ -f /usr/bin/zypper ]; then
		sudo zypper -n rm helm3
	fi
	sudo bash -c "if [ -f $RKECLUSTERDIR/helm-cli/helm ]; then cp $RKECLUSTERDIR/helm-cli/helm /usr/local/bin; chmod +x /usr/local/bin/helm; fi"
	# profile settings for kubeconfig, crictl and binaries
	# also hope that this will be part of the RPM
	# for suse this was working
	# sudo bash -c 'cat << EOF > /etc/profile.local
	# for ubuntu adjusted to rancher.sh (need to test if this also works on suse)
	sudo bash -c 'cat << EOF > /etc/profile.d/rancher.sh
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
	# does not work with RKE2 v1.19.*
        if [ -f $CA_CRT ] && [ -f $CA_KEY ] && [ "$FIRSTMASTER" == "1" ] && ! echo $RKE2_VERSION |grep "v1.19." ; then
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

function _FIX_1_19_DEPLOYMENT {
	if  echo $RKE2_VERSION |grep "v1.19." ; then
		# etcd timeout does not exist in 1.19.*
		sudo sed -i "/^etcd-s3-timeout:.*/d" /etc/rancher/rke2/config.yaml
		# cis 1.6 does not exist in 1.19.*
		sudo sed -i "s/^profile: cis-1.6/profile: cis-1.5/g" /etc/rancher/rke2/config.yaml
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
        if [ "$RKE2_VERSION" == "v1.20.6+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.20.7+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.20.7+rke2r2" ] ||\
	   [ "$RKE2_VERSION" == "v1.20.7+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.20.8+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.20.9+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.20.10+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.20.11+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.20.11+rke2r2" ] ||\
	   [ "$RKE2_VERSION" == "v1.20.12+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.20.13+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.20.15+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.21.2+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.21.3+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.21.4+rke2r3" ] ||\
	   [ "$RKE2_VERSION" == "v1.21.5+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.21.6+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.21.7+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.21.7+rke2r2" ] ||\
	   [ "$RKE2_VERSION" == "v1.21.9+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.21.10+rke2r2" ] ||\
	   [ "$RKE2_VERSION" == "v1.21.14+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.22.8+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.22.9+rke2r2" ] ||\
	   [ "$RKE2_VERSION" == "v1.22.12+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.23.9+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.24.3+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.22.13+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.23.10+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.24.4+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.24.10+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.25.6+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.26.1+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.24.17+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.25.15+rke2r2" ] ||\
	   [ "$RKE2_VERSION" == "v1.26.10+rke2r2" ] ||\
	   [ "$RKE2_VERSION" == "v1.27.17+rke2r2" ] ||\
	   [ "$RKE2_VERSION" == "v1.28.3+rke2r2" ] ||\
	   [ "$RKE2_VERSION" == "v1.21.11+rke2r1" ] ; then
                # remove system-default registry
                sudo sed -i "/^system-default-registry:.*/d" /etc/rancher/rke2/config.yaml
                sudo sed -i "s/systemDefaultRegistry:.*/systemDefaultRegistry: \"\"/g" $RKECLUSTERDIR/manifests/*.yaml
                # remove job image as with rewrite this comes from the registry
                sudo sed -i "/jobImage:/d" $RKECLUSTERDIR/manifests/*.yaml
                # remove registry and stage because this is now on the registries.yaml rewrite
                sudo sed -i "s#$REGISTRY/$STAGE/##g" $RKECLUSTERDIR/manifests/*.yaml
                # remove image paths - not working because some helm charts do not have the defaults
                #sudo sed -i "/$REGISTRY/d" $RKECLUSTERDIR/manifests/*.yaml
                #sudo sed -i "/image:/d" $RKECLUSTERDIR/manifests/*.yaml
                #sudo sed -i "/repository:/d" $RKECLUSTERDIR/manifests/*.yaml
                # remove images from rancher manifests
                sudo sed -i "/busyboxImage:/d" $RKECLUSTERDIR/manifests/*.yaml
                sudo sed -i "/rancherImage:/d" $RKECLUSTERDIR/manifests/*.yaml
                sudo rm /var/lib/rancher/rke2/agent/images/rke2-images.linux-amd64.tar.zst
        fi
}

function _FIX_1_20_7 {
	# workaround only needed on agents
        if [ "$RKE2_VERSION" == "v1.20.7+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.20.7+rke2r2" ] ||\
	   [ "$RKE2_VERSION" == "v1.20.8+rke2r1" ] ||\
	   [ "$RKE2_VERSION" == "v1.21.2+rke2r1" ] ; then
                echo "adding etcd user also on agents due to https://github.com/rancher/rke2/issues/1063"
                sudo useradd -r -c "etcd user" -s /sbin/nologin -M etcd 2>&1 >/dev/null
        fi
}

function _FIX_1_20_11 {
        if echo $RKE2_VERSION |grep "v1.20.11" ||\
	   echo $RKE2_VERSION |grep "v1.20.12" ||\
	   echo $RKE2_VERSION |grep "v1.20.13" ||\
	   echo $RKE2_VERSION |grep "v1.20.15" ||\
	   echo $RKE2_VERSION |grep "v1.21.7" ||\
	   echo $RKE2_VERSION |grep "v1.21.9" ||\
	   echo $RKE2_VERSION |grep "v1.21.10" ||\
	   echo $RKE2_VERSION |grep "v1.21.14" ||\
	   echo $RKE2_VERSION |grep "v1.22.8" ||\
	   echo $RKE2_VERSION |grep "v1.22.9" ||\
	   echo $RKE2_VERSION |grep "v1.22.12" ||\
	   echo $RKE2_VERSION |grep "v1.23.9" ||\
	   echo $RKE2_VERSION |grep "v1.24.3" ||\
	   echo $RKE2_VERSION |grep "v1.22.13" ||\
	   echo $RKE2_VERSION |grep "v1.23.10" ||\
	   echo $RKE2_VERSION |grep "v1.24.4" ||\
	   echo $RKE2_VERSION |grep "v1.24.10" ||\
	   echo $RKE2_VERSION |grep "v1.25.6" ||\
	   echo $RKE2_VERSION |grep "v1.26.1" ||\
	   echo $RKE2_VERSION |grep "v1.24.17" ||\
	   echo $RKE2_VERSION |grep "v1.25.15" ||\
	   echo $RKE2_VERSION |grep "v1.26.10" ||\
	   echo $RKE2_VERSION |grep "v1.27.17" ||\
	   echo $RKE2_VERSION |grep "v1.28.3" ||\
	   echo $RKE2_VERSION |grep "v1.21.11" ; then
                echo "remove rke2-kube-proxy-config.yaml as the deployment method for kube proxy changed"
		sudo rm $RKECLUSTERDIR/manifests/rke2-kube-proxy-config.yaml
		sudo rm /var/lib/rancher/rke2/server/manifests/rke2-kube-proxy-config.yaml
        fi
}

function _FIX_V2_TAILING_SLASH {
        # image pull does not work with tailing slash in registries.yaml in these versions but older versions need the tailing slash
        if [ "$RKE2_VERSION" == "v1.20.15+rke2r1" ] ||\
                [ "$RKE2_VERSION" == "v1.21.9+rke2r1" ] ||\
                [ "$RKE2_VERSION" == "v1.21.10+rke2r2" ] ||\
                [ "$RKE2_VERSION" == "v1.22.8+rke2r1" ] ||\
                [ "$RKE2_VERSION" == "v1.22.9+rke2r2" ] ||\
                [ "$RKE2_VERSION" == "v1.21.11+rke2r1" ] ; then
                sudo sed -i 's/v2\//v2/g' /etc/rancher/rke2/registries.yaml
        fi
}

function _CILIUM_NOT_CANAL {
	if echo $RKE2_VERSION |grep "v1.20.6" && [ -f $RKECLUSTERDIR/manifests/rke2-cilium.yaml ]; then
		echo "Cilium Yaml exists and cluster version is v1.20.6"
		sudo sed -i "/^disable: rke2-canal/d" /etc/rancher/rke2/config.yaml
		sudo bash -c 'echo "disable: rke2-canal" >>/etc/rancher/rke2/config.yaml'
		sudo rm $RKECLUSTERDIR/manifests/rke2-canal*.yaml /var/lib/rancher/rke2/server/manifests/rke2-canal*.yaml
	elif echo $RKE2_VERSION |grep "v1.20.7" ||\
	     echo $RKE2_VERSION |grep "v1.20.8" ||\
	     echo $RKE2_VERSION |grep "v1.20.9" ||\
	     echo $RKE2_VERSION |grep "v1.20.10" ||\
	     echo $RKE2_VERSION |grep "v1.20.11" ||\
	     echo $RKE2_VERSION |grep "v1.20.12" ||\
	     echo $RKE2_VERSION |grep "v1.20.13" ||\
	     echo $RKE2_VERSION |grep "v1.21.2" ||\
	     echo $RKE2_VERSION |grep "v1.21.3" ||\
	     echo $RKE2_VERSION |grep "v1.21.4" ||\
	     echo $RKE2_VERSION |grep "v1.21.5" ||\
	     echo $RKE2_VERSION |grep "v1.21.6" ||\
	     echo $RKE2_VERSION |grep "v1.21.7" ||\
	     echo $RKE2_VERSION |grep "v1.21.9" ||\
	     echo $RKE2_VERSION |grep "v1.21.10" ||\
	     echo $RKE2_VERSION |grep "v1.21.14" ||\
	     echo $RKE2_VERSION |grep "v1.22.8" ||\
	     echo $RKE2_VERSION |grep "v1.22.9" ||\
	     echo $RKE2_VERSION |grep "v1.22.12" ||\
	     echo $RKE2_VERSION |grep "v1.23.9" ||\
	     echo $RKE2_VERSION |grep "v1.24.3" ||\
	     echo $RKE2_VERSION |grep "v1.22.13" ||\
	     echo $RKE2_VERSION |grep "v1.23.10" ||\
	     echo $RKE2_VERSION |grep "v1.24.4" ||\
	     echo $RKE2_VERSION |grep "v1.24.10" ||\
	     echo $RKE2_VERSION |grep "v1.25.6" ||\
	     echo $RKE2_VERSION |grep "v1.26.1" ||\
	     echo $RKE2_VERSION |grep "v1.24.17" ||\
  	     echo $RKE2_VERSION |grep "v1.25.15" ||\
	     echo $RKE2_VERSION |grep "v1.26.10" ||\
	     echo $RKE2_VERSION |grep "v1.27.17" ||\
	     echo $RKE2_VERSION |grep "v1.28.3" ||\
	     echo $RKE2_VERSION |grep "v1.21.11" &&\
   	     [ -f $RKECLUSTERDIR/manifests/rke2-cilium.yaml ]; then
		echo "Cilium Yaml exists and cluster version is v1.20.7-v1.20.15 or v1.21.2-v1.28.3"
		sudo sed -i "/^cni:/d" /etc/rancher/rke2/config.yaml
		sudo bash -c 'echo "cni: cilium" >>/etc/rancher/rke2/config.yaml'
		sudo rm $RKECLUSTERDIR/manifests/rke2-canal*.yaml /var/lib/rancher/rke2/server/manifests/rke2-canal*.yaml
		# do not need this file in 1.20.7 or newer, anymore
		sudo rm $RKECLUSTERDIR/manifests/rke2-cilium.yaml
	else
		echo "Cilium Yaml does not exist or cluster version is not v1.20.7-v1.20.15 or v1.21.2-v1.28.3"
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
                if [ ! -f /usr/bin/rsync ]; then
                        echo "rsync not installed but reqired - installing"
			if [ -f /usr/bin/zypper ]; then
                        	sudo zypper -n in rsync
			fi
			if [ -f /usr/bin/apt-get ]; then
                        	sudo apt-get install rsync -y
			fi
                fi
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
		_FIX_1_20_6
		_FIX_1_20_11
		# just to the first master for the moment as the recognition on "identical" is not based on file content / md5sum or similar
		if [ "$FIRSTMASTER" == "1" ]; then
			echo "copy manifests only on first master until we have better solution to apply only once"
			# try to ensure all files have the same timestamp to apply only once
			sudo touch -d "2021-04-16 11:53" $RKECLUSTERDIR/manifests/*.yaml
			# remove *.yaml file created by touch in case no yaml file exists
			sudo rm $RKECLUSTERDIR/manifests/\*.yaml
			if [ "$FLEET" == "yes" ]; then
				echo "We use fleet so not copying $RKECLUSTERDIR/manifests/*.yaml to /var/lib/rancher/rke2/server/manifests"
				# just copy rancher and gitrepo manifests for fleet
				sudo cp -a $RKECLUSTERDIR/manifests/rancher.yaml /var/lib/rancher/rke2/server/manifests
				sudo cp -a $RKECLUSTERDIR/manifests/gitrepo*.yaml /var/lib/rancher/rke2/server/manifests
			else
				echo "We do not use fleet so copying $RKECLUSTERDIR/manifests/*.yaml to /var/lib/rancher/rke2/server/manifests"
				sudo cp -a $RKECLUSTERDIR/manifests/*.yaml /var/lib/rancher/rke2/server/manifests
			fi
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
                sudo sed -i "s/%%S3_ENDPOINT%%/$S3_ENDPOINT/g" /etc/rancher/rke2/config.yaml
                sudo sed -i "s/%%S3_ACCESSTOKEN%%/$S3_ACCESSTOKEN/g" /etc/rancher/rke2/config.yaml
                sudo sed -i "s/%%S3_SECRET%%/$S3_SECRET/g" /etc/rancher/rke2/config.yaml
                sudo sed -i "s/%%S3_BUCKET%%/$S3_BUCKET/g" /etc/rancher/rke2/config.yaml
                sudo sed -i "s/%%S3_REGION%%/$S3_REGION/g" /etc/rancher/rke2/config.yaml
}

function _VSPHERE_CONFIG {
		# use out of tree vsphere if cpi and csi configs are available -> requires RKE2 >1.20.8!
		if [ -f $RKECLUSTERDIR/manifests/rancher-vsphere-cpi-config.yaml ] && [ $RKECLUSTERDIR/manifests/rancher-vsphere-csi-config.yaml ]; then
			echo "Using out-of-tree vsphere CSI and CPI"
			sudo sed -i 's/cloud-provider-name: vsphere/cloud-provider-name: rancher-vsphere/g' /etc/rancher/rke2/config.yaml
			sudo sed -i '/cloud-provider-config: \/etc\/rancher\/rke2\/vsphere.conf/d' /etc/rancher/rke2/config.yaml
			sudo rm /etc/rancher/rke2/vsphere.conf
			sudo rm $RKECLUSTERDIR/manifests/vsphere-storageclass.yaml
			sudo rm /var/lib/rancher/rke2/server/manifests/vsphere-storageclass.yaml
		else
			echo "Not using out-of-tree vsphere CSI and CPI"
		fi
		if [ -f /etc/rancher/rke2/vsphere.conf ]; then 
			echo "adjust vsphere.conf as it exists"
	                sudo sed -i "s/%%CLUSTER%%/$CLUSTER/g" /etc/rancher/rke2/vsphere.conf
		else
			echo "no vsphere.conf so removing cloud config from config.yaml"
			sudo sed -i '/cloud-provider-name: vsphere/d' /etc/rancher/rke2/config.yaml
			sudo sed -i '/cloud-provider-config: \/etc\/rancher\/rke2\/vsphere.conf/d' /etc/rancher/rke2/config.yaml
		fi
}

function _CLEANUP_IMAGES {
	# after initial startup the images should be extracted so lets delete them to speed up the process for further restarts
		if [ -f /var/lib/rancher/rke2/agent/images/rke2-images.linux-amd64.tar.zst ]; then
			sudo rm /var/lib/rancher/rke2/agent/images/rke2-images.linux-amd64.tar.zst
		fi
		if [ -f $RKECLUSTERDIR/$RKE2_VERSION/rke2-images.linux-amd64.tar.zst ]; then
			rm $RKECLUSTERDIR/$RKE2_VERSION/rke2-images.linux-amd64.tar.zst
		fi
}

function _JOIN_CLUSTER {
        if [ $NODETYPE == "master1" ] ; then
                echo "We are on the first master"
		FIRSTMASTER=1
		MASTER=1
		WORKER=0
                _PREPARE_RKE2_SERVER_CONFIG
                _PREPARE_RKE2_PSA_SERVER_CONFIG
                _PREPARE_RKE2_CLOUD_CONFIG
		_COPY_MANIFESTS_AND_CHARTS
		_ADJUST_CLUSTER_IDENTITY
		_VSPHERE_CONFIG
		_FIX_1_19_DEPLOYMENT
                _FIX_1_20_DEPLOYMENT
                _FIX_1_20_6
		_FIX_V2_TAILING_SLASH
                sudo sed -i "/^server/d" /etc/rancher/rke2/config.yaml
                sudo systemctl enable rke2-server.service 2>&1 >/dev/null;
                sudo systemctl restart rke2-server.service 2>&1 >/dev/null;
		#_CLEANUP_IMAGES
                _ADMIN_PREPARE
		echo "Verify with:  sudo journalctl -u rke2-server -f"
	elif [ $NODETYPE == "master" ] ; then
                echo "We are on a secondary master"
		FIRSTMASTER=0
		MASTER=1
		WORKER=0
                _PREPARE_RKE2_SERVER_CONFIG
                _PREPARE_RKE2_PSA_SERVER_CONFIG
                _PREPARE_RKE2_CLOUD_CONFIG
		_COPY_MANIFESTS_AND_CHARTS
		_ADJUST_CLUSTER_IDENTITY
		_VSPHERE_CONFIG
		_FIX_1_19_DEPLOYMENT
                _FIX_1_20_DEPLOYMENT
                _FIX_1_20_6
		_FIX_V2_TAILING_SLASH
                sudo systemctl enable rke2-server.service 2>&1 >/dev/null;
                sudo systemctl restart rke2-server.service 2>&1 >/dev/null;
		#_CLEANUP_IMAGES
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
		_VSPHERE_CONFIG
		_FIX_1_19_DEPLOYMENT
                _FIX_1_20_DEPLOYMENT
                _FIX_1_20_6
		_FIX_1_20_7
		_FIX_V2_TAILING_SLASH
                sudo systemctl enable rke2-agent.service 2>&1 >/dev/null;
                sudo systemctl restart rke2-agent.service 2>&1 >/dev/null;
		#_CLEANUP_IMAGES
		_AGENT_PREPARE
		echo "Verify with:  sudo journalctl -u rke2-agent -f"
        else
                echo "We are not on a master or worker so deploying only admin tools"
                _ADMIN_PREPARE
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
