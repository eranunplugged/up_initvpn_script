function install_docker {
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose
  systemctl enable --now docker
}

function install_vault() {
  export VAULT_VERSION="1.9.3" # Replace with the desired version
  docker run -d -t --name=vault vault:${VAULT_VERSION}
  docker cp vault:/bin/vault /bin/vault
  docker rm -f vault
}

function install_up_ssh_certificate() {
  echo "# Installing ssh certificate"
  curl -s -o /etc/ssh/trusted-user-ca-keys.pem ${UP_VAULT_ADDR}/v1/ssh-client-signer2/public_key
  echo "TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem" >> /etc/ssh/sshd_config
  systemctl restart sshd
}
function vpn_protocol_enables() {
  echo ${VPN_TYPES} | grep ${1} >/dev/null 2>&1
}

function install_openvpn() {
  $(vpn_protocol_enables OPENVPN) || return
  [ -z "${OVPN_PORT}" ] && export OVPN_PORT=443
  export DISABLE_REALITY=1
  curl -o ovpn-gen-peers.sh https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/ovpn-gen-peers.sh
  chmod 777 ovpn-gen-peers.sh

  export OVPN_DATA="ovpn-data"
  export PUBLIC_IP=$(dig -4 TXT +short o-o.myaddr.l.google.com @ns1.google.com | grep -oP '(?<=").*(?=")')
  docker volume create --name $OVPN_DATA
  docker run -v $OVPN_DATA:/etc/openvpn --log-driver=none --rm protectvpn/ovpn:${OVPN_IMAGE_VERSION} ovpn_genconfig -u tcp://${PUBLIC_IP}:${OVPN_PORT}
  sed -i "s/1194/${OVPN_PORT}/i" /var/lib/docker/volumes/${OVPN_DATA}/_data/openvpn.conf
  docker run -v $OVPN_DATA:/etc/openvpn -d -p ${OVPN_PORT}:${OVPN_PORT}/tcp --cap-add=NET_ADMIN --name ovpn protectvpn/ovpn:${OVPN_IMAGE_VERSION}
  docker run -v $OVPN_DATA:/etc/openvpn --log-driver=none --rm -i -e DEBUG=1 --env OVPN_CN="${PUBLIC_IP}" --env EASYRSA_BATCH=1 protectvpn/ovpn:${OVPN_IMAGE_VERSION} ovpn_initpki nopass
  ls -la /var/lib/docker/volumes/$OVPN_DATA/_data
  ./ovpn-gen-peers.sh >/tmp/ovpn-gen.log 2>&1 &
}

function install_elastic() {
  if [ ! -z "${ES_ENABLED}" ]; then
    curl -L -O https://artifacts.elastic.co/downloads/beats/elastic-agent/${ES_PREFIX}.tar.gz
    tar xzvf ${ES_PREFIX}.tar.gz
    cd "${ES_PREFIX}" || exit
    ./elastic-agent install -f -n --url=${ES_CLOUD_URL} --enrollment-token=${ES_ENROLLMENT_TOKEN}
    cd ${OLDPWD}
  fi
}
function install_wireguard() {
  $(vpn_protocol_enables WIREGUARD) || return
  curl -o install_wireguard.sh https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/install_wireguard.sh
  chmod 777 install_wireguard.sh
  ./install_wireguard.sh
}

function install_reality(){
  $(vpn_protocol_enables REALITY) || return
}

function install_rabitmq_sender() {
  TMPDIR=$(mktmp)
  cd "${TMPDIR}"
  curl -o send_to_rabbitmq_template.sh https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/send_to_rabbitmq_template.sh

  # Set the user, group, and script path
    service_user="root"
    service_group="root"
    service_script_path="/usr/local/bin/send_to_rabbitmq.sh"

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
  OnCalendar=*-*-* *:0/1:00
  Unit=send_to_rabbitmq.service

  [Install]
  WantedBy=timers.target
EOF

  # Reload the systemd configuration, start the timer, and enable it to run at boot
  systemctl daemon-reload
  systemctl enable --now send_to_rabbitmq.timer

  # Check the status of the timer
  systemctl status send_to_rabbitmq.timer


}