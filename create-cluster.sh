#!/usr/bin/env bash
set -e

usage() {
  cat << EOF
Usage: $0
  Required Args:
    -c <clusterName>      (example: mycluster01)
    -a <machineNetworkIP> (example: 172.18.0.0)

  Optional Args:
    -b <baseDomain>     (default: patternfly.org)
    -m <masterFlavor>   (default: quicklab.ocp4.master)
    -n <masterCount>    (default: 3)
    -w <workerFlavor>   (default: quicklab.ocp4.worker)
    -x <workerCount>    (default: 3)
    -h (echo this message)
EOF
  exit 1
}

while getopts ":a:b:c:m:n:w:x:h:" o; do
  case "${o}" in
    a)
      MACH_NET_ADDR=${OPTARG}
      ;;
    b)
      BASE_DOMAIN=${OPTARG}
      ;;
    c)
      CLUSTER_NAME=${OPTARG}
      ;;
    m)
      MASTER_FLAVOR=${OPTARG}
      ;;
    n)
      MASTER_COUNT=${OPTARG}
      ;;
    w)
      WORKER_FLAVOR=${OPTARG}
      ;;
    x)
      WORKER_COUNT=${OPTARG}
      ;;
    h)
      usage
      ;;
    *)
      usage
      ;;
  esac
done
shift $((OPTIND-1))

# required args
if [ -z "${CLUSTER_NAME}" ]; then
  echo "ERROR: clusterName is a required argument!
  Example: -c mycluster"
  usage

elif [[ "${CLUSTER_NAME}" =~ [^a-z0-9] ]]; then
  echo "ERROR: clusterName must be all lower case and only contain alphanumeric characters!
  Exmaples: mycluster, mycluster001"
fi

if [ -z "${MACH_NET_ADDR}" ]; then
  echo "ERROR: machineNetworkIP is a required argument!
  Example: -a 172.30.0.0"
  usage
fi

# Somewhere you can create A* DNS entries (default patternfly.org)
export BASE_DOMAIN=${BASE_DOMAIN:-patternfly.org}

# default cnt: 3 servers
MASTER_COUNT=${MASTER_COUNT:-3}
# default flavor: quicklab.ocp4.master
export MASTER_FLAVOR=${MASTER_FLAVOR:-quicklab.ocp4.master}

# default cnt: 3 servers
WORKER_COUNT=${WORKER_COUNT:-3}
# default flavor: quicklab.ocp4.worker (2 VCPU, 8GB RAM)
export WORKER_FLAVOR=${WORKER_FLAVOR:-quicklab.ocp4.worker}

export OPENSTACK_EXTERNAL_NETWORK=provider_net_shared_3
CLUSTER_OS_IMAGE=rhcos-4.4.3
export PULL_SECRET=$(cat pull-secret.txt)

# In case you have to ssh in and debug
export SSH_PUB_KEY=$(cat $HOME/.ssh/id_rsa.pub)

getFIP() {
  local _description="${CLUSTER_NAME} $1"

  local _fip=$(openstack floating ip list --long -c "Floating IP Address" -c Description -f value | grep "$_description" | awk 'NR==1 {print $1}')

  if [ -z "$_fip" ]; then
    _fip=$(openstack floating ip create --description "$_description" provider_net_shared_3 -f value -c floating_ip_address)
  fi

  echo "$_fip"
}

# validate a given flavor is available
isFlavor() {
  local _flavor=$1
  if ! openstack flavor show ${_flavor} > /dev/null 2>&1; then
    echo "ERROR: cluster flavor does not exist: ${_flavor}"
    exit 2
  fi
}

# validate if the given ip address range is already used
isNetUsed() {
  local netIP=$1
  local netName=$2

  if openstack floating ip list -c "Fixed IP Address" -f value \
  |grep $(echo ${netIP} |awk -F. '{print$1"."$2}') > /dev/null 2>&1; then
    echo "ERROR: IP Range Already In Use: ${netIP}"
    exit 3
  else
    echo "INFO: Using IP Range ${netIP}/16 for ${netName}"
  fi
}


# imageContentSources:
#  - source: quay.io/openshift-release-dev/ocp-release@4.4.9-x86_64

create_install_config() {
  cat > install-config.yaml << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform:
    openstack:
      type: ${WORKER_FLAVOR}
  replicas: ${WORKER_COUNT}
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform: {}
  replicas: ${MASTER_COUNT}
metadata:
  name: ${CLUSTER_NAME}
networking:
  # Stay out of the 10.x namespace as there are collisions with openstack services
  clusterNetwork:
  - cidr: 172.20.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: ${MACH_NET_ADDR}/16
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.19.0.0/16
platform:
  openstack:
    cloud: openstack
    externalNetwork:  ${OPENSTACK_EXTERNAL_NETWORK}
    clusterOSImage:   ${CLUSTER_OS_IMAGE}
    computeFlavor:    ${MASTER_FLAVOR}
    lbFloatingIP:     "${API_FIP}"
pullSecret: '${PULL_SECRET}'
sshKey: ${SSH_PUB_KEY}
EOF
}

append_hosts() {
  start_comment="# Generated for ${CLUSTER_NAME}.${BASE_DOMAIN}"
  end_comment="# End of ${CLUSTER_NAME}.${BASE_DOMAIN}"
  hosts="$start_comment
$API_FIP api.${CLUSTER_NAME}.${BASE_DOMAIN}
$INGRESS_FIP console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
$INGRESS_FIP integrated-oauth-server-openshift-authentication.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
$INGRESS_FIP oauth-openshift.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
$INGRESS_FIP prometheus-k8s-openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
$INGRESS_FIP grafana-openshift-monitoring.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
$end_comment"

  regex="/$start_comment/,/$end_comment/"
  old_hosts=$(awk "$regex" /etc/hosts)

  if [ "${hosts}" != "${old_hosts}" ]; then
    echo "Updating hosts file"
    # check if it is mac OS, sed is not GNU
    if [ `uname -s` == "Darwin" ]; then
      sudo sed -i '' "${regex}d" /etc/hosts
    else
      sudo sed -i "${regex}d" /etc/hosts
    fi
    echo "$hosts" | sudo tee -a /etc/hosts
  fi
}

# execute
API_FIP=$(getFIP "API")
INGRESS_FIP=$(getFIP "Ingress")

isFlavor ${MASTER_FLAVOR}
isFlavor ${WORKER_FLAVOR}

isNetUsed ${MACH_NET_ADDR} machineNetwork

create_install_config
append_hosts

openshift-install create cluster

INGRESS_PORT=$(openstack port list --format value -c Name | awk "/${CLUSTER_NAME}.*-ingress-port/ {print}")
echo "Attaching ingress port ${INGRESS_PORT} to FIP ${INGRESS_FIP}"
openstack floating ip set --port ${INGRESS_PORT} ${INGRESS_FIP}

echo "
Create the following DNS entries:

  api.${CLUSTER_NAME}.${BASE_DOMAIN}.  IN  A  ${API_FIP}
  *.apps.${CLUSTER_NAME}.${BASE_DOMAIN}. IN  A ${INGRESS_FIP}
"
