#!/usr/bin/env bash.

# Ce script provisionne via l'image debian-12-cloudinit une VM HexStrike et la harden sur serveur XCP-NG
# Utiliser une clé ssh root pour l'initialisation.
# Genèrer le mot de passe de la vm avec "openssl passwd -6 'password'", puis ajouter le resultat dans SSH_PASSWORD_HASH
# L'installation via XOA nest pas fonctionnel

set -Eeuo pipefail

if ! command -v python3 >/dev/null; then
  echo "Python3 requis." >&2; exit 1
fi

# --- Paramètres ---
# Exécution auto en fin de script.
AUTO_RUN="${AUTO_RUN:-1}"

# Tags Ansible utilisés par défaut.
INSTALL_TAGS="${INSTALL_TAGS:-provision,configure,verify}"

# Répertoires et fichiers Ansible.
PROJECT_DIR="${PROJECT_DIR:-hexmcp-ansible}"
TF_DIR="${TF_DIR:-$PROJECT_DIR/terraform}"

INV="${INV:-$PROJECT_DIR/inventories/lab/hosts.ini}"
PLAY="${PLAY:-$PROJECT_DIR/site.yml}"

ANSIBLE_VERSION="${ANSIBLE_VERSION:-9.1.0}"   # ansible 9.x (core >=2.16)
VENV_DIR="${VENV_DIR:-$HOME/venvs/ansible}"

# Driver XCP-ng : xo via Xen Orchestra ou xapi direct.
XCP_DRIVER="${XCP_DRIVER:-xapi}"


# Paramètres Xen Orchestra.
XO_URL="${XO_URL:-wss://x<redacted>h}"
XO_USER="${XO_USER:-<redacted>}"
XO_PASS="${XO_PASS:-T<redacted>o}"
XO_TEMPLATE_NAME="${XO_TEMPLATE_NAME:-debian-12-cloudinit}"
XO_SR_NAME="${XO_SR_NAME:-OMV}"
XO_NETWORK_NAME="${XO_NETWORK_NAME:-VLAN-HEXSTRIKE}"
XO_INSECURE="${XO_INSECURE:-true}"


# Paramètres XAPI direct.
XAPI_HOST="${XAPI_HOST:-<redacted>}"
XAPI_USER="${XAPI_USER:-<redacted>}"
XAPI_PASS="${XAPI_PASS:-<redacted>}"
XAPI_TEMPLATE="${XAPI_TEMPLATE:-<redacted>t}"
XAPI_NET="${XAPI_NET:-<redacted>}"

# VM. Pour HexStrike, viser plutôt 4 vCPU, 6 Go RAM et 80 Go disque.
VM_NAME="${VM_NAME:-hexmcp-ephemeral}"
VM_VCPUS="${VM_VCPUS:-1}"
VM_RAM_MB="${VM_RAM_MB:-1024}"
VM_DISK_GB="${VM_DISK_GB:-40}"
VM_MAC="${VM_MAC:-02:16:3e:66:00:01}"

# Réseau injecté côté Terraform/cloud-init.
HEXMCP_IP="${HEXMCP_IP:-192.168.66.2}"
HEXMCP_GW="${HEXMCP_GW:-192.168.66.1}"
HEXMCP_DNS1="${HEXMCP_DNS1:-192.168.2.254}"
HEXMCP_DNS2="${HEXMCP_DNS2:-1.1.1.1}"
HEXMCP_USER="${HEXMCP_USER:-hex}"


# Compte SSH initial et clé injectée.
SSH_USER="${SSH_USER:-debian}"
SSH_KEY_NAME="${SSH_KEY_NAME:-<redacted>}"   # sera créé dans ~/.ssh si absent
SSH_PUBKEY_PATH="${SSH_PUBKEY_PATH:-$HOME/.ssh/${SSH_KEY_NAME}.pub}"
SSH_PRIVKEY_PATH="${SSH_PRIVKEY_PATH:-$HOME/.ssh/${SSH_KEY_NAME}}"
ROOT_PASS="${ROOT_PASS:-root}"

# HexStrike / MCP.
MCP_BIND_IP="${MCP_BIND_IP:-0.0.0.0}"
MCP_BIND_PORT="${MCP_BIND_PORT:-8888}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"             # optionnel
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"       # optionnel
OTHER_SECRET="${OTHER_SECRET:-}"                 # optionnel
MCP_REPO_URL="${MCP_REPO_URL:-https://github.com/0x4m4/hexstrike-ai.git}"  # à vérifier si le dépôt change

