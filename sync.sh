#!/bin/bash
if [ "$1" = "" ]; then
	echo "add clustername to command i.e. ./sync.sh rancher or rke-test, rke-int or rke-prod"
	exit 1
fi
if [ "$1" == "rancher" ]; then 
	CLUSTER_NODES=$(cat /srv/salt/rke-cluster/server.txt|grep $1 |grep -v hostname|cut -f1 -d ",")
else
	CLUSTER_NODES=$(cat /srv/salt/rke-cluster/server.txt|grep $1 |grep -v ^rancher |grep -v hostname|cut -f1 -d ",")
fi
DOMAIN=$(cat /srv/salt/rke-cluster/server.txt|grep $1 |grep -v hostname|cut -f2 -d ","|uniq)
CLUSTER_NODES_LIST=$(for CLUSTER_NODE in $CLUSTER_NODES; do echo -n $CLUSTER_NODE.$DOMAIN,; done|sed 's/,$//g')
echo "applying salt-state rke-cluster to: $CLUSTER_NODES_LIST"
salt -L $CLUSTER_NODES_LIST state.apply manager_org_1.rke-cluster
for CLUSTER_NODE in $CLUSTER_NODES; do	
	ROLE=$(grep $CLUSTER_NODE /srv/salt/rke-cluster/server.txt|cut -f6 -d ",")
	echo "checking if node is rebooted after patching"
	PATCHED="5"
	while [ "$PATCHED" == "5" ]; do
		# need to be enhanced - does not work in case there are no patches that require a reboot
		echo "PATCHED for $CLUSTER_NODE.$DOMAIN is $PATCHED"
		PATCHED=$(salt $CLUSTER_NODE.$DOMAIN cmd.shell "last reboot"|wc -l)
		echo "PATCHED for $CLUSTER_NODE.$DOMAIN is $PATCHED"
		sleep 5
	done
	echo "executing rke-cluster.sh on server $CLUSTER_NODE"
	salt $CLUSTER_NODE.$DOMAIN cmd.shell "bash /home/rkeadmin/rke-cluster/rke-cluster.sh"
	if [ "$2" == "nosleep" ]; then
		echo "skip sleep"
	else
		if [ $ROLE == "master1" ] || [ $ROLE == "master" ]; then
			echo "master deployed - waiting 60 seconds"
			sleep 60
		else
			echo "worker deployed - waiting 10 seconds"
			sleep 10
		fi
	fi
done
