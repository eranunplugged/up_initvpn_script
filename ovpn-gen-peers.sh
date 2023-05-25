#!/bin/bash
set -e
env
cat << EOF | sudo tee /etc/systemd/system/docker-openvpn@.service
#
[Unit]
Description=OpenVPN Docker Container
Documentation=https://github.com/kylemanna/docker-openvpn
After=network.target docker.service
Requires=docker.service
[Service]
RestartSec=10
Restart=always
Environment="NAME=ovpn"
Environment="DATA_VOL=ovpn-data"
Environment="IMG=ovpn:latest"
Environment="PORT=443:443/tcp"
ExecStartPre=/bin/sh -c 'test -z "\$IP6_PREFIX" && exit 0; sysctl net.ipv6.conf.all.forwarding=1'
ExecStart=/usr/bin/docker start -a \$NAME
ExecStartPost=/bin/sh -c 'test -z "\${IP6_PREFIX}" && exit 0; sleep 1; ip route replace \${IP6_PREFIX} via \$(docker inspect -f "{{ .NetworkSettings.GlobalIPv6Address }}" \$NAME ) dev docker0'
ExecStop=/usr/bin/docker stop -f \$NAME
ExecStopPost=/bin/sh -c 'test -z "\$IP6_PREFIX" && exit 0; ip route del \$IP6_PREFIX dev docker0'
[Install]
WantedBy=multi-user.target
EOF

docker run -v ${OVPN_DATA}:/etc/openvpn --log-driver=none --rm -i -e DEBUG=1 protectvpn/ovpn:${OVPN_IMAGE_VERSION} ovpn_genclientcert "user" nopass $NUM_USERS
docker stop ovpn
systemctl enable --now docker-openvpn@ovpn.service


rabbitmq_host=$RABBIT_HOST
rabbitmq_port=$RABBIT_PORT
rabbitmq_user=$RABBIT_DATABASE_USERNAME
rabbitmq_password=$RABBIT_DATABASE_PASSWORD
rabbitmq_exchange="exchange_vpn"
rabbitmq_routing_key="routingkey"
json_payload='{"protocol": "OPENVPN"}'
rabbit_data=""
counter=0
mkdir -p /tmp/configs
cd /tmp/configs
for i in $(seq 1 ${NUM_USERS}); do
  echo -n "Creating user${i}"
  docker run -v ${OVPN_DATA}:/etc/openvpn --rm protectvpn/ovpn:${OVPN_IMAGE_VERSION} ovpn_getclient user${i} > user${i}.ovpn;
  echo "    Done"
done
for file in *.ovpn; do
    if [[ -f $file ]]; then
        value=$(base64 -w 0 "$file")
        json_payload="{\"protocol\":\"OPENVPN\",\"ip\":\"${PUBLIC_IP}\",\"vpnConfiguration\":\"${value}\",\"available\":\"true\",\"ami\":\"${INSTANCE_ID}\",\"region\":\"${INSTANCE_REGION}\"}"
        if [ "${rabbit_data}" == "" ]; then
          rabbit_data=${json_payload}
        else
          rabbit_data="${rabbit_data},${json_payload}"
        fi
        counter=$((counter + 1))

        # Send rabbit_data in batches of 10
        if [ $counter -eq 10 ]; then
            amqp-publish -u "amqp://${rabbitmq_user}:${rabbitmq_password}@${rabbitmq_host}:${rabbitmq_port}" -e "$rabbitmq_exchange" -r "$rabbitmq_routing_key" -p -b "[$rabbit_data]"
            [ $? -eq 0 ] && echo "Successfully sent another batch"
            rabbit_data=""
            counter=0
        fi
    fi
done
cd ${OLDPWD} || exit
rm -rf /tmp/configs