apiVersion: helm.cattle.io/v1
kind: HelmChart
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  jobImage: %%REGISTRY%%/%%STAGE%%/docker.io/rancher/klipper-helm:v0.4.3
  chart: https://%%CLUSTER%%.%%DOMAIN%%:9345/static/charts/rke2-cilium-1.9.402.tgz
  bootstrap: true
  set:
    global.rke2DataDir: /var/lib/rancher/rke2
    global.systemDefaultRegistry: "%%REGISTRY%%/%%STAGE%%/docker.io"
  valuesContent: |-
    global:
      cattle:
        systemDefaultRegistry: "%%REGISTRY%%/%%STAGE%%/docker.io"
        clusterName: %%CLUSTER%%
      systemDefaultRegistry: "%%REGISTRY%%/%%STAGE%%/docker.io"
    cilium:
      ipam:
        mode: "kubernetes"
      image:
        repository: %%REGISTRY%%/%%STAGE%%/docker.io/rancher/mirrored-cilium-cilium
      operator:
        image:
          repository: %%REGISTRY%%/%%STAGE%%/docker.io/rancher/mirrored-cilium-operator
      nodeinit:
        image:
          repository: %%REGISTRY%%/%%STAGE%%/docker.io/rancher/mirrored-cilium-startup-script
      preflight:
        image:
          repository: %%REGISTRY%%/%%STAGE%%/docker.io/rancher/mirrored-cilium-cilium
