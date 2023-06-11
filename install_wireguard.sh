
apt-get update
apt-get install -y wireguard-dkms wireguard-tools

cd /etc/wireguard || exit
umask 077
export ENDPOINT=$(dig +short myip.opendns.com @resolver1.opendns.com)
export SERVER_IP="10.0.0.1"
export WAN_INTERFACE_NAME=$(ip r | grep default | awk {'print $5'})
# Update package list and install required dependencies

# Install Docker Compose
curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Create Docker Compose configuration
mkdir -p ~/wireguard-docker
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
      - SERVERURL=${ENDPOINT}
      - SERVERPORT=51820
      - PEERS=${NUM_USERS}
      - PEERDNS=1.1.1.1
      - INTERNAL_SUBNET=${SERVER_IP}
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


## Wait for all the files to be generated
client_conf="/etc/wireguard/config/peer${NUM_USERS}/peer${NUM_USERS}.conf"
while [ ! -f "$client_conf"  ]; do
        echo "waiting for configurations"
        sleep 1
done

# Initialize an empty array for storing JSON objects
#json_payload='{"protocol": "WIREGUARD"}'

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
        json_payload="{\"protocol\":\"WIREGUARD\",\"ip\":\"${PUBLIC_IP}\",\"vpnConfiguration\":\"${value}\",\"available\":\"true\",\"ami\":\"${INSTANCE_ID}\",\"region\":\"${INSTANCE_REGION}\"}"
        if [ "${rabbit_data}" == "" ]; then
            rabbit_data=${json_payload}
        else
            rabbit_data="${rabbit_data},${json_payload}"
        fi
        counter=$((counter + 1))

        # Send rabbit_data in batches of 10
        if [ $counter -eq 10 ]; then
            echo "Sending $rabbit_data to rabbitmq"
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
