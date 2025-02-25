# Runtime Copilot Helm Charts
The main function of the runtime copilot is to assist the operation of the container runtime component (containerd), specifically for adding or deleting non-safe registries.

## Usage

[Helm](https://helm.sh) must be installed to use the charts.  Please refer to
Helm's [documentation](https://helm.sh/docs) to get started.

Once Helm has been set up correctly, add the repo as follows:

    helm repo add runtime-copilot https://lengrongfu.github.io/runtime-copilot

If you is first time to use this repo, you need to run command as follows:

    helm repo update
    helm search repo runtime-copilot

If you had already added this repo earlier, run `helm repo update` to retrieve
the latest versions of the packages.  You can then run `helm search repo
runtime-copilot` to see the charts.

To install the runtime-copilot chart:

    helm install runtime-copilot runtime-copilot/charts --namespace runtime-copilot

To uninstall the chart:

    helm delete runtime-copilot --namespace runtime-copilot