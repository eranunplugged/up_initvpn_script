#!/bin/bash

echo << EOF >> /etc/sysctl.conf
net.ipv4.tcp_keepalive_time = 90
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_fastopen = 3
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.file-max = 65535000
EOF

echo << EOF >> /etc/security/limits.conf
root soft     nproc          655350
root hard     nproc          655350
root soft     nofile         655350
root hard     nofile         655350
EOF
mkdir /tmp/xray
cd /tmp/xray
sudo apt-get update
sudo apt-get install unzip
curl -o xray.zip https://github.com/XTLS/Xray-core/releases/download/v1.8.1/Xray-linux-64.zip
unzip xray.zip
rm -f xray.zip
./xray uuid -i Secret