# Interface VPN HTB.
HTB_IFACE="${HTB_IFACE:-tun0}"

# OpenVPN HTB : copie un profil local puis crée le service.
HTB_ENABLE="${HTB_ENABLE:-1}"                    # 1=activer, 0=désactiver
HTB_OVPN_SRC="${HTB_OVPN_SRC:-/root/academy-regular.ovpn}" # Chemin côté Deployer, copié ensuite sur la VM.
HTB_OVPN_DST="${HTB_OVPN_DST:-/etc/openvpn/htb.ovpn}"

# 1 = réécrire les fichiers générés.
OVERWRITE="${OVERWRITE:-1}"


set --
# --- Fonctions ---

die(){ echo "ERROR: $*" >&2; exit 1; }

need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "Commande requise manquante: $1"; }

wf(){
  local target="$1"
  local mode="${2:-}"

  mkdir -p "$(dirname "$target")"
  if [[ "${OVERWRITE:-0}" = "1" || ! -s "$target" ]]; then
    cat >"$target"
    [[ -n "$mode" ]] && chmod "$mode" "$target"
  else
    echo "[skip] $target existe déjà"
  fi
}

ensure_dirs(){
  mkdir -p "$PROJECT_DIR" "$TF_DIR" "$(dirname "$INV")"
}


# --- Pré-requis locaux ---

echo "[init] Vérification des dépendances locales"
need_cmd bash
need_cmd python3
need_cmd ssh-keygen
need_cmd sshpass

if ! command -v ansible >/dev/null 2>&1; then
  echo "[init] Ansible absent, installation via apt"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    sudo apt-get install -y ansible python3-pip python3-venv
  else
    die "Ansible absent et installation automatique impossible."
  fi
fi

ensure_venv() {
  python3 -m venv "$VENV_DIR" 2>/dev/null || true
  # shellcheck source=/dev/null
  . "$VENV_DIR/bin/activate"
  python -m pip install --upgrade pip wheel setuptools
  python -m pip install "ansible==${ANSIBLE_VERSION}"
  ansible --version || true
}

echo "[init] Venv Ansible: $VENV_DIR"
ensure_venv
export PATH="$VENV_DIR/bin:$PATH"

ensure_terraform(){
  if ! command -v terraform >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y gnupg software-properties-common
    wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
      sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
    sudo apt-get update && sudo apt-get install -y terraform
  fi
  terraform -version
}
ensure_terraform
ensure_dirs

# Clé SSH locale.
SSH_DIR="$HOME/.ssh"
SSH_KEY="$SSH_DIR/$SSH_KEY_NAME"
if [[ ! -f "$SSH_KEY" ]]; then
  echo "[init] Génération clé SSH: $SSH_KEY"
  mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"
  ssh-keygen -t ed25519 -N "" -f "$SSH_KEY"
else
  echo "[init] Clé SSH existante: $SSH_KEY"
fi
PUBKEY="$(cat "$SSH_KEY.pub")"

# --- Terraform ---

TF_DIR="${TF_DIR:-$PROJECT_DIR/terraform}"

# main.tf
wf "$TF_DIR/main.tf" <<'EOF'
terraform {
  required_providers {
    xenorchestra = {
      source  = "terra-farm/xenorchestra"
    }
    cloudinit = {
        source = "hashicorp/cloudinit"
  }
 }
}

provider "xenorchestra" {
  url      = var.xo_url
  username = var.xo_user
  password = var.xo_pass
  insecure = var.xo_insecure
}

data "xenorchestra_template" "tmpl"  { name_label = var.xo_template_name }
data "xenorchestra_sr"       "sr"    { name_label = var.xo_sr_name }
data "xenorchestra_network"  "net"   { name_label = var.xo_network_name }

# cloud-init.
data "cloudinit_config" "cfg" {
  gzip          = false
  base64_encode = false

part {
  filename     = "user-data"
  content_type = "text/cloud-config"
  content = <<-EOC
#cloud-config
hostname: ${var.vm_name}

#cloud-config
disable_root: false
ssh_pwauth: true
chpasswd:
  expire: false
  list: |
    root:root

package_update: false
package_upgrade: false
  EOC
}

part {
  filename     = "network-config"
  content_type = "text/plain"
  content = <<-EON
version: 2
ethernets:
  nic0:
    match:
      macaddress: "${var.vm_mac}"
    dhcp4: true
    dhcp6: false
    nameservers:
      addresses:
        - 192.168.66.1
    optional: true
EON
}

}
resource "xenorchestra_cloud_config" "cc" {
  name     = "${var.vm_name}-cloudinit"
  template = data.cloudinit_config.cfg.rendered
}

