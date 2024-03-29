#!/bin/bash

# Configuration
rabbitmq_host="%%RABBIT_HOST%%"
rabbitmq_port="%%RABBIT_PORT%%"
rabbitmq_user="%%RABBIT_DATABASE_USERNAME%%"
rabbitmq_password="%%RABBIT_DATABASE_PASSWORD%%"
rabbitmq_routing_key="ping"
ami="%%INSTANCE_ID%%"

# Time
time=$(date +"%s")

# IP (retrieve the primary public IP of the instance)
public_ip="%%PUBLIC_IP%%"

# CPU usage (averaged over 1 minute)
PREV_TOTAL=0
PREV_IDLE=0
for ITER in {1..2}; do
    CPU=( $(cat /proc/stat | grep ^cpu ) )
    IDLE=${CPU[4]}
    TOTAL=0
    for VALUE in "${CPU[@]:1}"; do
        TOTAL=$((TOTAL + VALUE))
    done

    DIFF_IDLE=$((IDLE - PREV_IDLE))
    DIFF_TOTAL=$((TOTAL - PREV_TOTAL))
    DIFF_USAGE=$((1000 * (DIFF_TOTAL - DIFF_IDLE) / DIFF_TOTAL + 5))
    USAGE_PERCENT=$((DIFF_USAGE / 10))

    PREV_TOTAL="$TOTAL"
    PREV_IDLE="$IDLE"

    if [ $ITER -eq 1 ]; then
        sleep 1
    fi
done

cpu=$USAGE_PERCENT

# Server status (true if the server is up, false otherwise)
serverStatusUP=true
point=$(cat /etc/up/point)

# Create JSON payload
payload=$(jq -n --arg time "$time" \
               --arg ami "$ami" \
               --arg ip "$public_ip" \
               --arg cpu "$cpu" \
               --arg serverStatusUP "$serverStatusUP" \
               --arg region "%%INSTANCE_REGION%%" \
               --argjson point "$point" \
               '{time: $time, ami: $ami, ip: $ip, cpu: $cpu, serverStatusUP: $serverStatusUP, region: $region, point: $point}')

# Send data to RabbitMQ
echo "Sending data to RabbitMQ: $payload"
amqp-publish -u "amqp://${rabbitmq_user}:${rabbitmq_password}@${rabbitmq_host}:${rabbitmq_port}" -r "$rabbitmq_routing_key" -p -b "$payload"
