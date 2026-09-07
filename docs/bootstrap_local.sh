set -euo pipefail

# Ce script initialise la VM pour acceuilir les deploiements et commandes ansible

# Usage:
#   HOSTS="srv1 srv2" INIT_USER="root" INIT_PASS="xxx" PUBKEY_FILE="$HOME/.ssh <redacted>_ed25519.pub" ./bootstrap <redacted>.sh

HOSTS=${HOSTS:-}
INIT_USER=${INIT_USER:-root}
INIT_PASS=${INIT_PASS:-}
PUBKEY_FILE=${PUBKEY_FILE:-$HOME/.ssh <redacted>_ed25519.pub}

if [[ -z "$HOSTS" ]]; then
  echo "Définis HOSTS=\"host1 host2 ...\""
  exit 1
fi
if [[ ! -r "$PUBKEY_FILE" ]]; then
  echo "Clé publique introuvable: $PUBKEY_FILE"
  exit 1
fi

PUBKEY_CONTENT="$(cat "$PUBKEY_FILE")"

for HOST in $HOSTS; do
  echo ">>> Bootstrap $HOST (via $INIT_USER)"
  if [[ -n "$INIT_PASS" ]]; then
    SSH="sshpass -p $INIT_PASS ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -l $INIT_USER $HOST"
  else
    SSH="ssh -o StrictHostKeyChecking=no -l $INIT_USER $HOST"
  fi

  # 1) Paquets minimaux
  $SSH "command -v apt-get >/dev/null 2>&1 && (apt-get update -y || true; DEBIAN_FRONTEND=noninteractive apt-get install -y sudo python3 rsync) || true
        command -v dnf >/dev/null 2>&1     && (dnf -y install sudo python3 rsync || true) || true
        command -v yum >/dev/null 2>&1     && (yum -y install sudo python3 rsync || true) || true
        command -v apk >/dev/null 2>&1     && (apk add --no-cache sudo python3 rsync || true) || true"

  # 2) Crée l’utilisateur - s’il n’existe pas
  $SSH "id -u <redacted> >/dev/null 2>&1 || useradd -m -s /bin/bash <redacted> || adduser -D -s /bin/bash <redacted> || true
        # groupes sudo/wheel selon distro
        getent group sudo  >/dev/null 2>&1 && usermod -aG sudo  <redacted> || true
        getent group wheel >/dev/null 2>&1 && usermod -aG wheel <redacted> || true
        # 3) SSH keys
        install -d -m 700 -o <redacted> -g <redacted> /home <redacted>/.ssh
        printf '%s\n' '$PUBKEY_CONTENT' >> /home <redacted>/.ssh/authorized_keys
        chown <redacted> /home <redacted>/.ssh/authorized_keys
        chmod 600 /home <redacted>/.ssh/authorized_keys
        # 4) Sudo NOPASSWD pour automatisation
        if command -v visudo >/dev/null 2>&1; then
          echo  <redacted> ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99 <redacted>
          chmod 440 /etc/sudoers.d/99 <redacted>
          visudo -c >/dev/null
        else
          # fallback (rare)
          echo  <redacted> ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
        fi
        # 5) Verrouiller le mot de passe (clé seule)
        (command -v passwd >/dev/null 2>&1 && passwd -l <redacted>) || true
        # 6) Durcir SSH root
        if [ -f /etc/ssh/sshd_config ] && grep -q '^PermitRootLogin' /etc/ssh/sshd_config; then
          sed -i 's/^PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config || true
          systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        fi
  "

  echo ">>> OK : $HOST prêt pour utilisationAnsible via <redacted> "
done