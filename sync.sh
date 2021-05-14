#!/bin/bash
if [ "$1" = "" ]; then
	echo "add clustername to command i.e. ./sync.sh rancher or rke-test, rke-int or rke-prod"
	exit 1
fi
CLUSTER_NODES=$(cat /srv/salt/rke-cluster/server.txt|grep $1 |grep -v hostname|cut -f1 -d ",")
DOMAIN=$(cat /srv/salt/rke-cluster/server.txt|grep $1 |grep -v hostname|cut -f2 -d ","|uniq)
echo "applying salt-state rke-cluster to: $CLUSTER_NODES"
salt -L $(echo $CLUSTER_NODES|sed "s/ /.$DOMAIN,"/g) state.apply manager_org_1.rke-cluster
for CLUSTER_NODE in $CLUSTER_NODES; do 
	ROLE=$(grep $CLUSTER_NODE /srv/salt/rke-cluster/server.txt|cut -f6 -d ",")
	echo "executing rke-cluster.sh on server $CLUSTER_NODE"
	salt $CLUSTER_NODE.$DOMAIN "cmd.shell /home/rkeadmin/rke-cluster/rke-cluster.sh"
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
