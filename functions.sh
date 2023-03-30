function install_docker {
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose
  systemctl enable --now docker
}

function install_vault() {

  cd /tmp || exit
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
  cd "$OLDPWD" || exit
}