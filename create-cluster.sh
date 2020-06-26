#!/usr/bin/env bash
set -e

: "${CLUSTER_NAME:?Need to set CLUSTER_NAME non-empty}"

# Somewhere you can create A* DNS entries (default patternfly.org)
export BASE_DOMAIN=${BASE_DOMAIN:-patternfly.org}

# 4 VCPU, 8GB RAM
MASTER_COUNT=3
export OPENSTACK_FLAVOR=ci.w1.large
# 4 VCPU, 8GB RAM
WORKER_COUNT=1
export OPENSTACK_WORKER_FLAVOR=ci.w1.large
export OPENSTACK_EXTERNAL_NETWORK=provider_net_shared_3
CLUSTER_OS_IMAGE=rhcos-4.4.3
export PULL_SECRET=$(cat pull-secret.txt)
# In case you have to ssh in and debug
export SSH_PUB_KEY=$(cat $HOME/.ssh/id_rsa.pub)

getFIP() {
  local _description="${CLUSTER_NAME} $1"

  local _fip=$(openstack float ip list --long -c "Floating IP Address" -c Description -f value | grep "$_description" | awk 'NR==1 {print $1}')

  if [ -z "$_fip" ]; then
    _fip=$(openstack floating ip create --description "$_description" provider_net_shared_3 | awk '{print $4}')
  fi

  echo "$_fip"
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
      type: ${OPENSTACK_WORKER_FLAVOR}
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
  - cidr: 172.18.0.0/16
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.19.0.0/16
platform:
  openstack:
    cloud: openstack
    externalNetwork:  ${OPENSTACK_EXTERNAL_NETWORK}
    clusterOSImage:   ${CLUSTER_OS_IMAGE}
    computeFlavor:    ${OPENSTACK_FLAVOR}
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
