rke-cluster deployment and upgrade

adjust variables in settings.txt

adjust servers parameters in servers.txt

adjust and execute get-rke2.sh to get rke2 versions reqired

adjust and execute cert-manager-cli/get-cert-manager-cli.sh

adjust and exeute helm-cli/get-helm-cli.sh

adjust and execute rancher-cli/get-rancher-cli.sh

rename manifests/rancher to the clustername you have defined for rancher in settings.txt

adjust rke-cluster.sh -> vsphere CPI, credentials, cluster and services CIRD

adjust manifest files in manifests/... - especially s3 credentials and other configs

adust or delete vsphere.conf and yaml files / charts that are not required

add custom CA to tls subdir if required
