#!/bin/bash
# Install required packages
set -x
export VAULT_TOKEN=VAULT_TOKEN_PLACE_HOLDER
export VAULT_ADDR=VAULT_ADDRESS_PLACE_HOLDER
export UP_VAULT_ADDR=UP_VAULT_ADDRESS_PLACE_HOLDER
export ENVIRONMENT=ENVIRONMENT_PLACE_HOLDER
export INSTANCE_CLOUD=INSTACE_CLOUD_PLACE_HOLDER
export INSTANCE_REGION=REGION_PLACE_HOLDER

echo "# Installing ssh certificate"
curl -s -o /etc/ssh/trusted-user-ca-keys.pem ${UP_VAULT_ADDR}/v1/ssh-client-signer2/public_key
echo "TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem" >> /etc/ssh/sshd_config
systemctl restart sshd

apt update -o DPkg::Lock::Timeout=-1 -y
apt install -o DPkg::Lock::Timeout=-1 -y software-properties-common unzip jq amqp-tools default-jre sysstat awscli gpg wireguard-dkms wireguard-tools qrencode -y

# Download and install Vault CLI
export VAULT_VERSION="1.9.3" # Replace with the desired version
export ARCHITECTURE="amd64"

# Download Vault
curl -O -L "https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_linux_${ARCHITECTURE}.zip"

# Unzip the Vault archive
unzip "vault_${VAULT_VERSION}_linux_${ARCHITECTURE}.zip"

# Move the binary to /usr/local/bin
mv vault /usr/local/bin/

# Set the executable bit
chmod +x /usr/local/bin/vault

# Remove the downloaded zip file
rm "vault_${VAULT_VERSION}_linux_${ARCHITECTURE}.zip"

# Verify the installation
vault --version




if [ "$INSTANCE_CLOUD" == "AWS" ]; then
  INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
fi
if [ "$INSTANCE_CLOUD" == "DIGITAL_OCEAN" ]; then
  INSTANCE_ID=$(curl http://169.254.169.254/metadata/v1/id)
  chage -I -1 -m 0 -M 99999 -E -1 root
fi
if [ "$INSTANCE_CLOUD" == "LINODE" ]; then
  INSTANCE_ID=$(curl http://169.254.169.254/v1/json/linode/id)
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
ES_CONFIG=$(vault kv get -format=json up-secrets/tmp_protectvpn_es | jq -r '.data.data | to_entries | map("\(.key)=\(.value)") | join("\n")')                                         ─╯
echo $ES_CONFIG 
if [ "$ES_ENABLED" == "true" ]; then
  curl -L -O https://artifacts.elastic.co/downloads/beats/elastic-agent/$ES_PREFIX.tar.gz 
  tar xzvf $ES_PREFIX.tar.gz 
  cd $ES_PREFIX
  ./elastic-agent install --url=YYY --enrollment-token=$ES_ENROLLMENT_TOKEN
fi


#######INSTALL OPENVPN################

apt-get update -o DPkg::Lock::Timeout=-1
apt-get install -o DPkg::Lock::Timeout=-1 -y apt-transport-https ca-certificates curl software-properties-common dnsutils
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get -o DPkg::Lock::Timeout=-1 update
apt-get install -o DPkg::Lock::Timeout=-1 -y docker-ce docker-ce-cli containerd.io docker-compose
systemctl enable --now docker
export OVPN_DATA="ovpn-data"
export PUBLIC_IP=$(dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | grep -oP '(?<=").*(?=")')
docker volume create --name $OVPN_DATA
docker run -v $OVPN_DATA:/etc/openvpn --log-driver=none --rm ghcr.io/eranunplugged/up_openvpn_xor ovpn_genconfig -u tcp://${PUBLIC_IP}:443
sed -i 's/1194/443/i' /var/lib/docker/volumes/${OVPN_DATA}/_data/openvpn.conf
docker run -v $OVPN_DATA:/etc/openvpn -d -p 443:443/tcp --cap-add=NET_ADMIN --name ovpn ghcr.io/eranunplugged/up_openvpn_xor
ls -la /var/lib/docker/volumes/$OVPN_DATA/_data
docker run -v $OVPN_DATA:/etc/openvpn --log-driver=none --rm -i -e DEBUG=1 --env OVPN_CN="${PUBLIC_IP}" --env EASYRSA_BATCH=1 ghcr.io/eranunplugged/up_openvpn_xor ovpn_initpki nopass
ls -la /var/lib/docker/volumes/$OVPN_DATA/_data
export NUM_USERS=${QUANTITY_GENERATED_VPNS:-10}
docker run -v $OVPN_DATA:/etc/openvpn --log-driver=none --rm -i -e DEBUG=1 ghcr.io/eranunplugged/up_openvpn_xor ovpn_genclientcert "user" nopass $NUM_USERS
for i in $(seq 1 $NUM_USERS); do
  docker run -v $OVPN_DATA:/etc/openvpn --log-driver=none --rm -e DEBUG=1 ghcr.io/eranunplugged/up_openvpn_xor ovpn_getclient "user$i" > "user$i.ovpn"
done
docker stop ovpn
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


##########VPN USER DATA ON TIME to RABBIT
# Initialize JSON payload with typeVpn key-value pair
rabbitmq_host=$RABBIT_HOST
rabbitmq_port=$RABBIT_PORT
rabbitmq_user=$RABBIT_DATABASE_USERNAME
rabbitmq_password=$RABBIT_DATABASE_PASSWORD
rabbitmq_exchange="exchange_vpn"
rabbitmq_routing_key="routingkey"

json_payload='{"typeVpn": "ov"}'

rabbit_data=""
counter=0
for file in *.ovpn; do
    if [[ -f $file ]]; then
        value=$(base64 -w 0 "$file")
        json_payload="{\"typeVpn\":\"ov\",\"ip\":\"${PUBLIC_IP}\",\"vpnConfiguration\":\"${value}\",\"available\":\"true\",\"ami\":\"${INSTANCE_ID}\",\"region\":\"${INSTANCE_REGION}\"}"
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
    fi
done

# Check if the command was successful
if [ $? -eq 0 ]; then
    echo "Data successfully sent to RabbitMQ"
else
    echo "Failed to send data to RabbitMQ"
    exit 1
fi
##########WIREGUARD INSTALLATION#################################

cd /etc/wireguard

umask 077


export ENDPOINT=$(dig +short myip.opendns.com @resolver1.opendns.com)

export SERVER_IP="10.0.0.1"


export WAN_INTERFACE_NAME=$(ip r | grep default | awk {'print $5'})
# Update package list and install required dependencies
apt-get update
apt-get install -y apt-transport-https ca-certificates curl software-properties-common

# Add Docker repository and install Docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update
apt-get install -y docker-ce

# Install Docker Compose
curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Create Docker Compose configuration
mkdir -p ~/wireguard-docker
docker login ghcr.io -u eranunplugged -p ${GTOKEN}
cat << EOF > ~/wireguard-docker/docker-compose.yml
version: "2.1"
services:
  wireguard:
    image: ghcr.io/eranunplugged/up_wireguard:latest
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

systemctl start send_to_rabbitmq.timer
systemctl enable send_to_rabbitmq.timer

# Check the status of the timer
systemctl status send_to_rabbitmq.timer
