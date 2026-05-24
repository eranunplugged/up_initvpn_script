function install_base_packages {
  # awscli was removed from Ubuntu 24.04 repos; install AWS CLI v2 from the official bundle.
  DEBIAN_FRONTEND=noninteractive apt install -o DPkg::Lock::Timeout=-1 -y software-properties-common unzip jq amqp-tools default-jre sysstat gpg qrencode apt-transport-https ca-certificates curl dnsutils
  if ! command -v aws >/dev/null 2>&1; then
    curl -sL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    rm -rf /tmp/aws /tmp/awscliv2.zip
  fi
}

function install_docker {
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -o DPkg::Lock::Timeout=-1
  DEBIAN_FRONTEND=noninteractive apt-get install -o DPkg::Lock::Timeout=-1 -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
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
  # On Ubuntu 24.04 the systemd unit is `ssh.service` (socket-activated); the
  # `sshd.service` alias from 20.04 is gone, so `restart sshd` exits non-zero
  # and the new TrustedUserCAKeys line is never reloaded.
  systemctl restart ssh
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
  docker run -v ${OVPN_DATA}:/etc/openvpn --log-driver=none --rm ghcr.io/eranunplugged/up_openvpn_xor:${OVPN_IMAGE_VERSION} ovpn_genconfig -u tcp://${PUBLIC_IP}:${OVPN_PORT}
  sed -i "s/1194/${OVPN_PORT}/i" /var/lib/docker/volumes/${OVPN_DATA}/_data/openvpn.conf
  docker run -v $OVPN_DATA:/etc/openvpn --log-driver=none --rm -i -e DEBUG=1 --env OVPN_CN="${PUBLIC_IP}" --env EASYRSA_BATCH=1 ghcr.io/eranunplugged/up_openvpn_xor:${OVPN_IMAGE_VERSION} ovpn_initpki nopass
  docker run -v $OVPN_DATA:/etc/openvpn -d -p ${OVPN_PORT}:${OVPN_PORT}/tcp --cap-add=NET_ADMIN --name ovpn ghcr.io/eranunplugged/up_openvpn_xor:${OVPN_IMAGE_VERSION}
  ls -la /var/lib/docker/volumes/$OVPN_DATA/_data/pki/issued/
  ./ovpn-gen-peers.sh >/tmp/ovpn-gen.log 2>&1
}

function install_elastic() {
  if [ -n "${ES_ENABLED}" ]; then
    [ -z "${ES_PREFIX}" ] && echo "Need to set elastic prefix" && return
    [ -z "${ES_CLOUD_URL}" ] && echo "Need to set elastic cloud url" && return
    [ -z "${ES_ENROLLMENT_TOKEN}" ] && echo "Need to set elastic token" && return
    # Vault ships ES_PREFIX as elastic-agent-<ver>-linux-x86_64; rewrite for
    # aarch64 hosts (e.g. OCI Ampere shapes) so we don't tar-extract an x86
    # binary that then dies with "cannot execute binary file: Exec format error".
    if [ "$(uname -m)" = "aarch64" ]; then
      ES_PREFIX=${ES_PREFIX//x86_64/arm64}
    fi
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
  curl -o install_wireguard.sh https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/install_wireguard-2404.sh
  chmod 777 install_wireguard.sh
  ./install_wireguard.sh
}

function install_reality(){
  $(vpn_protocol_enables REALITY) || return
  [ -n "$DISABLE_REALITY" ] && return
  # shellcheck disable=SC2086
  curl -o install_reality.sh https://raw.githubusercontent.com/eranunplugged/up_initvpn_script/${BRANCH}/install_reality-2404.sh
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
