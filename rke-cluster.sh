#!/bin/bash 
#
######################################################
# v0.1 25.03.2021 Martin Weiss - Martin.Weiss@suse.com
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
# - move variables in setting.txt
# - manage kubeconfig with rights
# - allow rkeadmin to manage cri / crictl
# - add a detection on secondary masters to wait until join is possible
#
######################################################

# ------------------------------
# Variables
# ------------------------------

# define the default rke2 version to be used
RKE2_VERSION="v1.19.7+rke2r1"

# get the dns domain of the server
DOMAIN=$(/usr/bin/hostname -d)

# on premise registry to be used (https will always be used)
REGISTRY="registry01.suse:5000"

# registry credentials - required for registry authentication in containerd
# use one bot user per cluster
RANCHER_USERNAME="rancher-cluster"
RANCHER_PASSWORD="6t2n-NtR5DeWCfCwBkrV"
PROD_USERNAME="rke-prod-cluster"
PROD_PASSWORD="omE-NsRgyuxLs8h-quKZ"
INT_USERNAME="rke-int-cluster"
INT_PASSWORD="F8RBf8NtmMqearESeZ43"
TEST_USERNAME="rke-test-cluster"
TEST_PASSWORD="_Ey4sYq1wAyBUSfjcsQY"

# registry credentials for docker login in v1.19.7+rke2r1
PROD_CREDS="$(echo -n $PROD_USERNAME:$PROD_PASSWORD|base64)"
RANCHER_CREDS="$(echo -n $RANCHER_USERNAME:$RANCHER_PASSWORD|base64)"
INT_CREDS="$(echo -n $INT_USERNAME:$INT_PASSWORD|base64)"
TEST_CREDS="$(echo -n $TEST_USERNAME:$TEST_PASSWORD|base64)"

# detect cluster and set version
function _DETECT_CLUSTER {
        if hostname|grep rancher; then
                CLUSTER="rancher"
                STAGE="prod"
		USERNAME=$RANCHER_USERNAME
		PASSWORD=$RANCHER_PASSWORD
		CREDS=$RANCHER_CREDS
		RKE2_VERSION="v1.19.7+rke2r1"
        elif hostname|grep test; then
                CLUSTER="rke-test"
                STAGE="test"
		USERNAME=$TEST_USERNAME
		PASSWORD=$TEST_PASSWORD
		CREDS=$TEST_CREDS
		#RKE2_VERSION="v1.19.7+rke2r1"
		RKE2_VERSION="v1.20.4+rke2r1"
        elif hostname|grep int; then
                CLUSTER="rke-int"
                STAGE="int"
		USERNAME=$INT_USERNAME
		PASSWORD=$INT_PASSWORD
		CREDS=$INT_CREDS
		RKE2_VERSION="v1.19.7+rke2r1"
        elif hostname|grep prod; then
                CLUSTER="rke-prod"
                STAGE="prod"
		USERNAME=$PROD_USERNAME
		PASSWORD=$PROD_PASSWORD
		CREDS=$PROD_CREDS
		RKE2_VERSION="v1.19.7+rke2r1"
        fi
	echo CLUSTER is $CLUSTER
	echo STAGE is $STAGE
	echo RKE2_VERSION is $RKE2_VERSION
}

# end o variables

function _INSTALL_RKE2 {
	# hoping to replace this with an RPM for SLES 15 SP2, soon
	echo "Install RKE2 from Tarball"
	# this part should be part of the SUSE RPM for RKE2 once we have it
	sudo tar xzvf /home/rkeadmin/rke-cluster/$RKE2_VERSION/rke2.linux-amd64.tar.gz -C /usr/local 2>&1 >/dev/null;
	# for security based on rke2 docs
	sudo useradd -r -c "etcd user" -s /sbin/nologin -M etcd 2>&1 >/dev/null
	sudo cp -f /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
	sudo systemctl restart systemd-sysctl 2>&1 >/dev/null
	# copy systemd unit files to etc due to "reboot not starting the service in case /usr/local is not part of the root filesystem"
	sudo cp /usr/local/lib/systemd/system/rke2-agent.service /etc/systemd/system/rke2-agent.service
	sudo cp /usr/local/lib/systemd/system/rke2-server.service /etc/systemd/system/rke2-server.service
	sudo systemctl daemon-reload;
	# create target dir for configs of rke2
	sudo mkdir -p /etc/rancher/rke2
	# workaround in v1.19.7+rke2r1 for authentication for base images from on-premise registry with authentication
	sudo bash -c 'cat << EOF > /etc/default/rke2-server
HOME=/root
EOF'
	sudo bash -c 'cat << EOF > /etc/default/rke2-agent
HOME=/root
EOF'
}

