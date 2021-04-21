apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
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
