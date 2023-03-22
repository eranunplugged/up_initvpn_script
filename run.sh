#!/bin/bash
# Install required packages
set -x
export VAULT_TOKEN=VAULT_TOKEN_PLACE_HOLDER
export VAULT_ADDR=VAULT_ADDRESS_PLACE_HOLDER
export ENVIRONMENT=ENVIRONMENT_PLACE_HOLDER
export INSTANCE_CLOUD=INSTACE_CLOUD_PLACE_HOLDER
export INSTANCE_REGION=REGION_PLACE_HOLDER

echo "# Installing ssh certificate"
sudo curl -s -o /etc/ssh/trusted-user-ca-keys.pem ${VAULT_ADDR}/v1/ssh-client-signer2/public_key
sudo echo "TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem" >> /etc/ssh/sshd_config
sudo systemctl restart sshd

sudo apt update -y
sudo apt install -y software-properties-common unzip jq amqp-tools default-jre sysstat awscli gpg wireguard-dkms wireguard-tools qrencode -y

# Download and install Vault CLI
export VAULT_VERSION="1.9.3" # Replace with the desired version
export ARCHITECTURE="amd64"

# Download Vault
curl -O -L "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${ARCHITECTURE}.zip"

# Unzip the Vault archive
unzip "vault_${VAULT_VERSION}_linux_${ARCHITECTURE}.zip"

# Move the binary to /usr/local/bin
sudo mv vault /usr/local/bin/

# Set the executable bit
sudo chmod +x /usr/local/bin/vault

# Remove the downloaded zip file
rm "vault_${VAULT_VERSION}_linux_${ARCHITECTURE}.zip"

# Verify the installation
vault --version




if [ "$INSTANCE_CLOUD" == "AWS" ]; then
  INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
