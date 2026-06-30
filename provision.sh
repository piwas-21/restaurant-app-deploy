#!/usr/bin/env bash
# One-time bootstrap for a fresh Netcup RS box. Run as root.
# Tested on the delivered image: Debian 13 (trixie), amd64. Also works on
# Ubuntu — the Docker apt repo is selected from /etc/os-release ($ID/$VERSION_CODENAME).
#   ssh root@<server-ip>  then:  bash provision.sh
# Idempotent — safe to re-run.
set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-rumi}"
SSH_PUBKEY="${SSH_PUBKEY:-}"   # optional: export SSH_PUBKEY="ssh-ed25519 AAAA..." to seed the deploy user's key

echo "==> System update"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

echo "==> Base packages"
apt-get install -y ca-certificates curl gnupg git ufw fail2ban unattended-upgrades

echo "==> Non-root deploy user: ${DEPLOY_USER}"
if ! id "${DEPLOY_USER}" &>/dev/null; then
  adduser --disabled-password --gecos "" "${DEPLOY_USER}"
fi
usermod -aG sudo "${DEPLOY_USER}"
if [[ -n "${SSH_PUBKEY}" ]]; then
  install -d -m 700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh"
  echo "${SSH_PUBKEY}" > "/home/${DEPLOY_USER}/.ssh/authorized_keys"
  chmod 600 "/home/${DEPLOY_USER}/.ssh/authorized_keys"
  chown "${DEPLOY_USER}:${DEPLOY_USER}" "/home/${DEPLOY_USER}/.ssh/authorized_keys"
fi

echo "==> Docker Engine + compose plugin"
if ! command -v docker &>/dev/null; then
  . /etc/os-release   # $ID = debian|ubuntu, $VERSION_CODENAME = trixie|noble|...
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
usermod -aG docker "${DEPLOY_USER}"
systemctl enable --now docker

echo "==> Firewall (SSH + HTTP + HTTPS only)"
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "==> SSH hardening (key-only, no root password login)"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl reload ssh || systemctl reload sshd || true

echo "==> Unattended security upgrades"
dpkg-reconfigure -f noninteractive unattended-upgrades || true

echo "==> Application directory"
install -d -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" /opt/rumi

cat <<EOF

==> Done.
Next:
  1. SSH back in as ${DEPLOY_USER} (NOT root) and confirm sudo + docker work:
       ssh ${DEPLOY_USER}@<server-ip>
       docker ps
  2. Put the deploy folder at /opt/rumi/deploy (only this folder is needed; images come from GHCR).
  3. Fill /opt/rumi/deploy/.env and /opt/rumi/deploy/app-secrets.json.
  4. Point DNS, then: cd /opt/rumi/deploy && ./deploy.sh   (pulls GHCR images + starts)
EOF
