#!/bin/bash
# <UDF name="UP_VAULT_ADDR" label="" />
# <UDF name="VAULT_ADDR" label="" />
# <UDF name="VAULT_TOKEN" label=""  />
# <UDF name="ENVIRONMENT" label=""  />
# <UDF name="INSTANCE_REGION" label=""  />


set -x
# Will be replaced by vault
export OVPN_IMAGE_VERSION=latest
export INSTANCE_CLOUD="LINODE"

curl -o functions.sh https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/main/functions.sh
curl -o ovpn-gen-peers.sh https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/main/ovpn-gen-peers.sh
chmod 777 ovpn-gen-peers.sh

. ./functions.sh

install_up_ssh_certificate
install_docker
install_vault
apt install -y software-properties-common unzip jq amqp-tools default-jre sysstat awscli gpg wireguard-dkms wireguard-tools qrencode apt-transport-https ca-certificates curl software-properties-common dnsutils


if [ "$INSTANCE_CLOUD" == "AWS" ]; then
  INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
fi
if [ "$INSTANCE_CLOUD" == "DIGITAL_OCEAN" ]; then
  INSTANCE_ID=$(curl http://169.254.169.254/metadata/v1/id)
fi
if [ ! -z $LINODE_ID ]; then
  INSTANCE_ID=$LINODE_ID
fi

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
#####################################
if [ ! -z $ES_ENABLED ]; then
  curl -L -O https://artifacts.elastic.co/downloads/beats/elastic-agent/$ES_PREFIX.tar.gz
  tar xzvf $ES_PREFIX.tar.gz
  cd "$ES_PREFIX" || exit
  ./elastic-agent install --url=$ES_CLOUD_URL --enrollment-token=$ES_ENROLLMENT_TOKEN
fi



#######INSTALL OPENVPN################

export OVPN_DATA="ovpn-data"
export PUBLIC_IP=$(dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | grep -oP '(?<=").*(?=")')
docker volume create --name $OVPN_DATA
docker run -v $OVPN_DATA:/etc/openvpn --log-driver=none --rm protectvpn/ovpn:${OVPN_IMAGE_VERSION} ovpn_genconfig -u tcp://${PUBLIC_IP}:443
sed -i 's/1194/443/i' /var/lib/docker/volumes/${OVPN_DATA}/_data/openvpn.conf
docker run -v $OVPN_DATA:/etc/openvpn -d -p 443:443/tcp --cap-add=NET_ADMIN --name ovpn protectvpn/ovpn:${OVPN_IMAGE_VERSION}
docker run -v $OVPN_DATA:/etc/openvpn --log-driver=none --rm -i -e DEBUG=1 --env OVPN_CN="${PUBLIC_IP}" --env EASYRSA_BATCH=1 protectvpn/ovpn:${OVPN_IMAGE_VERSION} ovpn_initpki nopass
ls -la /var/lib/docker/volumes/$OVPN_DATA/_data


./ovpn-gen-peers.sh >/tmp/ovpn-gen.log 2>&1 &

########Create rabbitmq stats sender########

wget -O /root/send_to_rabbitmq_template.sh https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/main/send_to_rabbitmq_template.sh

sed -e "s/%%RABBIT_HOST%%/$RABBIT_HOST/" \
    -e "s/%%RABBIT_PORT%%/$RABBIT_PORT/" \
    -e "s/%%RABBIT_DATABASE_USERNAME%%/$RABBIT_DATABASE_USERNAME/" \
    -e "s/%%RABBIT_DATABASE_PASSWORD%%/$RABBIT_DATABASE_PASSWORD/" \
    -e "s/%%INSTANCE_ID%%/$INSTANCE_ID/" \
    -e "s/%%PUBLIC_IP%%/$PUBLIC_IP/" \
    -e "s/%%INSTANCE_REGION%%/$INSTANCE_REGION/" \
    /root/send_to_rabbitmq_template.sh > /root/send_to_rabbitmq.sh

chmod +x /root/send_to_rabbitmq.sh

# Set the user, group, and script path
user="root"
group="root"
script_path="/root/send_to_rabbitmq.sh"

# Create the send_to_rabbitmq.service file
bash -c "cat << EOF > /etc/systemd/system/send_to_rabbitmq.service
[Unit]
Description=Send server info to RabbitMQ

[Service]
Type=oneshot
User=$user
Group=$group
ExecStart=$script_path
EOF"

# Create the send_to_rabbitmq.timer file
bash -c "cat << EOF > /etc/systemd/system/send_to_rabbitmq.timer
[Unit]
Description=Send server info to RabbitMQ every minute

[Timer]
OnCalendar=*-*-* *:0/1:00
Unit=send_to_rabbitmq.service

[Install]
WantedBy=timers.target
EOF"

# Reload the systemd configuration, start the timer, and enable it to run at boot
systemctl daemon-reload
systemctl enable --now send_to_rabbitmq.timer

# Check the status of the timer
systemctl status send_to_rabbitmq.timer


cd /etc/wireguard

umask 077


export ENDPOINT=$(dig +short myip.opendns.com @resolver1.opendns.com)

export SERVER_IP="10.0.0.1"


export WAN_INTERFACE_NAME=$(ip r | grep default | awk {'print $5'})
# Update package list and install required dependencies
apt-get update
apt-get install -y apt-transport-https ca-certificates curl software-properties-common

# Install Docker Compose
curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Create Docker Compose configuration
mkdir -p ~/wireguard-docker
cat << EOF > ~/wireguard-docker/docker-compose.yml
version: "2.1"
services:
  wireguard:
    image: lscr.io/linuxserver/wireguard:latest
    container_name: wireguard
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Etc/UTC
      - SERVERURL=$ENDPOINT
      - SERVERPORT=51820
      - PEERS=$NUM_USERS
      - PEERDNS=1.1.1.1
      - INTERNAL_SUBNET=$SERVER_IP
      - ALLOWEDIPS=0.0.0.0/0
      - PERSISTENTKEEPALIVE_PEERS=all
      - LOG_CONFS=true
    volumes:
      - /etc/wireguard/config:/config
      - /lib/modules:/lib/modules
    ports:
      - 51820:51820/udp
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    restart: unless-stopped
EOF

# Run Docker Compose
cd ~/wireguard-docker
docker-compose up -d

# Initialize JSON payload with typeVpn key-value pair
rabbitmq_host=$RABBIT_HOST
rabbitmq_port=$RABBIT_PORT
rabbitmq_user=$RABBIT_DATABASE_USERNAME
rabbitmq_password=$RABBIT_DATABASE_PASSWORD
rabbitmq_exchange="exchange_vpn"
rabbitmq_routing_key="routingkey"


# Wait for all the files to be generated
files_generated=0
while [ $files_generated -lt $NUM_USERS ]; do
    files_generated=0
    for i in $(seq 1 $NUM_USERS); do
        client_conf="/etc/wireguard/config/peer${i}/peer${i}.conf"
        if [[ -e "$client_conf" ]]; then
            files_generated=$((files_generated + 1))
        fi
    done
    sleep 1
done

# Initialize an empty array for storing JSON objects
json_payload='{"typeVpn": "wg"}'

# Iterate through all configuration files
rabbit_data=""
counter=0
for i in $(seq 1 $NUM_USERS); do
    client_conf="/etc/wireguard/config/peer${i}/peer${i}.conf"
    echo "Checking file: $client_conf" # Debug output
    if [[ -e "$client_conf" ]]; then
        echo "PersistentKeepalive=25" >> "$client_conf"
        echo "File exists: $client_conf" # Debug output
        # Read the contents of the client configuration file and encode it in Base64
        value=$(base64 -w 0 < "$client_conf")
        json_payload="{\"typeVpn\":\"wg\",\"ip\":\"${PUBLIC_IP}\",\"vpnConfiguration\":\"${value}\",\"available\":\"true\",\"ami\":\"${INSTANCE_ID}\",\"region\":\"${INSTANCE_REGION}\"}"
        if [ "${rabbit_data}" == "" ]; then
            rabbit_data=${json_payload}
        else
            rabbit_data="${rabbit_data},${json_payload}"
        fi
        counter=$((counter + 1))

        # Send rabbit_data in batches of 10
        if [ $counter -eq 10 ]; then
            amqp-publish -u "amqp://${rabbitmq_user}:${rabbitmq_password}@${rabbitmq_host}:${rabbitmq_port}" -e "$rabbitmq_exchange" -r "$rabbitmq_routing_key" -p -b "[$rabbit_data]"
            rabbit_data=""
            counter=0
        fi
    else
        echo "File not found: $client_conf" # Debug output
    fi
done


# Check if the command was successful
if [ $? -eq 0 ]; then
    echo "Data successfully sent to RabbitMQ"
else
    echo "Failed to send data to RabbitMQ"
    exit 1
fi