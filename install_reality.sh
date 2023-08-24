#!/bin/bash

cat << EOF >> /etc/sysctl.conf
net.ipv4.tcp_keepalive_time = 90
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fastopen = 3
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.file-max = 65535000
EOF

cat << EOF >> /etc/security/limits.conf
root soft     nproc          655350
root hard     nproc          655350
root soft     nofile         655350
root hard     nofile         655350
EOF

sysctl -p
curl -o /etc/systemd/system/xray.service https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/services/reality/xray.service
curl -o /etc/systemd/system/realstats.service https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/services/reality/realstats.service
curl -o /etc/systemd/system/realstats.timer https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/services/reality/realstats.timer
curl -o /usr/local/bin/reality_stats.sh https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/services/reality/reality_stats.sh
chmod 755 /usr/local/bin/reality_stats.sh

echo "============================================================================================"
env | sort
echo "============================================================================================"

mkdir /opt/xray
cd /opt/xray
sudo apt-get update -o DPkg::Lock::Timeout=-1
sudo apt-get install -o DPkg::Lock::Timeout=-1 unzip
wget https://github.com/XTLS/Xray-core/releases/download/v1.8.1/Xray-linux-64.zip
unzip Xray-linux-64.zip
rm -f Xray-linux-64.zip
if [ -z "$REALITY_EXTERNAL_HOST" ]; then
  export REALITY_EXTERNAL_HOST="www.google-analytics.com"
fi
if [ -z "$REALITY_EXTERNAL_PORT" ]; then
  export REALITY_EXTERNAL_PORT=443
fi
if [ -z "$REALITY_LISTEN_PORT" ]; then
  export REALITY_LISTEN_PORT="443"
fi
X25519=$(./xray x25519)
echo "X25519:"
echo "$X25519"
X_PRIVATE_KEY=$(echo "$X25519" | head -1 | cut -d " " -f 3)
echo "X_PRIVATE_KEY: $X_PRIVATE_KEY"
X_PUBLIC_KEY=$(echo "$X25519" | tail -1 | cut -d " " -f 3)
RABBIT_URL="amqp://${RABBIT_DATABASE_USERNAME}:${RABBIT_DATABASE_PASSWORD}@${RABBIT_HOST}:${RABBIT_PORT}"
echo "Rabbit url: ${RABBIT_URL}"
uuid=$(./xray uuid -i Secret)
clients="{\"id\": \"${uuid}\",\"flow\": \"xtls-rprx-vision\"}"
for i in $(seq 1 ${NUM_USERS}); do
  sid=$(openssl rand -hex 8)
  if [ -z "$sids" ]; then
    sids=$sid
  else
    sids="$sids,$sid"
  fi
  value=$(echo "vless://${uuid}@${PUBLIC_IP}:${REALITY_LISTEN_PORT}?security=reality&encryption=none&pbk=${X_PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=${REALITY_EXTERNAL_HOST}&sid=$sid#" | base64 -w0)
  json_payload="{\"protocol\":\"REALITY\",\"ip\":\"${PUBLIC_IP}\",\"vpnConfiguration\":\"${value}\",\"available\":\"true\",\"ami\":\"${INSTANCE_ID}\",\"region\":\"${INSTANCE_REGION}\"}"

  if [ "${rabbit_data}" == "" ]; then
      rabbit_data=${json_payload}
  else
      rabbit_data="${rabbit_data},${json_payload}"
  fi
  counter=$((counter + 1))

  # Send rabbit_data in batches of 10
  if [ $counter -eq 10 ]; then
    echo "$i: sending"
    amqp-publish -u "${RABBIT_URL}"  -r "vpn" -p -b "[$rabbit_data]"
    rabbit_data=""
    counter=0
  fi
done
# shellcheck disable=SC2086
SIDS=$(echo \"$sids\" | jq -c 'split(",")')
echo "SIDS: $SIDS"
# shellcheck disable=SC2086
curl -s -o config.json https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/reality_config.json
perl -i -pe "s/REALITY_PRIVATE_KEY/$X_PRIVATE_KEY/i" config.json
perl -i -pe "s/REALITY_SHORT_IDS/$SIDS/i" config.json
perl -i -pe "s/REALITY_CLIENTS/$clients/i" config.json
perl -i -pe "s/REALITY_EXTERNAL_HOST/$REALITY_EXTERNAL_HOST/i" config.json
perl -i -pe "s/REALITY_EXTERNAL_PORT/$REALITY_EXTERNAL_PORT/i" config.json
perl -i -pe "s/REALITY_LISTEN_PORT/$REALITY_LISTEN_PORT/i" config.json

cat config.json
systemctl daemon-reload
systemctl enable --now xray realstats.timer

