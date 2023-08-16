#!/bin/bash
TMPDIR=$(mktemp -d)
cd "${TMPDIR}"
curl -o send_to_rabbitmq_template.sh https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/send_to_rabbitmq_template.sh

# Set the user, group, and script path
service_user="root"
service_group="root"
service_script_path="/usr/local/bin/send_to_rabbitmq.sh"

# Point (latitude and longitude)
mkdir -p /etc/up
location_data=$(curl -s "http://ip-api.com/json/$PUBLIC_IP")
latitude=$(echo "$location_data" | jq -r '.lat')
longitude=$(echo "$location_data" | jq -r '.lon')
city=$(echo "$location_data" | jq -r '.city')
point=$(jq -n --arg lat "$latitude" --arg  lon "$longitude" --arg city "$city" '{lat: $lat, lon: $lon, city: $city}')
echo "${point}" > /etc/up/point

########Create rabbitmq stats sender#######
sed -e "s/%%RABBIT_HOST%%/$RABBIT_HOST/" \
    -e "s/%%RABBIT_PORT%%/$RABBIT_PORT/" \
    -e "s/%%RABBIT_DATABASE_USERNAME%%/$RABBIT_DATABASE_USERNAME/" \
    -e "s/%%RABBIT_DATABASE_PASSWORD%%/$RABBIT_DATABASE_PASSWORD/" \
    -e "s/%%INSTANCE_ID%%/$INSTANCE_ID/" \
    -e "s/%%PUBLIC_IP%%/$PUBLIC_IP/" \
    -e "s/%%INSTANCE_REGION%%/$INSTANCE_REGION/" \
    send_to_rabbitmq_template.sh > ${service_script_path}

chmod +x ${service_script_path}



# Create the send_to_rabbitmq.service file
cat << EOF > /etc/systemd/system/send_to_rabbitmq.service
[Unit]
Description=Send server info to RabbitMQ

[Service]
Type=oneshot
User=${service_user}
Group=${service_group}
ExecStart=${service_script_path}
EOF

# Create the send_to_rabbitmq.timer file
cat << EOF > /etc/systemd/system/send_to_rabbitmq.timer
[Unit]
Description=Send server info to RabbitMQ every minute

[Timer]
OnCalendar=*:0/5
Unit=send_to_rabbitmq.service

[Install]
WantedBy=timers.target
EOF

# Reload the systemd configuration, start the timer, and enable it to run at boot
systemctl daemon-reload
systemctl enable --now send_to_rabbitmq.timer

# Check the status of the timer
systemctl status send_to_rabbitmq.timer