function _PREPARE_RKE2_SERVER_CONFIG {
	echo "Create server config.yaml"
	# adjust CIRD to networks not used for services in the local infrastructure
	# needs also adjustment in kube-proxy and canal deployments!
	sudo bash -c 'cat << EOF > /etc/rancher/rke2/config.yaml
write-kubeconfig-mode: "0640"
server: https://%%CLUSTER%%.%%DOMAIN%%:9345
cluster-cidr: "172.27.0.0/16"
service-cidr: "172.28.0.0/16"
cluster-dns: "172.28.0.10"
cloud-provider-name: vsphere
cloud-provider-config: /etc/rancher/rke2/vsphere.conf
private-registry: /etc/rancher/rke2/registries.yaml
agent-token: %%CLUSTER%%-token-asfebwadg
token: %%CLUSTER%%-token-asfebwadg
system-default-registry: %%REGISTRY%%/rke-%%STAGE%%/docker.io
profile: cis-1.5
tls-san:
  - "%%CLUSTER%%.%%DOMAIN%%"
node-label:
  - "cluster=%%CLUSTER%%"
EOF'
	if ! [ $CLUSTER == "rancher" ]; then
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
system-default-registry: %%REGISTRY%%/rke-%%STAGE%%/docker.io
server: https://%%CLUSTER%%.%%DOMAIN%%:9345
profile: cis-1.5
node-label:
  - "cluster=%%CLUSTER%%"
EOF'
}

function _PREPARE_RKE2_CLOUD_CONFIG {
	echo "Create vsphere.conf"
	sudo bash -c 'cat << EOF > /etc/rancher/rke2/vsphere.conf
[Global]
user = "terraform-kubernetes@vsphere.local"
password = "Suse1234!"
port = "443"
insecure-flag = "1"

[VirtualCenter "vsphere.suse"]
datacenters = "Datacenter1"

[Workspace]
server = "vsphere.suse"
datacenter = "Datacenter1"
default-datastore = "datastore1"
resourcepool-path = "Cluster1/Resources"
folder = "/Datacenter1/vm/Kubernetes/%%CLUSTER%%"

[Disk]
scsicontrollertype = pvscsi

#[Network]
#public-network = "192-168-0"

#[Labels]
#region = "<VC_DATACENTER_TAG>"
#zone = "<VC_CLUSTER_TAG>"

EOF'
}

function _PREPARE_REGISTRIES_YAML {
	# required for registry mapping (missing namespace mapping feature compared to crio!!)
	# required for global registry authentication for the cluster
	echo "Prepare Registries YAML"
	sudo cp /home/rkeadmin/rke-cluster/registries.yaml /etc/rancher/rke2/
        sudo sed -i "s/%%STAGE%%/$STAGE/g" /etc/rancher/rke2/registries.yaml
        sudo sed -i "s/%%USERNAME%%/$USERNAME/g" /etc/rancher/rke2/registries.yaml
        sudo sed -i "s/%%PASSWORD%%/$PASSWORD/g" /etc/rancher/rke2/registries.yaml
        sudo sed -i "s/%%REGISTRY%%/$REGISTRY/g" /etc/rancher/rke2/registries.yaml
}

function _PREPARE_DOCKER_CREDENTIALS {
	# for v1.19.7+rke2r1 to pull the base images with authentication from on-premise registry
	echo "Prepare Docker Credentials"
	sudo mkdir -p /root/.docker
	sudo cp /home/rkeadmin/rke-cluster/config.json /root/.docker/config.json
        sudo sed -i "s/%%REGISTRY%%/$REGISTRY/g" /root/.docker/config.json
	sudo sed -i "s/%%CREDS%%/$CREDS/g" /root/.docker/config.json
}

