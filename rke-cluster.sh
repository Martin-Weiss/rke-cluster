#!/bin/bash 

# ------------------------------
# Open ToDo
# ------------------------------
# 
# - move variables in setting.txt
# - manage kubeconfig with rights
# - allow rkeadmin to manage cri / crictl

# ------------------------------
# Variables
# ------------------------------

RKE2_VERSION="v1.19.7+rke2r1"

DOMAIN=$(/usr/bin/hostname -d)

# registry details
REGISTRY="registry01.suse:5000"

# required for registry authentication in containerd
RANCHER_USERNAME="rancher-cluster"
RANCHER_PASSWORD="6t2n-NtR5DeWCfCwBkrV"
PROD_USERNAME="rke-prod-cluster"
PROD_PASSWORD="omE-NsRgyuxLs8h-quKZ"
INT_USERNAME="rke-int-cluster"
INT_PASSWORD="F8RBf8NtmMqearESeZ43"
TEST_USERNAME="rke-test-cluster"
TEST_PASSWORD="_Ey4sYq1wAyBUSfjcsQY"

# required for docker login credentials
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
	echo "Install RKE2 from Tarball"
	# this part should be part of the SUSE RPM for RKE2 once we have it
	sudo tar xzvf /home/rkeadmin/rke-cluster/$RKE2_VERSION/rke2.linux-amd64.tar.gz -C /usr/local 2>&1 >/dev/null;
	sudo useradd -r -c "etcd user" -s /sbin/nologin -M etcd 2>&1 >/dev/null
	sudo cp -f /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
	sudo systemctl restart systemd-sysctl 2>&1 >/dev/null
	sudo cp /usr/local/lib/systemd/system/rke2-agent.service /etc/systemd/system/rke2-agent.service
	sudo cp /usr/local/lib/systemd/system/rke2-server.service /etc/systemd/system/rke2-server.service
	sudo mkdir -p /etc/rancher/rke2
	sudo bash -c 'cat << EOF > /etc/default/rke2-server
HOME=/root
EOF'
	sudo bash -c 'cat << EOF > /etc/default/rke2-agent
HOME=/root
EOF'
	sudo systemctl daemon-reload;
}

function _PREPARE_RKE2_SERVER_CONFIG {
	echo "Create server config.yaml"
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
	echo "Prepare Registries YAML"
	sudo cp /home/rkeadmin/rke-cluster/registries.yaml /etc/rancher/rke2/
        sudo sed -i "s/%%STAGE%%/$STAGE/g" /etc/rancher/rke2/registries.yaml
        sudo sed -i "s/%%USERNAME%%/$USERNAME/g" /etc/rancher/rke2/registries.yaml
        sudo sed -i "s/%%PASSWORD%%/$PASSWORD/g" /etc/rancher/rke2/registries.yaml
        sudo sed -i "s/%%REGISTRY%%/$REGISTRY/g" /etc/rancher/rke2/registries.yaml
}

function _PREPARE_DOCKER_CREDENTIALS {
	echo "Prepare Docker Credentials"
	sudo mkdir -p /root/.docker
	sudo cp /home/rkeadmin/rke-cluster/config.json /root/.docker/config.json
        sudo sed -i "s/%%REGISTRY%%/$REGISTRY/g" /root/.docker/config.json
	sudo sed -i "s/%%CREDS%%/$CREDS/g" /root/.docker/config.json
}

function _ADMIN_PREPARE {
	echo "Prepare Admin Tools"
	sudo zypper -n in helm3
	# .bashrc
	sudo bash -c 'cat << EOF > /etc/profile.local
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml
export PATH=\$PATH:/var/lib/rancher/rke2/bin
EOF'
	# bash completion
	while [ ! -f /var/lib/rancher/rke2/bin/kubectl ]; do
		echo "waiting on /var/lib/rancher/rke2/bin/kubectl to be available"
		sleep 1
	done
	sudo bash -c '/var/lib/rancher/rke2/bin/kubectl completion bash > /usr/share/bash-completion/completions/kubectl'
	sudo bash -c '/usr/bin/helm completion bash > /usr/share/bash-completion/completions/helm'
	sudo chmod 644 /usr/share/bash-completion/completions/kubectl
	sudo chmod 644 /usr/share/bash-completion/completions/helm
	# kube config
	while [ ! -f /etc/rancher/rke2/rke2.yaml ]; do
		echo "waiting on /etc/rancher/rke2/rke2.yaml to be available"
		sleep 1
	done
	mkdir -p /home/rkeadmin/.kube
	ln -s /etc/rancher/rke2/rke2.yaml /home/rkeadmin/.kube/config 2>&1 >/dev/null
	sudo chown rkeadmin:users /home/rkeadmin/.kube
	sudo mkdir -p /root/.kube
	sudo ln -s /etc/rancher/rke2/rke2.yaml /root/.kube/config 2>&1 >/dev/null
	sudo chgrp rkeadmin /etc/rancher/rke2/rke2.yaml
	export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
	export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml
	export PATH=$PATH:/var/lib/rancher/rke2/bin
}

function _AGENT_PREPARE {
	echo "Prepare Agent Tools"
	sudo bash -c 'cat << EOF > /etc/profile.local
export CRI_CONFIG_FILE=/var/lib/rancher/rke2/agent/etc/crictl.yaml
export PATH=$PATH:/var/lib/rancher/rke2/bin
EOF'
}

function _COPY_MANIFESTS_AND_CHARTS {
		echo "Copy default manifests and charts to master"
		sudo mkdir -p /var/lib/rancher/rke2/server/manifests
		sudo mkdir -p /var/lib/rancher/rke2/server/static/charts
		sudo rsync -a --delete /home/rkeadmin/rke-cluster/$RKE2_VERSION/static/charts/$CLUSTER/* /var/lib/rancher/rke2/server/static/charts
		sudo rsync -a --delete /home/rkeadmin/rke-cluster/$RKE2_VERSION/manifests/$CLUSTER/* /var/lib/rancher/rke2/server/manifests

}

function _ADJUST_CLUSTER_IDENTITY {
                sudo sed -i "s/%%CLUSTER%%/$CLUSTER/g" /etc/rancher/rke2/config.yaml
                sudo sed -i "s/%%DOMAIN%%/$DOMAIN/g" /etc/rancher/rke2/config.yaml
                sudo sed -i "s/%%REGISTRY%%/$REGISTRY/g" /etc/rancher/rke2/config.yaml
        	sudo sed -i "s/%%STAGE%%/$STAGE/g" /etc/rancher/rke2/config.yaml
                sudo sed -i "s/%%CLUSTER%%/$CLUSTER/g" /etc/rancher/rke2/vsphere.conf
}

function _JOIN_CLUSTER {
        if hostname|grep master-01; then
                echo "We are on the first master"
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
