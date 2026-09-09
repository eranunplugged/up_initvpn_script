# Serialize with the distro's own boot-time apt activity.
#
# `-o DPkg::Lock::Timeout` covers only the dpkg locks. `apt-get update` takes
# /var/lib/apt/lists/lock via pkgAcquire::GetLock(), which makes a single
# non-blocking attempt and fails immediately ("Unable to lock directory") --
# there is no timeout option for that lock in any apt version, noble's
# included. apt-daily.timer is Persistent=true, so on a freshly-built image it
# fires right at first boot and wins the race; the first apt call then dies,
# Docker never installs, Vault never installs, and the script loops forever on
# "waiting for configurations".
#
# We wait and retry rather than masking apt-daily.timer / killing an in-flight
# unattended-upgrade: masking would silently disable security updates on the
# VPN node, and killing a running dpkg can leave packages half-configured.
# Correctness here comes from the retry, so this works even where `fuser` is
# absent. Budget: up to 60 attempts x 10 s = 10 minutes.
function apt_wait() {
  local i
  for i in $(seq 1 60); do
    if systemctl is-active --quiet apt-daily.service \
       || systemctl is-active --quiet apt-daily-upgrade.service \
       || systemctl is-active --quiet unattended-upgrades.service; then
      echo "apt_wait: a distro apt job is running, waiting (${i}/60)"
      sleep 10
      continue
    fi
    # shellcheck disable=SC2068
    DEBIAN_FRONTEND=noninteractive apt-get \
      -o DPkg::Lock::Timeout=300 \
      -o Dpkg::Options::=--force-confold \
      -yq $@ && return 0
    echo "apt_wait: 'apt-get $*' failed, retrying (${i}/60)"
    sleep 10
  done
  echo "apt_wait: 'apt-get $*' still failing after 60 attempts -- giving up"
  return 1
}

# Open the VPN ports on the host firewall.
#
# OCI's Canonical Ubuntu images ship /etc/iptables/rules.v4 whose INPUT chain
# ends in `-j REJECT --reject-with icmp-host-prohibited`, so WireGuard (51820/udp)
# and Reality/OpenVPN (443/tcp) are blocked on the host even when the VCN
# security list is correct. Oracle documents that ufw must NOT be used on their
# images -- it drops the rules that let the instance reach its iSCSI boot volume
# and can leave it unbootable -- so edit the iptables rules directly instead.
#
# `iptables -A INPUT` would append *after* the REJECT and be silently dead, so
# insert immediately before the first REJECT/DROP. On images with no such rule
# (Linode, DigitalOcean, Hetzner, AWS) the rules are simply appended and are a
# harmless no-op. Persist only where the image already manages rules that way.
function open_vpn_firewall_ports() {
  command -v iptables >/dev/null 2>&1 || return 0
  local specs=("-p udp --dport 51820" "-p tcp --dport 443")
  if [ -n "${OVPN_PORT}" ] && [ "${OVPN_PORT}" != "443" ]; then
    specs+=("-p tcp --dport ${OVPN_PORT}")
  fi
  local spec pos
  for spec in "${specs[@]}"; do
    # shellcheck disable=SC2086
    iptables -C INPUT $spec -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null && continue
    pos=$(iptables -L INPUT --line-numbers -n | awk '$2=="REJECT"||$2=="DROP"{print $1; exit}')
    if [ -n "$pos" ]; then
      # shellcheck disable=SC2086
      iptables -I INPUT "$pos" $spec -m conntrack --ctstate NEW -j ACCEPT
    else
      # shellcheck disable=SC2086
      iptables -A INPUT $spec -m conntrack --ctstate NEW -j ACCEPT
    fi
  done
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save
  iptables -S INPUT
}

function install_base_packages {
  # awscli was removed from Ubuntu 24.04 repos; install AWS CLI v2 from the official bundle.
  apt_wait install software-properties-common unzip jq amqp-tools default-jre sysstat gpg qrencode apt-transport-https ca-certificates curl dnsutils
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
  apt_wait update
  apt_wait install docker-ce docker-ce-cli containerd.io docker-compose-plugin
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
