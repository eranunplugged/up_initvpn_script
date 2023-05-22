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

cat << EOF > /etc/systemd/system/xray.service
[Unit]
Description=XTLS Xray-Core a VMESS/VLESS Server
After=network.target nss-lookup.target
[Service]
# Change to your username <---
User=USERNAME
Group=USERNAME
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/opt/xray/xray run -config /opt/xray/config.json
Restart=on-failure
RestartPreventExitStatus=23
StandardOutput=journal
LimitNPROC=100000
LimitNOFILE=1000000
[Install]
WantedBy=multi-user.target
EOF
echo "============================================================================================"
env | sort
echo "============================================================================================"
mkdir /opt/xray
cd /opt/xray
sudo apt-get update
sudo apt-get install unzip
wget https://github.com/XTLS/Xray-core/releases/download/v1.8.1/Xray-linux-64.zip
unzip Xray-linux-64.zip
rm -f Xray-linux-64.zip
X25519=$(./xray x25519)
X_PRIVATE_KEY=$(echo "$X25519" | cut -d " " -f 3)
X_PUBLIC_KEY=$(echo "$X25519" | cut -d " " -f 5)
RABBIT_URL="amqp://${RABBIT_DATABASE_USERNAME}:${RABBIT_DATABASE_PASSWORD}@${RABBIT_HOST}:${RABBIT_PORT}"
echo "Rabbit url: ${RABBIT_URL}"
for i in $(seq 1 ${NUM_USERS}); do
  uuid=$(./xray uuid -i Secret)
  sid=$(openssl rand -hex 8)
  echo "sid: $sid, uuid: $uuid "
  if [ -z "$clients" ]; then
    clients="{\"id\": \"${uuid}\",\"flow\": \"xtls-rprx-vision\"}"
  else
        clients="$clients,{\"id\": \"${uuid}\",\"flow\": \"xtls-rprx-vision\"}"
  fi
  if [ -z "$sids" ]; then
    sids=$sid
  else
    sids="$sids,$sid"
  fi
  value=$(echo "vless://${uuid}@${PUBLIC_IP}:443?security=reality&encryption=none&pbk=${X_PUBLIC_KEY}&headerType=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=www.google-analytics.com&sid=$sid#" | base64 -w0)
  json_payload="{\"protocol\":\"REALITY\",\"ip\":\"${PUBLIC_IP}\",\"vpnConfiguration\":\"${value}\",\"available\":\"true\",\"ami\":\"${INSTANCE_ID}\",\"region\":\"${INSTANCE_REGION}\"}"

  echo "${json_payload}"
  if [ "${rabbit_data}" == "" ]; then
      rabbit_data=${json_payload}
  else
      rabbit_data="${rabbit_data},${json_payload}"
  fi
  counter=$((counter + 1))

  # Send rabbit_data in batches of 10
  if [ $counter -eq 10 ]; then
    echo "$i: sending"
    amqp-publish -u "${RABBIT_URL}" -e "exchange_vpn" -r "routingkey" -p -b "[$rabbit_data]"
    rabbit_data=""
    counter=0
  fi
done
# shellcheck disable=SC2086
SIDS=$(echo \"$sids\" | jq -c 'split(",")')
echo "SIDS: $SIDS"
# shellcheck disable=SC2086
curl -s -o config.json https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/reality_config.json
perl -i -pe "s/PRIVATE_KEY/$X_PRIVATE_KEY/i" config.json
perl -i -pe "s/SHORT_IDS/$SIDS/i" config.json
perl -i -pe "s/CLIENTS/$clients/i" config.json

cat config.json
systemctl daemon-reload && sudo systemctl enable --now xray

