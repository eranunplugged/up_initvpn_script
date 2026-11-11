#!/bin/bash
# <UDF name="UP_VAULT_ADDR" label="" />
# <UDF name="VAULT_ADDR" label="" />
# <UDF name="VAULT_TOKEN" label=""  />
# <UDF name="ENVIRONMENT" label=""  />
# <UDF name="INSTANCE_REGION" label=""  />
# <UDF name="VPN_TYPES" label=""  />
# This scripts is executed first

# Disable password expiration for root user
passwd -u root
ROOT_PASSWD=$(date | md5sum | cut -c1-8)
echo "root:$ROOT_PASSWD" | chpasswd
chage -I -1 -m 0 -M 99999 -E -1 root

# Allow different environments to use different branches.
[ -z ${BRANCH} ] && export BRANCH=main

# Fetch the VPN server config from Vault FIRST, before any package work.
# vpn-admin hands us a VAULT_TOKEN with a ~5 minute TTL; the old flow only read
# Vault after install_docker / install_vault / install_base_packages, and on
# slow first boots (OCI: apt-daily at boot, 1-vCPU droplets) that took longer
# than the TTL, so the read failed and the node never registered. curl is in
# every base image, so no vault CLI or jq is needed here: store the raw JSON
# root-only and parse it later, once jq is installed. Done before `set -x` so
# the token header is never echoed into the cloud-init / StackScript log.
# The token header is fed to curl on stdin (-H @-) rather than as an argument,
# so it never shows up in `ps` either. --retry covers timeouts and 5xx (e.g. a
# sealed Vault) but deliberately not 403/404: an expired or wrong token should
# fail fast, not burn the remaining TTL.
VPN_SERVER_CONFIG_JSON=/root/vpn-server-config.json
if ! ( umask 077; printf 'X-Vault-Token: %s\n' "${VAULT_TOKEN}" | \
       curl -sS --fail --retry 5 --retry-delay 3 --retry-connrefused --max-time 20 \
         -H @- \
         -o "${VPN_SERVER_CONFIG_JSON}" \
         "${VAULT_ADDR}/v1/kv/data/vpn-server/${ENVIRONMENT}" ); then
  echo "FATAL: could not read kv/vpn-server/${ENVIRONMENT} from ${VAULT_ADDR} -- aborting"
  exit 1
fi
echo "Vault config fetched for environment ${ENVIRONMENT}"
set -x
# Will be replaced by vault
export OVPN_IMAGE_VERSION=latest

# Pick OS-specific helper family. 20.04 = empty suffix (legacy path, intact); 24.04 = -2404.
SCRIPT_SUFFIX=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  [ "${VERSION_ID}" = "24.04" ] && SCRIPT_SUFFIX="-2404"
fi
export SCRIPT_SUFFIX

#Main install script
curl -o functions.sh https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/functions${SCRIPT_SUFFIX}.sh
. ./functions.sh

[ -f /etc/ssh/trusted-user-ca-keys.pem ] || install_up_ssh_certificate
docker version || install_docker
vault version || install_vault
install_base_packages
# shellcheck disable=SC2155
export PUBLIC_IP=$(dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | grep -oP '(?<=").*(?=")')
if [ "$INSTANCE_CLOUD" == "AWS" ]; then
  # Canonical's Ubuntu AMIs carry ImdsSupport=v2.0, so instances launched from them
  # get HttpTokens=required and an unauthenticated IMDSv1 GET returns 401 -- leaving
  # INSTANCE_ID empty, the hostname blank, and the node registering itself against an
  # empty id (verified on stage sa-east-1, 2026-09-07). The old custom VPNSERVER_V7
  # AMI has no ImdsSupport attribute, so IMDSv1 was permitted and this never showed.
  # Ask for a token first; fall back to the plain call for images where v1 still works.
  IMDS_TOKEN=$(curl -s -f -X PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null || true)
  if [ -n "$IMDS_TOKEN" ]; then
    export INSTANCE_ID=$(curl -s -f -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
        http://169.254.169.254/latest/meta-data/instance-id)
  else
    export INSTANCE_ID=$(curl -s -f http://169.254.169.254/latest/meta-data/instance-id)
  fi
elif [ "$INSTANCE_CLOUD" == "DIGITAL_OCEAN" ]; then
  export INSTANCE_ID=$(curl http://169.254.169.254/metadata/v1/id)
  VPN_NAME=$(curl -s -f http://169.254.169.254/metadata/v1/hostname)
elif [ "$INSTANCE_CLOUD" == "LINODE" ]; then
    export INSTANCE_ID=$LINODE_ID
    LINODE_TOKEN=$(curl -s -f -X PUT -H "Metadata-Token-Expiry-Seconds: 300" http://169.254.169.254/v1/token)
    VPN_NAME=$(curl -s -f -H "Metadata-Token: $LINODE_TOKEN" http://169.254.169.254/v1/instance | sed -n 's/^label: //p')
elif [ "$INSTANCE_CLOUD" == "HETZNER" ]; then
    export INSTANCE_ID=$(curl http://169.254.169.254/hetzner/v1/metadata/instance-id)
    VPN_NAME=$(curl -s -f http://169.254.169.254/hetzner/v1/metadata/hostname)
elif [ "$INSTANCE_CLOUD" == "LIGHTNODE" ]; then
    export INSTANCE_ID=$(cat /etc/machine-id)
elif [ "$INSTANCE_CLOUD" == "ORACLE" ]; then
    export INSTANCE_ID=$(curl -s -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/id)
    VPN_NAME=$(curl -s -f -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/displayName)
fi

# Checked unconditionally: the old `elif [ -z "$INSTANCE_ID" ]` could only fire when no
# cloud branch matched at all, so an empty id from a branch that *did* match passed
# silently -- which is exactly how the IMDSv2 failure above went unnoticed.
if [ -z "$INSTANCE_ID" ]; then
  echo "MISSING INSTANCE_ID !!!!!!!!!!!!!! cloud=${INSTANCE_CLOUD}"
fi

# Before install_elastic: the agent takes host.name from it at enrolment.
CLOUD=${INSTANCE_CLOUD,,}
hostnamectl set-hostname "${VPN_NAME:-${INSTANCE_ID}}${CLOUD:+-${CLOUD//_/-}}"

# Set output file
OUTPUT_FILE="./output.txt"

# Turn the Vault config fetched at the top of this script into env vars
# (same jq expression as the old `vault read` pipeline; KV v2 nests under .data.data).
VPN_SERVER_CONFIG=$(jq -r '.data.data | to_entries | map("\(.key)=\(.value)") | join(" ")' "${VPN_SERVER_CONFIG_JSON}")
echo "$VPN_SERVER_CONFIG" > $OUTPUT_FILE

# Source the output file to set environment variables
set -a
. $OUTPUT_FILE
set +a
export NUM_USERS=${QUANTITY_GENERATED_VPNS:-10}
#####################################
docker login ghcr.io -u eranunplugged -p ${GTOKEN}
# Open 51820/udp and 443/tcp on the host firewall before any VPN software is
# installed. Needed on OCI, whose Ubuntu images REJECT everything but 22/tcp;
# a no-op on the other clouds. Runs after the Vault config is sourced so a
# non-default OVPN_PORT is covered too.
open_vpn_firewall_ports
install_elastic
install_openvpn
install_wireguard
install_reality
install_rabitmq_sender


