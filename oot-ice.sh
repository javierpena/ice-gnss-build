#!/bin/bash

set -eu

exit_on_error () {
  local rc="$1"

  if [[ $rc -ne 0 ]]; then
    echo "ERROR: $rc"
    exit $rc
  fi
}

print_usage () {
cat <<- END_OF_HELP
    usage: $(basename $0) [-h] [-r] [-o] [-t] <ice_vers>

    The environment variable REGISTRY must be set.
    This is the registry that the driver container will be pushed to.

    Build the Intel out of tree ice driver and GNSS module for Redhat OCP
      -h: Print this help.
      -o: Use this specific OCP version.
          This option must be given if the KUBECONFIG env variable is not set
          or an OCP version other than the KUBECONFIG cluster version is desired.
      -r: Build the RT version of the OCP kernel.
      -t: Specific tag of the Linux kernel source code to use for building the
          GNSS driver as an external module. Default value is v5.19
END_OF_HELP
}

build_image () {
  BASE_IMAGE='registry.access.redhat.com/ubi8-minimal:latest'
  TAG=${KERNEL_VER}
  DTK_IMAGE=$(oc adm release info --image-for=driver-toolkit quay.io/openshift-release-dev/ocp-release:${OCP_VER}-x86_64)
  echo "Building for kernel:${KERNEL_VER} on OCP:${OCP_VER}"
  echo "DTKI for OCP:${OCP_VER} : ${DTK_IMAGE}"

  podman build -f Dockerfile --no-cache . \
    --build-arg IMAGE=${BASE_IMAGE} \
    --build-arg BUILD_IMAGE=${DTK_IMAGE} \
    --build-arg DRIVER_VER=${DRIVER_VER} \
    --build-arg KERNEL_VERSION=${KERNEL_VER} \
    --build-arg GNSS_KERNEL_TAG=${GNSS_KERNEL_TAG} \
    -t ${REGISTRY}/${DRIVER_IMAGE}:${TAG}
  exit_on_error $?

}

push_image () {
  podman push --tls-verify=false ${REGISTRY}/${DRIVER_IMAGE}:${TAG}
  exit_on_error $?
}

generate_machine_config () {

  local service=$(base64 -w 0 service.sh)
  local ptp_config=$(base64 -w 0 ptp-config.sh)

cat <<- END_OF_MACHINE_CONFIG > mc-oot-ice-gnss.yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: 10-oot-ice-gnss
spec:
  config:
    ignition:
     version: 3.2.0
    storage:
      files:
        - contents:
            source: 'data:text/plain;charset=us-ascii;base64,$service'
          filesystem: root
          mode: 493
          path: /usr/local/bin/oot-ice
        - contents:
            source: 'data:text/plain;charset=us-ascii;base64,$ptp_config'
          filesystem: root
          mode: 493
          path: /usr/local/bin/ptp-config
    systemd:
      units:
      - contents: |
          [Unit]
          Description=out-of-tree driver loader
          # Start after the network is up
          Wants=network-online.target
          After=network-online.target
          # Also after docker.service (no effect on systems without docker)
          After=docker.service
          # Before kubelet.service (no effect on systems without kubernetes)
          Before=kubelet.service

          [Service]
          Type=oneshot
          RemainAfterExit=true
          # Use bash to workaround https://github.com/coreos/rpm-ostree/issues/1936
          ExecStart=/usr/bin/bash -c "/usr/local/bin/oot-ice load  ${REGISTRY}/${DRIVER_IMAGE}"
          ExecStop=/usr/bin/bash -c "/usr/local/bin/oot-ice unload ${REGISTRY}/${DRIVER_IMAGE}"
          ExecStartPost=/usr/bin/bash -c "/usr/local/bin/ptp-config"
          StandardOutput=journal+console

          [Install]
          WantedBy=default.target
        enabled: true
        name: "oot-ice.service"
  kernelArguments:
    - firmware_class.path=/var/lib/firmware
END_OF_MACHINE_CONFIG
}

# Default values
KERNEL_VER=""
BUILD_RT="no"
OCP_VER=""
GNSS_KERNEL_TAG="v5.19"
KUBECONFIG=${KUBECONFIG:-""}

REGISTRY=${REGISTRY:-""}
if [ -z ${REGISTRY} ]; then
   echo "The environment variable REGISTRY must be set."
   exit 1
fi

while getopts hrc:k:o:t ARG ; do
  case $ARG in
    o ) OCP_VER=$OPTARG ;;
    r ) BUILD_RT="yes" ;;
    t ) GNSS_KERNEL_TAG=$OPTARG ;;
    h ) print_usage ; exit 0 ;;
    ? ) print_usage ; exit 1 ;;
  esac
done
shift $(($OPTIND - 1))

if [ $# -lt 1 ]; then
  print_usage
  exit 1
fi
DRIVER_VER=$1; shift

# Try to get the OCP version from the cluster in KUBECONFIG
if [ -z ${OCP_VER} ]; then
  if [ -z ${KUBECONFIG} ]; then
    echo "Please specify -o or properly set your KUBECONFIG env variable"
    exit 1
  fi
  OCP_VER=$(oc get clusterversions/version -o json  | jq -r ".status.desired.version")
  exit_on_error $?
fi


DRIVER_IMAGE="ice-gnss-${DRIVER_VER}"

# Building for an OCP kernel.
MACHINE_OS=$(oc adm release info --image-for=machine-os-content quay.io/openshift-release-dev/ocp-release:${OCP_VER}-x86_64)
if [ ${BUILD_RT} == "yes" ]; then
    KERNEL_VER=$(oc image info -o json ${MACHINE_OS}  | jq -r ".config.config.Labels[\"com.coreos.rpm.kernel-rt-core\"]")
else
    KERNEL_VER=$(oc get nodes -o json | jq -r ".items[0].status.nodeInfo.kernelVersion")
fi

build_image

generate_machine_config

push_image