resource "xenorchestra_vm" "hexmcp" {
  name_label   = var.vm_name
  template     = data.xenorchestra_template.tmpl.id
  cloud_config = xenorchestra_cloud_config.cc.id

  # CPU / RAM
  cpus       = var.vm_vcpus
  memory_max = var.vm_memory_mb * 1024 * 1024
  auto_poweron = true

  # Disque
  disk {
    sr_id      = data.xenorchestra_sr.sr.id
    name_label = "boot-disk"
    size       = var.vm_disk_gb * 1024 * 1024 * 1024
  }

  # Réseau (VLAN-HTB + MAC fixe)
  network {
    network_id  = data.xenorchestra_network.net.id
    mac_address = var.vm_mac
  }

  # Attendre que la VM soit running sinon la population de la VM peut ne pas se faire.
  power_state = "Running"
}

output "vm_name" { value = xenorchestra_vm.hexmcp.name_label }
EOF

# variables.tf
wf "$TF_DIR/variables.tf" <<'EOF'
variable "xo_url"           { type = string }
variable "xo_user"          { type = string }

variable "xo_pass" {
  type      = string
  sensitive = true
}

variable "xo_insecure" {
  type = bool
  default = true
}


variable "xo_template_name" { type = string }
variable "xo_sr_name"       { type = string }
variable "xo_network_name"  { type = string }
variable "vm_mac"           { type = string }

variable "vm_name"          { type = string }
variable "vm_vcpus"         { type = number }
variable "vm_memory_mb"     { type = number }
variable "vm_disk_gb"       { type = number }

variable "vm_ssh_user"      { type = string }
variable "vm_ssh_pubkey"    { type = string }

variable "vm_ip"            { type = string }
variable "vm_gw"            { type = string }
variable "vm_dns1"          { type = string }
variable "vm_dns2"          { type = string }
EOF

# terraform.tfvars généré depuis les variables shell.
if [[ ! -s "$SSH_PUBKEY_PATH" ]]; then
  echo "[!] Clé SSH publique absente: $SSH_PUBKEY_PATH" >&2; exit 1
fi
SSH_PUBKEY_VAL="$(cat "$SSH_PUBKEY_PATH")"

wf "$TF_DIR/terraform.tfvars" <<EOF
xo_url           = "${XO_URL}"
xo_user          = "${XO_USER}"
xo_pass          = "${XO_PASS}"
xo_insecure      = ${XO_INSECURE}

xo_template_name = "${XO_TEMPLATE_NAME}"
xo_sr_name       = "${XO_SR_NAME}"
xo_network_name  = "${XO_NETWORK_NAME}"

vm_name       = "${VM_NAME}"
vm_vcpus      = ${VM_VCPUS}
vm_memory_mb  = ${VM_RAM_MB}
vm_disk_gb    = ${VM_DISK_GB}
vm_mac        = "${VM_MAC}"

vm_ssh_user   = "${SSH_USER}"
vm_ssh_pubkey = "${SSH_PUBKEY_VAL}"

vm_ip   = "${HEXMCP_IP}"
vm_gw   = "${HEXMCP_GW}"
vm_dns1 = "${HEXMCP_DNS1}"
vm_dns2 = "${HEXMCP_DNS2}"
EOF


# --- Arborescence Ansible ---

echo "[ansible] Génération des fichiers dans $PROJECT_DIR"
mkdir -p "$PROJECT_DIR"/{inventories/lab,group_vars,roles,roles/{xcp_guest,base_hardening,mcp_install,mcp_verify,mcp_teardown,htb_vpn}/{tasks,templates,files}}

# ansible.cfg
wf "$PROJECT_DIR/ansible.cfg" 0644 <<'EOF'
[defaults]
stdout_callback = yaml
host_key_checking = False
retry_files_enabled = False
deprecation_warnings = False
inventory = inventories/lab/hosts.ini
timeout = 45
EOF

# requirements.yml
wf "$PROJECT_DIR/requirements.yml" 0644 <<'EOF'
---
collections:
  - name: community.general
EOF

# hosts.ini
wf "$PROJECT_DIR/inventories/lab/hosts.ini" 0644 <<'EOF'
[localhost]
127.0.0.1 ansible_connection=local

[hexmcp]
# rempli après provision.
EOF

