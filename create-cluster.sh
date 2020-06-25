#!/usr/bin/env bash
set -e
set -x

API_FIP="10.0.110.87"
INGRESS_FIP="10.0.111.125"
CLUSTER_NAME="dzipi"

# 4 VCPU, 8GB RAM
MASTER_COUNT=3
export OPENSTACK_FLAVOR=ci.m4.xlarge
# 4 VCPU, 16GB RAM
WORKER_COUNT=1
export OPENSTACK_WORKER_FLAVOR=ci.w1.large
export OPENSTACK_EXTERNAL_NETWORK=provider_net_shared_3
CLUSTER_OS_IMAGE=rhcos-4.4.3
export PULL_SECRET=$(cat zallen-auth.json      | tr -d '\t\r\n ')
export SSH_PUB_KEY=$(cat $HOME/.ssh/id_rsa.pub | tr -d '\r\n')
export BASE_DOMAIN=patternfly.org

create_install_config () {
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
    trunkSupport:     "0"
publish: External
pullSecret: '${PULL_SECRET}'
sshKey: ${SSH_PUB_KEY}
EOF
}

create_hosts() {
  start_comment="# Generated for $CLUSTER_NAME"
  end_comment="# End of $CLUSTER_NAME"
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
    sudo sed -i "${regex}d" /etc/hosts
    echo "$hosts" | sudo tee -a /etc/hosts
  fi
}

create_install_config
create_hosts

openshift-install create cluster

# Attach the ingress port
# openstack floating ip set --port $INGRESS_PORT $INGRESS_FIP