function _ADMIN_PREPARE {
	echo "Prepare Admin Tools"
	# take helm3 from caasp 4.5 channels - needs to be replaced with helm3 delivery from "somewhere else"
	sudo zypper -n in helm3
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
	sudo bash -c '/var/lib/rancher/rke2/bin/kubectl completion bash > /usr/share/bash-completion/completions/kubectl'
	sudo bash -c '/usr/bin/helm completion bash > /usr/share/bash-completion/completions/helm'
	sudo chmod 644 /usr/share/bash-completion/completions/kubectl
	sudo chmod 644 /usr/share/bash-completion/completions/helm
	# kube config
	# prepare kubeconfig for user root and rkeadmin in case environment is not set
	# have to wait until kubeconfig is created by rke2-server service
	while [ ! -f /etc/rancher/rke2/rke2.yaml ]; do
		echo "waiting on /etc/rancher/rke2/rke2.yaml to be available"
		sleep 1
	done
	mkdir -p /home/rkeadmin/.kube
	ln -s /etc/rancher/rke2/rke2.yaml /home/rkeadmin/.kube/config 2>&1 >/dev/null
	sudo chown rkeadmin:users /home/rkeadmin/.kube
	sudo mkdir -p /root/.kube
	sudo ln -s /etc/rancher/rke2/rke2.yaml /root/.kube/config 2>&1 >/dev/null
	# give rkeadmin group access to kubeconfig
	sudo chgrp rkeadmin /etc/rancher/rke2/rke2.yaml
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

function _COPY_MANIFESTS_AND_CHARTS {
		echo "Copy default manifests and charts to master"
		# all masters need all static charts as we can not download them from helm repo that has self-signed certificate
		# all masters should have the same
		# also delete stuff that is not required anymore
		# during upgrades we might deliver "other" charts - depending on dependencies and upgrade procedures
		sudo mkdir -p /var/lib/rancher/rke2/server/manifests
		sudo mkdir -p /var/lib/rancher/rke2/server/static/charts
		sudo rsync -a --delete /home/rkeadmin/rke-cluster/$RKE2_VERSION/static/charts/$CLUSTER/* /var/lib/rancher/rke2/server/static/charts
		sudo rsync -a --delete /home/rkeadmin/rke-cluster/$RKE2_VERSION/manifests/$CLUSTER/* /var/lib/rancher/rke2/server/manifests

}

function _FIX_1_20_4_DEPLOYMENT {
	# change in system-default-registry does not allow namespace anymore
	sudo sed -i "s/^system-default-registry:.*/system-default-registry: $REGISTRY/g" /etc/rancher/rke2/config.yaml
	# due to missing namespacee support for initial images have to use tarball
	sudo mkdir -p /var/lib/rancher/rke2/agent/images 
	sudo cp -av /home/rkeadmin/rke-cluster/v1.20.4+rke2r1/rke2-images.linux-amd64.tar.zst /var/lib/rancher/rke2/agent/images
	if grep airgap-extra-registry /etc/rancher/rke2/config.yaml && [ $WORKER == "0" ]; then
		echo "airgap-extra-registry already set or we are on a master"
	else
		echo "adding airgap-extra-registry as workaround for not setting proper image tags on workers"
		sudo bash -c "echo airgap-extra-registry: $REGISTRY >> /etc/rancher/rke2/config.yaml"
	fi
}

function _ADJUST_CLUSTER_IDENTITY {
		# replace placeholders in config.yaml template
                sudo sed -i "s/%%CLUSTER%%/$CLUSTER/g" /etc/rancher/rke2/config.yaml
                sudo sed -i "s/%%DOMAIN%%/$DOMAIN/g" /etc/rancher/rke2/config.yaml
                sudo sed -i "s/%%REGISTRY%%/$REGISTRY/g" /etc/rancher/rke2/config.yaml
        	sudo sed -i "s/%%STAGE%%/$STAGE/g" /etc/rancher/rke2/config.yaml
                sudo sed -i "s/%%CLUSTER%%/$CLUSTER/g" /etc/rancher/rke2/vsphere.conf
		# have to adopt 1.20.4 workaround before starting the cluster
		if [ "$RKE2_VERSION" == "v1.20.4+rke2r1" ]; then
			_FIX_1_20_4_DEPLOYMENT
		fi
}

function _JOIN_CLUSTER {
        if hostname|grep master-01; then
                echo "We are on the first master"
		FIRSTMASTER=1
		MASTER=1
		WORKER=0
                _PREPARE_RKE2_SERVER_CONFIG
                _PREPARE_RKE2_CLOUD_CONFIG
		_COPY_MANIFESTS_AND_CHARTS
		_ADJUST_CLUSTER_IDENTITY
                sudo sed -i "/^server/d" /etc/rancher/rke2/config.yaml
                sudo systemctl enable rke2-server.service 2>&1 >/dev/null;
                sudo systemctl restart rke2-server.service 2>&1 >/dev/null;
                _ADMIN_PREPARE
		echo "Verify with:  sudo journalctl -u rke2-server -f"
	elif hostname |grep master; then
                echo "We are on a secondary master"
		FIRSTMASTER=0
		MASTER=1
		WORKER=0
                _PREPARE_RKE2_SERVER_CONFIG
                _PREPARE_RKE2_CLOUD_CONFIG
		_COPY_MANIFESTS_AND_CHARTS
		_ADJUST_CLUSTER_IDENTITY
                sudo systemctl enable rke2-server.service 2>&1 >/dev/null;
                sudo systemctl restart rke2-server.service 2>&1 >/dev/null;
                _ADMIN_PREPARE
		echo "Verify with:  sudo journalctl -u rke2-server -f"
        elif hostname |grep worker; then
                echo "We are on a worker"
		FIRSTMASTER=0
		MASTER=0
		WORKER=1
                _PREPARE_RKE2_AGENT_CONFIG
                _PREPARE_RKE2_CLOUD_CONFIG
		_ADJUST_CLUSTER_IDENTITY
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