# group_vars/all.yml
wf "$PROJECT_DIR/group_vars/all.yml" 0644 <<EOF
xcp_driver: "$XCP_DRIVER"

# XO
t_xo_url: "$XO_URL"
xo_username: "$XO_USER"
xo_password: "$XO_PASS"
xo_template_name: "$XO_TEMPLATE_NAME"
xo_sr_name: "$XO_SR_NAME"
xo_network_name: "$XO_NETWORK_NAME"

# XAPI
xapi_hostname: "$XAPI_HOST"
xapi_username: "$XAPI_USER"
xapi_password: "$XAPI_PASS"
xapi_template_name: "$XAPI_TEMPLATE"
xapi_network_name: "$XAPI_NET"

# VM
hexmcp_vm_name: "$VM_NAME"
hexmcp_vcpus: $VM_VCPUS
hexmcp_ram_mb: $VM_RAM_MB
hexmcp_disk_gb: $VM_DISK_GB
hexmcp_cloudinit_sshkey: "$PUBKEY"

# SSH invité
hexmcp_ip: "dhcp"
ssh_user: "$SSH_USER"
hex_pubkey: "$HOME/.ssh/hex_hexmcp_ed25519.pub"

# MCP
mcp_dir: "/opt/hexmcp"
mcp_user: "$MCP_USER"
mcp_group: "$MCP_USER"
mcp_bind_ip: "$MCP_BIND_IP"
mcp_bind_port: "$MCP_BIND_PORT"
mcp_env:
  OPENAI_API_KEY: "$OPENAI_API_KEY"
  ANTHROPIC_API_KEY: "$ANTHROPIC_API_KEY"
  OTHER_SECRET: "$OTHER_SECRET"
mcp_repo_url: "$MCP_REPO_URL"

# Firewall
htb_iface: "$HTB_IFACE"
allowed_out_tcp: [80, 443, 53]
allowed_out_udp: [53]

# Durcissement système
mounts_noexec:
  - { path: "/tmp",     opts: "nodev,nosuid,noexec" }
  - { path: "/var/tmp", opts: "nodev,nosuid,noexec" }

sysctl_hardening:
  net.ipv4.ip_forward: 0
  net.ipv4.conf.all.send_redirects: 0
  net.ipv4.conf.default.send_redirects: 0
  net.ipv4.conf.all.accept_redirects: 0
  net.ipv4.conf.default.accept_redirects: 0
  net.ipv4.conf.all.accept_source_route: 0
  net.ipv4.conf.default.accept_source_route: 0
  net.ipv4.tcp_syncookies: 1
  net.ipv6.conf.all.accept_redirects: 0
  net.ipv6.conf.default.accept_redirects: 0

# VPN HTB
htb_enable: ${HTB_ENABLE}
htb_ovpn_src: "$HTB_OVPN_SRC"
htb_ovpn_dst: "$HTB_OVPN_DST"
EOF

# site.yml
wf "$PROJECT_DIR/site.yml" 0644 <<'EOF'
---
- name: Provision VM HexMCP sur XCP-NG
  hosts: localhost
  gather_facts: false
  tags: [provision]
  roles:
    - role: xcp_guest

- name: Durcir la VM + installer MCP + outils
  hosts: hexmcp
  become: true
  gather_facts: false
  tags: [configure]
  pre_tasks:
    - name: Nettoyer known_hosts pour l’IP (VM recréée)
      known_hosts:
        name: "{{ inventory_hostname }}"
        state: absent
      delegate_to: localhost
      become: false

    - name: Attendre la réponse SSH
      wait_for_connection:
        delay: 2
        timeout: 50
  roles:
    - role: base_hardening
    - role: htb_vpn     # activé seulement si htb_enable=true
    - role: mcp_install

- name: Vérifications de sécurité
  hosts: hexmcp
  become: true
  gather_facts: false
  tags: [verify]
  pre_tasks:
    - name: Attendre que la VM soit joignable en SSH
      wait_for_connection:
        delay: 5
        timeout: 600
  roles:
    - role: mcp_verify

- name: Détruire la VM HexMCP
  hosts: localhost
  gather_facts: false
  tags: [destroy]
  roles:
    - role: mcp_teardown
EOF

# --- Role xcp_guest ---
wf "$PROJECT_DIR/roles/xcp_guest/tasks/main.yml" 0644 <<'EOF'
---
- name: Définir la cible SSH
  set_fact:
    wait_ssh_host: "{{ hexmcp_vm_name }}"

