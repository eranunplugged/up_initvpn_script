#!/bin/bash
{
export VAULT_TOKEN=
export VAULT_ADDR=https://vault-dev.unpluggedsystems.app
export UP_VAULT_ADDR=https://vault-dev.unpluggedsystems.app
export ENVIRONMENT=stage
export INSTANCE_CLOUD=OTHER
export INSTANCE_REGION=eu-central
export VPN_TYPES=WIREGUARD,REALITY
export BRANCH=DVO-54
export REALITY_EXTERNAL_HOST=www.googleanalytics.com
export REALITY_EXTERNAL_PORT=443
export INSTANCE_ID=hetzner_helsinki
env

curl -o init.sh https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/init-vpn-linode.sh
chmod 777 init.sh
./init.sh
} > /var/log/unplugged-vpn-script.log 2>&1 &