fi
if [ "$INSTANCE_CLOUD" == "DIGITAL_OCEAN" ]; then
  INSTANCE_ID=$(curl http://169.254.169.254/metadata/v1/id)
fi

########For rabbitmq###########
# Set output file
OUTPUT_FILE="output.txt"

# Read AWS credentials from Vault and store them as environment variables
AWS_CREDS=$(vault read -format=json aws/creds/vpn_server | jq -r '.data | to_entries | map("\(.key)=\(.value)") | join(" ")')
echo "export $AWS_CREDS" > $OUTPUT_FILE

# Read VPN server configuration data from Vault and store them as environment variables
VPN_SERVER_CONFIG=$(vault read -format=json /kv/data/vpn-server/${ENVIRONMENT} | jq -r '.data.data | to_entries | map("\(.key)=\(.value)") | join(" ")')
echo "export $VPN_SERVER_CONFIG" >> $OUTPUT_FILE

# Source the output file to set environment variables
source $OUTPUT_FILE
#####################################
#######INSTALL OPENVPN################

sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common dnsutils
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose
sudo systemctl enable --now docker
export OVPN_DATA="ovpn-data"
export PUBLIC_IP=$(dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | grep -oP '(?<=").*(?=")')
sudo docker volume create --name $OVPN_DATA
sudo docker run -v $OVPN_DATA:/etc/openvpn --log-driver=none --rm protectvpn/ovpn ovpn_genconfig -u tcp://${PUBLIC_IP}:443
sudo sed -i 's/1194/443/i' /var/lib/docker/volumes/${OVPN_DATA}/_data/openvpn.conf
sudo docker run -v $OVPN_DATA:/etc/openvpn -d -p 443:443/tcp --cap-add=NET_ADMIN --name ovpn protectvpn/ovpn
ls -la /var/lib/docker/volumes/$OVPN_DATA/_data
sudo docker run -v $OVPN_DATA:/etc/openvpn --log-driver=none --rm -i -e DEBUG=1 --env OVPN_CN="${PUBLIC_IP}" --env EASYRSA_BATCH=1 protectvpn/ovpn ovpn_initpki nopass
ls -la /var/lib/docker/volumes/$OVPN_DATA/_data
export NUM_USERS=${QUANTITY_GENERATED_VPNS:-10}
sudo docker run -v $OVPN_DATA:/etc/openvpn --log-driver=none --rm -i -e DEBUG=1 protectvpn/ovpn ovpn_genclientcert "user" nopass $NUM_USERS
for i in $(seq 1 $NUM_USERS); do
  sudo docker run -v $OVPN_DATA:/etc/openvpn --log-driver=none --rm -e DEBUG=1 protectvpn/ovpn ovpn_getclient "user$i" > "user$i.ovpn"
done
sudo docker stop ovpn
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
# Modify IP6_PREFIX to match network config
#Environment="IP6_PREFIX=2001:db8::/64"
#Environment="ARGS=--config openvpn.conf --server-ipv6 2001:db8::/64"
Environment="NAME=ovpn"
Environment="DATA_VOL=ovpn-data"
Environment="IMG=ovpn:latest"
Environment="PORT=443:443/tcp"
# To override environment variables, use local configuration directory:
# /etc/systemd/system/docker-openvpn@foo.d/local.conf
# http://www.freedesktop.org/software/systemd/man/systemd.unit.html
# IPv6: Ensure forwarding is enabled on host's networking stack (hacky)
# Would be nice to use systemd-network on the host, but this doesn't work
# http://lists.freedesktop.org/archives/systemd-devel/2015-June/032762.html
ExecStartPre=/bin/sh -c 'test -z "\$IP6_PREFIX" && exit 0; sysctl net.ipv6.conf.all.forwarding=1'
# Main process
# ExecStart=/usr/bin/docker run --rm --cap-add=NET_ADMIN -v \${DATA_VOL}:/etc/openvpn --name \${NAME} -p \${PORT} \${IMG} ovpn_run \$ARGS
ExecStart=/usr/bin/docker start -a \$NAME
# IPv6: Add static route for IPv6 after it starts up
ExecStartPost=/bin/sh -c 'test -z "\${IP6_PREFIX}" && exit 0; sleep 1; ip route replace \${IP6_PREFIX} via \$(docker inspect -f "{{ .NetworkSettings.GlobalIPv6Address }}" \$NAME ) dev docker0'
ExecStop=/usr/bin/docker stop -f \$NAME
# IPv6: Clean-up
ExecStopPost=/bin/sh -c 'test -z "\$IP6_PREFIX" && exit 0; ip route del \$IP6_PREFIX dev docker0'
[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now docker-openvpn@ovpn.service

########Create rabbitmq stats sender########

echo '#!/bin/bash

# Configuration
rabbitmq_host="${RABBIT_HOST}"
rabbitmq_port="${RABBIT_PORT}"
rabbitmq_user="${RABBIT_DATABASE_USERNAME}"
rabbitmq_password="${RABBIT_DATABASE_PASSWORD}"
rabbitmq_exchange="exchange_vpn"
rabbitmq_routing_key="routingkey"
ami="${INSTANCE_ID}"

# Time
time=$(date +"%Y-%m-%d %H:%M:%S")

# IP (retrieve the primary public IP of the instance)
public_ip="${PUBLIC_IP}"

# CPU usage (averaged over 1 minute)
cpu=$(awk -v a="$(awk '/cpu /{print $2,$4,$6}' /proc/stat; sleep 1)" '/cpu /{print 100-($2+$4+$6-a)}' /proc/stat)

# Server status (true if the server is up, false otherwise)
serverStatusUP=true

# Point (latitude and longitude)
location_data=$(curl -s "http://ip-api.com/json/$public_ip")
latitude=$(echo "\$location_data" | jq -r '.lat')
longitude=$(echo "\$location_data" | jq -r '.lon')
point="\$latitude,\$longitude"

# Create JSON payload
payload=$(jq -n --arg time "\$time" \
               --arg ami "\$ami" \
               --arg ip "\$public_ip" \
               --arg cpu "\$cpu" \
               --arg serverStatusUP "\$serverStatusUP" \
               --arg region "\${INSTANCE_REGION}" \
               --arg point "\$point" \
               '{time: $time, ip: $ip, cpu: $cpu, serverStatusUP: $serverStatusUP, region: $region, point: $point}')

# Send data to RabbitMQ
echo "Sending data to RabbitMQ: \$payload"
amqp-publish -u "amqp://\${rabbitmq_user}:\${rabbitmq_password}@\${rabbitmq_host}:\${rabbitmq_port}" -e "\$rabbitmq_exchange" -r "\$rabbitmq_routing_key" -p -b "\$payload"' > /root/send_to_rabbitmq_template.sh


chmod +x /root/send_to_rabbitmq_template.sh


envsubst < /root/send_to_rabbitmq_template.sh > /root/send_to_rabbitmq.sh
chmod +x /root/send_to_rabbitmq.sh
# Create the send_to_rabbitmq.service file
sudo bash -c "cat << EOF > /etc/systemd/system/send_to_rabbitmq.service
[Unit]
Description=Send server info to RabbitMQ

[Service]
Type=oneshot
User="root"
Group="root"
ExecStart="/root/send_to_rabbitmq.sh"
EOF"

# Create the send_to_rabbitmq.timer file
sudo bash -c "cat << EOF > /etc/systemd/system/send_to_rabbitmq.timer
[Unit]
Description=Send server info to RabbitMQ every minute

[Timer]
OnCalendar=*-*-* *:0/1:00
Unit=send_to_rabbitmq.service

[Install]
WantedBy=timers.target
EOF"

# Reload the systemd configuration, start the timer, and enable it to run at boot
sudo systemctl daemon-reload
sudo systemctl start send_to_rabbitmq.timer
sudo systemctl enable send_to_rabbitmq.timer

# Check the status of the timer
sudo systemctl status send_to_rabbitmq.timer


##########VPN USER DATA ON TIME to RABBIT
# Initialize JSON payload with typeVpn key-value pair
rabbitmq_host=$RABBIT_HOST
rabbitmq_port=$RABBIT_PORT
rabbitmq_user=$RABBIT_DATABASE_USERNAME
rabbitmq_password=$RABBIT_DATABASE_PASSWORD
rabbitmq_exchange="exchange_vpn"
rabbitmq_routing_key="routingkey"

json_payload='{"typeVpn": "ov"}'

# Iterate through all .ovpn files in the current directory
rabbit_data=""
for file in *.ovpn; do
    if [[ -f $file ]]; then
        value=$(base64 -w 0 "$file")
        json_payload="{\"typeVpn\":\"ov\",\"ip\":\"${PUBLIC_IP}\",\"vpnConfiguration\":\"${value}\",\"available\":\"true\",\"ami\":\"${INSTANCE_ID}\",\"region\":\"${INSTANCE_REGION}\"}"
        if [ "${rabbit_data}" == "" ]; then
          rabbit_data=${json_payload}
        else
          rabbit_data="${rabbit_data},${json_payload}"
        fi
    fi

done
amqp-publish -u "amqp://${rabbitmq_user}:${rabbitmq_password}@${rabbitmq_host}:${rabbitmq_port}" -e "$rabbitmq_exchange" -r "$rabbitmq_routing_key" -p -b "[$rabbit_data]"

# Check if the command was successful
if [ $? -eq 0 ]; then
    echo "Data successfully sent to RabbitMQ"
else
    echo "Failed to send data to RabbitMQ"
    exit 1
fi
##########WIREGUARD INSTALLATION#################################

aws configure set aws_access_key_id "$access_key" && aws configure set aws_secret_access_key "$secret_key" && aws configure set region "eu-west-2" && aws configure set output "json"
aws s3 sync ${PATH_WG_AGENT_JARS} ${WG_ROOT}

chmod +x ${WG_ROOT}/*.sh

###############################################
NET_FORWARD="net.ipv4.ip_forward=1"
sysctl -w  ${NET_FORWARD}
sed -i "s:#${NET_FORWARD}:${NET_FORWARD}:" /etc/sysctl.conf

cd /etc/wireguard

umask 077

export SERVER_PRIVATE_KEY=$( wg genkey )
export SERVER_PUBLIC_KEY=$( echo $SERVER_PRIVATE_KEY| wg pubkey )

echo $SERVER_PUBLIC_KEY > ./server_public.key
echo $SERVER_PRIVATE_KEY > ./server_private.key


export ENDPOINT=$(dig +short myip.opendns.com @resolver1.opendns.com)

echo $ENDPOINT:51820 > ./endpoint.var

SERVER_IP="10.0.0.1"
echo $SERVER_IP | grep -o -E '([0-9]+\.){3}' > ./vpn_subnet.var

DNS="1.1.1.1"
echo $DNS > ./dns.var

echo 1 > ./last_used_ip.var
echo 1 > ./third_used_ip.var
echo 1 > ./second_used_ip.var
echo 1 > ./first_used_ip.var

WAN_INTERFACE_NAME=$(ip r | grep default | awk {'print $5'})

echo $WAN_INTERFACE_NAME > ./wan_interface_name.var

cat ./endpoint.var | sed -e "s/:/ /" | while read SERVER_EXTERNAL_IP SERVER_EXTERNAL_PORT
do
cat > ./wg0.conf.def << EOF
[Interface]
Address = $SERVER_IP
SaveConfig = false
PrivateKey = $SERVER_PRIVATE_KEY
ListenPort = $SERVER_EXTERNAL_PORT
PostUp   = iptables -A FORWARD -s 10.0.0.16/16 -d 10.0.0.0/16 -j DROP; iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $WAN_INTERFACE_NAME -j MASQUERADE;
PostDown = iptables -D FORWARD -s 10.0.0.16/16 -d 10.0.0.0/16 -j DROP; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $WAN_INTERFACE_NAME -j MASQUERADE;
EOF
done

cp -f ./wg0.conf.def ./wg0.conf

systemctl enable wg-quick@wg0

echo "10.0.1.1" > /etc/wireguard/last_ip.var
mkdir /etc/wireguard/clients
chmod -R 777 /etc/wireguard

####################Generate clients######################

# Set the number of clients to generate
num_clients=${QUANTITY_GENERATED_VPNS:-10}

# Set the WireGuard server settings
SERVER_ENDPOINT=${ENDPOINT}
SERVER_PORT=51820
DNS="1.1.1.1"


for i in $(seq 1 $num_clients); do
    # Generate client private and public keys
    CLIENT_PRIVATE_KEY=$(wg genkey)
    CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVATE_KEY" | wg pubkey)

    # Assign an IP address to the client
    CLIENT_IP="10.0.0.$((i + 1))/32"

    # Create the client configuration file
    CLIENT_CONFIG_FILE="/etc/wireguard/clients/client${i}.conf"
    sudo bash -c "cat > $CLIENT_CONFIG_FILE" << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address = $CLIENT_IP
DNS = $DNS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
Endpoint = $SERVER_ENDPOINT:$SERVER_PORT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
done

echo "Generated $num_clients client configurations in /etc/wireguard/clients"

echo "# Wireguard installed" > wg-install.log
# Initialize JSON payload with typeVpn key-value pair
rabbitmq_host=$RABBIT_HOST
rabbitmq_port=$RABBIT_PORT
rabbitmq_user=$RABBIT_DATABASE_USERNAME
rabbitmq_password=$RABBIT_DATABASE_PASSWORD
rabbitmq_exchange="exchange_vpn"
rabbitmq_routing_key="routingkey"

json_payload='{"typeVpn": "wg"}'

# Iterate through all .ovpn files in the current directory
rabbit_data=""
for client_conf in /etc/wireguard/clients/*.conf; do
    # Read the contents of the client configuration file
    value=$(base64 -w 0 "$client_conf")
    json_payload="{\"typeVpn\":\"wg\",\"ip\":\"${PUBLIC_IP}\",\"vpnConfiguration\":\"${value}\",\"available\":\"true\",\"ami\":\"${INSTANCE_ID}\",\"region\":\"${INSTANCE_REGION}\"}"
    if [ "${rabbit_data}" == "" ]; then
        rabbit_data=${json_payload}
    else
        rabbit_data="${rabbit_data},${json_payload}"
    fi
done

amqp-publish -u "amqp://${rabbitmq_user}:${rabbitmq_password}@${rabbitmq_host}:${rabbitmq_port}" -e "$rabbitmq_exchange" -r "$rabbitmq_routing_key" -p -b "[$rabbit_data]"

# Check if the command was successful
if [ $? -eq 0 ]; then
    echo "Data successfully sent to RabbitMQ"
else
    echo "Failed to send data to RabbitMQ"
    exit 1
fi