- name: Pas de création Ansible en mode XO
  set_fact:
    xo_vm:
      changed: false
  when: xcp_driver == 'xo'

- name: Créer la VM via XAPI
  community.general.xenserver_guest:
    hostname: "{{ xapi_hostname }}"
    username: "{{ xapi_username }}"
    password: "{{ xapi_password }}"
    name: "{{ hexmcp_vm_name }}"
    template: "{{ xapi_template_name }}"
    state: running
    hardware:
      num_cpus: "{{ hexmcp_vcpus }}"
      memory_mb: "{{ hexmcp_ram_mb }}"
    disks:
      - size_gb: "{{ hexmcp_disk_gb }}"
    networks:
      - name: "{{ xapi_network_name }}"
    cloud_init: |
      #cloud-config
      disable_root: false
      ssh_pwauth: true
      chpasswd:
        expire: false
        list: |
          root:root

      package_update: true
      package_upgrade: true
  when: xcp_driver == 'xapi'
  register: xapi_vm

- name: Attendre SSH de la VM
  wait_for:
    host: "{{ wait_ssh_host }}"
    port: 22
    timeout: 600

- name: Ajouter la VM à l'inventaire
  add_host:
    name: "{{ wait_ssh_host }}"
    groups: hexmcp
    ansible_user: "root"
EOF

# --- Role base_hardening ---
wf "$PROJECT_DIR/roles/base_hardening/tasks/main.yml" 0644 <<'EOF'
---
- name: Créer l’utilisateur hex
  user:
    name: hex
    groups: sudo
    shell: /bin/bash
    create_home: true
    state: present

- name: Installer la clé SSH pour hex
  authorized_key:
    user: hex
    key: "{{ lookup('file', '/root/.ssh/hexmcp_ed25519.pub') }}"
    state: present

- name: Sudo NOPASSWD pour hex
  copy:
    dest: /etc/sudoers.d/90-hex
    content: "hex ALL=(ALL) NOPASSWD:ALL\n"
    owner: root
    group: root
    mode: "0440"
    validate: "/usr/sbin/visudo -cf %s"

- name: Appliquer la configuration SSH
  copy:
    dest: /etc/ssh/sshd_config
    owner: root
    group: root
    mode: '0600'
    content: |
      Port <redacted>
      Protocol 2
      PermitRootLogin yes
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      ChallengeResponseAuthentication no
      UsePAM yes
      X11Forwarding no
      AllowAgentForwarding no
      ClientAliveInterval 300
      ClientAliveCountMax 2
      AllowUsers hex root
  notify: Restart sshd

- name: Créer /tmp et /var/tmp si besoin
  file:
    path: "{{ item }}"
    state: directory
    mode: "1777"
  loop:
    - /tmp
    - /var/tmp

- name: /tmp et /var/tmp en tmpfs
  blockinfile:
    path: /etc/fstab
    marker: "# {mark} ANSIBLE hexmcp tmpfs"
    block: |
      tmpfs /tmp     tmpfs rw,nosuid,nodev,relatime,size=1G,mode=1777 0 0
      tmpfs /var/tmp tmpfs rw,nosuid,nodev,noexec,relatime,size=1G,mode=1777 0 0

- name: Monter /tmp
  command: mount /tmp
  register: mnt_tmp
  changed_when: mnt_tmp.rc == 0
  failed_when: false

- name: Monter /var/tmp
  command: mount /var/tmp
  register: mnt_vartmp
  changed_when: mnt_vartmp.rc == 0
  failed_when: false

- name: sysctl durci
  copy:
    dest: /etc/sysctl.d/99-hexmcp.conf
    content: |
      {% for k,v in sysctl_hardening.items() %}{{ k }} = {{ v }}
      {% endfor %}
  notify: Sysctl reload

- name: Attendre que dpkg/apt se libère
  shell: |
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
          fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
      echo "APT lock présent, attente..."
      sleep 3
    done
  changed_when: false

- name: Mettre à jour le cache APT
  apt:
    update_cache: true
    cache_valid_time: 3600
  environment:
    DEBIAN_FRONTEND: noninteractive

- name: Installer les paquets utiles
  apt:
    name: "{{ item }}"
    state: present
  environment:
    DEBIAN_FRONTEND: noninteractive
  loop:
    - git
    - curl
    - jq
    - python3-pip
    - nmap
    - gobuster
    - sqlmap
    - openvpn
    - nftables
    - auditd
    - tar
    - zip
    - unzip


