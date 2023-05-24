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
  docker volume create --name $OVPN_DATA
  docker run -v ${OVPN_DATA}:/etc/openvpn --log-driver=none --rm protectvpn/ovpn:${OVPN_IMAGE_VERSION} ovpn_genconfig -u tcp://${PUBLIC_IP}:${OVPN_PORT}
  sed -i "s/1194/${OVPN_PORT}/i" /var/lib/docker/volumes/${OVPN_DATA}/_data/openvpn.conf
  docker run -v $OVPN_DATA:/etc/openvpn -d -p ${OVPN_PORT}:${OVPN_PORT}/tcp --cap-add=NET_ADMIN --name ovpn protectvpn/ovpn:${OVPN_IMAGE_VERSION}
  docker run -v $OVPN_DATA:/etc/openvpn --log-driver=none --rm -i -e DEBUG=1 --env OVPN_CN="${PUBLIC_IP}" --env EASYRSA_BATCH=1 protectvpn/ovpn:${OVPN_IMAGE_VERSION} ovpn_initpki nopass
  ls -la /var/lib/docker/volumes/$OVPN_DATA/_data
  ./ovpn-gen-peers.sh >/tmp/ovpn-gen.log 2>&1 &
}

function install_elastic() {
  if [ -n "${ES_ENABLED}" ]; then
    [ -z "${ES_PREFIX}" ] && echo "Need to set elastic prefix" && return
    [ -z "${ES_CLOUD_URL}" ] && echo "Need to set elastic cloud url" && return
    [ -z "${ES_ENROLLMENT_TOKEN}" ] && echo "Need to set elastic token" && return
    # shellcheck disable=SC2086
    curl -L -O https://artifacts.elastic.co/downloads/beats/elastic-agent/${ES_PREFIX}.tar.gz
    # shellcheck disable=SC2086
    tar xzvf ${ES_PREFIX}.tar.gz
    cd "${ES_PREFIX}" || exit
    # shellcheck disable=SC2086
    ./elastic-agent install -f -n --url=${ES_CLOUD_URL} --enrollment-token=${ES_ENROLLMENT_TOKEN}
    # shellcheck disable=SC2086
    # shellcheck disable=SC2164
    cd ${OLDPWD}
  fi
}
function install_wireguard() {
  $(vpn_protocol_enables WIREGUARD) || return
  # shellcheck disable=SC2086
  curl -o install_wireguard.sh https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/install_wireguard.sh
  chmod 777 install_wireguard.sh
  ./install_wireguard.sh
}

function install_reality(){
  $(vpn_protocol_enables REALITY) || return
  [ -n "$DISABLE_REALITY" ] && return
  # shellcheck disable=SC2086
  curl -o install_reality.sh https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/install_reality.sh
  chmod 777 install_reality.sh
  ./install_reality.sh
}

function install_rabitmq_sender() {
  # no need to send data if no protocol was installed
  [ -z "$VPN_TYPES" ] && return
  # shellcheck disable=SC2086
  curl -o send_to_rabbitmq.sh https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/send_to_rabbitmq.sh
  chmod 777 send_to_rabbitmq.sh
  ./send_to_rabbitmq.sh
}