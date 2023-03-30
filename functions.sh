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