- name: Télécharger feroxbuster
  get_url:
    url: "https://github.com/epi052/feroxbuster/releases/latest/download/x86_64-linux-feroxbuster.zip"
    dest: /tmp/feroxbuster.zip
    mode: "0644"

- name: Dézipper feroxbuster
  unarchive:
    src: /tmp/feroxbuster.zip
    dest: /usr/local/bin
    remote_src: true

- name: Rendre feroxbuster exécutable
  file:
    path: /usr/local/bin/feroxbuster
    mode: "0755"

- name: Activer auditd
  service: { name: auditd, state: started, enabled: true }

- name: Installer la configuration nftables
  copy:
    dest: /etc/nftables.conf
    mode: "0644"
    content: |
      flush ruleset
      table inet filter {
        chain input {
          type filter hook input priority 0;
          policy drop;
          ct state established,related accept
          iif "lo" accept
          tcp dport 22 accept
          ip protocol icmp accept
          ip6 nexthdr ipv6-icmp accept
        }
        chain forward {
          type filter hook forward priority 0;
          policy drop;
        }
        chain output {
          type filter hook output priority 0;
          policy accept;
        }
      }

- name: Valider la conf nftables
  command: nft -c -f /etc/nftables.conf
  changed_when: false

- name: Appliquer nftables
  shell: "timeout 5s nft -f /etc/nftables.conf || true"
  changed_when: false

- name: Reprendre la connexion SSH
  block:
    - wait_for:
        host: "{{ inventory_hostname }}"
        port: 22
        timeout: 30
      delegate_to: localhost
      become: false
    - meta: reset_connection

- name: Vérifier SSH après nftables
  wait_for:
    host: "{{ inventory_hostname }}"
    port: 22
    timeout: 10
  delegate_to: localhost
  become: false
  register: ssh_check
  failed_when: false

- name: Rollback nftables si SSH cassé
  when: ssh_check.failed
  block:
    - copy:
        dest: /etc/nftables.conf
        content: |
          flush ruleset
          table inet filter {
            chain input { type filter hook input priority 0; policy accept; }
            chain forward { type filter hook forward priority 0; policy accept; }
            chain output { type filter hook output priority 0; policy accept; }
          }
    - command: nft -f /etc/nftables.conf

- name: Activation nftables
  service: { name: nftables, state: started, enabled: true }

EOF

# --- Handlers ---
wf "$PROJECT_DIR/roles/xcp_guest/handlers/main.yml" 0644 <<'EOF'
---
- name: Restart sshd
  service:
    name: ssh
    state: restarted

- name: Reload sysctl
  command: sysctl --system

- name: Restart nftables
  service:
    name: nftables
    state: restarted
EOF

# --- Role htb_vpn ---
wf "$PROJECT_DIR/roles/htb_vpn/tasks/main.yml" 0644 <<'EOF'
---
- name: Configurer OpenVPN HTB
  when: htb_enable | bool
  block:
    - name: Copier profil .ovpn
      copy:
        src: "{{ htb_ovpn_src }}"
        dest: "{{ htb_ovpn_dst }}"
        owner: root
        group: root
        mode: '0600'

    - name: Service systemd htb-vpn
      copy:
        dest: /etc/systemd/system/htb-vpn.service
        mode: '0644'
        content: |
          [Unit]
          Description=OpenVPN HTB
          After=network-online.target
          Wants=network-online.target

          [Service]
          Type=simple
          ExecStart=/usr/sbin/openvpn --config {{ htb_ovpn_dst }}
          Restart=on-failure
          RestartSec=2

          [Install]
          WantedBy=multi-user.target

    - name: Reload systemd
      systemd: { daemon_reload: true }

    - name: Démarrer et activer
      service:
        name: htb-vpn
        state: started
        enabled: true

EOF

# --- Role mcp_install ---
wf "$PROJECT_DIR/roles/mcp_install/tasks/main.yml" 0644 <<'EOF'
---
- name: Créer répertoire MCP
  file:
    path: "{{ mcp_dir }}"
    state: directory
    owner: "{{ mcp_user }}"
    group: "{{ mcp_group }}"
    mode: "0750"

- name: Déployer /etc/hexmcp.env (secrets)
  copy:
    dest: /etc/hexmcp.env
    owner: root
    group: root
    mode: "0600"
    content: |
      {% for k,v in mcp_env.items() %}{{ k }}={{ v }}
      {% endfor %}

- name: Cloner dépôt MCP
  git:
    repo: "{{ mcp_repo_url }}"
    dest: "{{ mcp_dir }}/src"
    update: yes
  become: true
  become_user: "{{ mcp_user }}"

