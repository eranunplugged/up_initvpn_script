#!/bin/bash
# <UDF name="UP_VAULT_ADDR" label="" />
# <UDF name="VAULT_ADDR" label="" />
# <UDF name="VAULT_TOKEN" label=""  />
# <UDF name="ENVIRONMENT" label=""  />
# <UDF name="INSTANCE_REGION" label=""  />
# <UDF name="VPN_TYPES" label=""  />
# This scripts is executed first

# Allow different environments to use different branches.
[ -z ${BRANCH} ] && export BRANCH=main
set -x
# Will be replaced by vault
export OVPN_IMAGE_VERSION=latest
#Main install script
curl -o functions.sh https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/functions.sh
. ./functions.sh

install_up_ssh_certificate
install_docker
install_vault
apt install -y software-properties-common unzip jq amqp-tools default-jre sysstat awscli gpg wireguard-dkms wireguard-tools qrencode apt-transport-https ca-certificates curl software-properties-common dnsutils

if [ "$INSTANCE_CLOUD" == "AWS" ]; then
  export INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
elif [ "$INSTANCE_CLOUD" == "DIGITAL_OCEAN" ]; then
  export INSTANCE_ID=$(curl http://169.254.169.254/metadata/v1/id)
  chage -I -1 -m 0 -M 99999 -E -1 root
elif [ ! -z $LINODE_ID ]; then
  export INSTANCE_ID=$LINODE_ID
fi

hostnamectl set-hostname ${INSTANCE_CLOUD}-${INSTANCE_REGION}-${INSTANCE_ID}

# Set output file
OUTPUT_FILE="./output.txt"

# Read AWS credentials from Vault and store them as environment variables
AWS_CREDS=$(vault read -format=json aws/creds/vpn_server | jq -r '.data | to_entries | map("\(.key)=\(.value)") | join(" ")')
echo "$AWS_CREDS" > $OUTPUT_FILE

# Read VPN server configuration data from Vault and store them as environment variables
# shellcheck disable=SC2086
VPN_SERVER_CONFIG=$(vault read -format=json /kv/data/vpn-server/${ENVIRONMENT} | jq -r '.data.data | to_entries | map("\(.key)=\(.value)") | join(" ")')
echo "$VPN_SERVER_CONFIG" >> $OUTPUT_FILE

# Source the output file to set environment variables
set -a
. $OUTPUT_FILE
set +a
export NUM_USERS=${QUANTITY_GENERATED_VPNS:-10}
#####################################
install_elastic

install_wireguard