- name: Installer les dépendances Python
  apt:
    name:
      - python3-venv
      - python3-pip
      - ca-certificates
      - unzip
    state: present
    update_cache: true
  environment:
    DEBIAN_FRONTEND: noninteractive

- name: Créer venv MCP
  command: python3 -m venv {{ mcp_dir }}/venv
  args:
    creates: "{{ mcp_dir }}/venv/bin/python3"

- name: Mettre à jour pip dans le venv
  command: "{{ mcp_dir }}/venv/bin/pip install --no-input --upgrade pip setuptools wheel"
  changed_when: false

# Installer requirements.txt si le dépôt en fournit un.
- name: Vérifier si requirements.txt existe
  stat:
    path: "{{ mcp_dir }}/src/requirements.txt"
  register: reqfile

- name: Installer les dépendances du dépôt
  when: reqfile.stat.exists
  command: "{{ mcp_dir }}/venv/bin/pip install --no-input -r {{ mcp_dir }}/src/requirements.txt"
  register: pip_req
  changed_when: "'Successfully installed' in (pip_req.stdout | default('')) or pip_req.rc == 0"

# Service systemd.
- name: Installer le service hexmcp
  copy:
    dest: /etc/systemd/system/hexmcp.service
    mode: "0644"
    content: |
      [Unit]
      Description=HexStrike MCP (isolé)
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=simple
      User={{ mcp_user }}
      Group={{ mcp_group }}
      EnvironmentFile=/etc/hexmcp.env
      WorkingDirectory={{ mcp_dir }}/src
      Environment=PYTHONUNBUFFERED=1
      ExecStart={{ mcp_dir }}/venv/bin/python {{ mcp_dir }}/src/hexstrike_server.py --port {{ mcp_bind_port }}
      Restart=on-failure
      RestartSec=2

      [Install]
      WantedBy=multi-user.target

- name: Reload systemd
  systemd:
    daemon_reload: true

- name: Démarrer et activer hexmcp
  service:
    name: hexmcp
    state: started
    enabled: true

# Dépannage simple des modules Python manquants.
- name: Installer le script de rattrapage Python
  copy:
    dest: /usr/local/bin/hexmcp-autodeps.sh
    mode: "0755"
    owner: root
    group: root
    content: |
      #!/usr/bin/env bash
      set -euo pipefail

      systemctl restart hexmcp || true
      sleep 1

      if systemctl is-active --quiet hexmcp; then
        echo "hexmcp active"
        exit 0
      fi

      logs="$(journalctl -u hexmcp -n 200 --no-pager || true)"

      # Extrait le dernier module manquant : No module named 'X'
      missing="$(printf '%s\n' "$logs" \
        | grep -oE "No module named '[^']+'" \
        | tail -n 1 \
        | sed -E "s/No module named '([^']+)'/\\1/")"

      if [[ -z "${missing:-}" ]]; then
        echo "hexmcp not active and no missing module found"
        echo "$logs"
        exit 2
      fi

      pkg="$missing"
      case "$missing" in
        yaml) pkg="pyyaml" ;;
        Crypto) pkg="pycryptodome" ;;
        PIL) pkg="pillow" ;;
        bs4) pkg="beautifulsoup4" ;;
        OpenSSL) pkg="pyopenssl" ;;
      esac

      echo "Installing missing python dep: import=$missing pip=$pkg"
      {{ mcp_dir }}/venv/bin/pip install --no-input "$pkg"
      exit 1



- name: Relancer hexmcp après installation des dépendances manquantes
  command: /usr/local/bin/hexmcp-autodeps.sh
  register: autodeps
  changed_when: "'Installing missing python dep' in autodeps.stdout"
  retries: 15
  delay: 2
  until: autodeps.rc == 0

EOF

# --- Role mcp_verify ---
wf "$PROJECT_DIR/roles/mcp_verify/tasks/main.yml" 0644 <<'EOF'
---
- name: Attendre que hexmcp soit actif
  command: systemctl is-active hexmcp
  register: svc
  retries: 30
  delay: 2
  until: svc.stdout.strip() == "active"
  changed_when: false

- assert:
    that:
      - svc.stdout.strip() == "active"

- name: MCP écoute local
  command: ss -ltnp
  register: ss_out
  changed_when: false

- name: Vérifier le bind
  assert:
    that: "'{{ mcp_bind_ip }}:{{ mcp_bind_port }}' in ss_out.stdout"

- name: Lire l'utilisateur du service
  shell: "systemctl show -p User --value hexmcp"
  register: svc_user
  changed_when: false

- name: Vérifier que le service n'est pas root
  assert:
    that:
      - svc_user.stdout.strip() != "root"
      - svc_user.stdout.strip() != ""
    fail_msg: "hexmcp tourne en root (User={{ svc_user.stdout.strip() }})"

- name: Récupérer le PID principal du service hexmcp
  command: systemctl show -p MainPID --value hexmcp
  register: hexmcp_pid
  changed_when: false

- name: Récupérer l'utilisateur du PID hexmcp
  command: ps -o user= -p {{ hexmcp_pid.stdout.strip() }}
  register: ps_user
  changed_when: false

- name: Vérifier l'utilisateur du process
  assert:
    that:
      - ps_user.stdout.strip() != "root"
      - ps_user.stdout.strip() == mcp_user
    fail_msg: "hexmcp tourne en {{ ps_user.stdout.strip() }}, attendu {{ mcp_user }}"

- name: Montages sécurisés
  shell: "mount | egrep '/tmp|/var/tmp'"
  register: mounts
  changed_when: false

- name: Vérifier options de montage /tmp et /var/tmp
  shell: |
    mount | egrep ' on /tmp | on /var/tmp '
  register: mounts
  changed_when: false

- name: Vérifier les options de montage
  assert:
    that:
      - "mounts.stdout is search(' on /tmp .*nosuid')"
      - "mounts.stdout is search(' on /tmp .*nodev')"
      - "mounts.stdout is search(' on /var/tmp .*nosuid')"
      - "mounts.stdout is search(' on /var/tmp .*nodev')"

- name: nftables OK
  command: nft list ruleset
  register: nft
  changed_when: false


- name: Afficher le score sécurité systemd
  command: systemd-analyze security hexmcp.service
  register: sec
  changed_when: false

EOF

# --- Role mcp_teardown ---
wf "$PROJECT_DIR/roles/mcp_teardown/tasks/main.yml" 0644 <<'EOF'
---
- name: Détruire via Xen-Orchestra
  when: xcp_driver == 'xo'
  debug:
    msg: "Détruire manuellement la VM"

- name: Détruire via XAPI
  when: xcp_driver == 'xapi'
  community.general.xenserver_guest:
    hostname: "{{ xapi_hostname }}"
    username: "{{ xapi_username }}"
    password: "{{ xapi_password }}"
    name: "{{ hexmcp_vm_name }}"
    state: absent
    force: true
EOF

# --- Collections et usage ---

echo "[ansible] Installation des collections"
( cd "$PROJECT_DIR" && ansible-galaxy collection install -r requirements.yml -f )

cat <<'EONXT'

Projet généré. Points à vérifier avant lancement :

- group_vars/all.yml : mcp_repo_url et éventuelles clés LLM
- htb_ovpn_src : chemin du profil .ovpn côté Deployer si htb_enable=true
- inventories/lab/hosts.ini : régénéré avant le playbook configure/verify

Commandes :
  cd "$PROJECT_DIR"
  ansible-playbook site.yml --tags provision,configure,verify

Destruction :
  ansible-playbook site.yml --tags destroy

SSH invité :
  ssh -i ~/.ssh/HEX_KEY <user>@<vm>
  sudo -s
EONXT

run_terraform(){
  ( cd "$TF_DIR" && terraform init -input=false && terraform apply -auto-approve )
}

run_ansible(){
  wf "$PROJECT_DIR/inventories/lab/hosts.ini" <<EOF
[hexmcp]
${HEXMCP_IP} ansible_user=root ansible_password=${ROOT_PASS} ansible_ssh_private_key_file=/root/.ssh/<redacted> ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'
EOF

  ansible-playbook -i "$PROJECT_DIR/inventories/lab/hosts.ini" "$PROJECT_DIR/site.yml" --tags configure,verify
}
run_destroy(){
  ( cd "$TF_DIR" && terraform destroy -auto-approve )
}

# Lancement automatique.
if [[ "${AUTO_RUN}" == "1" ]]; then
  if [[ -z "$XO_PASS" ]]; then
    echo "[!] XO_PASS vide (export XO_PASS='…')" >&2; exit 1
  fi
  run_terraform
  run_ansible
fi

# Destruction: DESTROY=1 ./bootstrap_hexmcp.sh
if [[ "${DESTROY:-0}" == "1" ]]; then
  run_destroy
  exit 0
fi
