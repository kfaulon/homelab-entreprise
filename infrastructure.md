# Infrastructure Global

Apercu de l'infrastructure Homelab. Pour des raisons principal de couts, beaucoup de systèmes qui meriterais une HA ne l'ont pas (Ex : NAS)

```mermaid
graph TD

Routeur --> OPNsense

OPNsense --> XCPNG1
OPNsense --> XCPNG2
OPNsense --> AX3000
OPNSense --> KaliLinux

XCPNG1 --> K3S
XCPNG1 --> DNS-1
XCPNG1 --> Dev_Game
XCPNG1 --> K3S
XCPNG1 --> Wazuh
XCPNG1 --> XOA-1
XCPNG1 --> NAS
XCPNG1 --> VLAN_HEXSTRIKE
XCPNG1 --> SysReptor
XCPNG1 --> ZABBIX 
XCPNG1 --> Wordpress-1

VLAN_HEXSTRIKE --> HexStrike_Ephemeral

XCPNG2 --> Authentik
XCPNG2 --> DNS-2
XCPNG2 --> Firezone
XCPNG2 --> Deployment
XCPNG2 --> DNS2
XCPNG2 --> Arch
XCPNG2 --> XOA-2
XCPNG2 --> IA-LAB
XCPNG2 --> Wordpress-2 

K3S --> Nextcloud
```

Cette infrastructure est amené à changer selon les besoins (Bastion, DMZ, ...)

# Réseau

La VM ephémère HexStrike, serveur hebergeant un MCP de Pentest Offensif, étant une machine critique et par définition vulnérable (prompt injection pour n'en cité qu'une), est séquestré dans un VLAN par le biais du Firewall. Ainsi, par des règles sricts, la VM Hexstrike n'a qu'une portée extremement limité sur le réseau.


```mermaid
graph TD

OPNsense --> VLANHEXSTRIKE
VLANHEXSTRIKE --> Hexstrike_MCP_Ephemeral
```

# Sécurité

Gestion des certificat HTTPS via autorité local OPNSense.
Authentification au Web locaux uniquement via HTTPS et principalement via Authentik (SSO, authentification Fingerprint et mobile), serveur IdP du réseau.

 ![Architecture Homelab](docs/images/administration_auth_2.png)

VM durcies par connexion autorisé via un seul utilisateur, filtrage via Firewall (pour les flux y passant) + regles iptables / firewalld, interdiction sudo, ...

# Deploiements

 ![Dossier Deployment](docs/images/small_list_ansibles.png)

 Le déploiement de VM se fait soit :
 - En manuel, avec import de template VM dans l'Hyperviseur, puis lancement d'ansibles tel que le [bootstrap_local](docs/bootstrap_local.sh), qui installe un utilisateur wheel, ainsi que sa clé SSH, puis des playbook hardenings d'utilisateurs et de configurations specifique.
 - En déploiement automatisé via Terraform, piloté par un [.sh](docs/bootstrap_hexstrike.sh) pour l'installation / destruction d'une VM MCP_Hexstrike.

 Versionning avec Gitea
  ![Gitea](docs/images/gitea.png)


# Virtualisation

- Plusieurs docker tournent sur les machines, en particulier Gitea, Bloodhound (sur KaliLinux )
- Une VM Kubernetes K3S est utilisé a fin d'experimentation et pour la gestion de Nextcloud, Money, Semaphore UI, et prochainement un stack Prometheus + Grafana.

# Supervision

- Supervision des status et des alertes Hardware via Zabbix
![Dashboard Zabbix](docs/images/zabbix_dashboard.png)
- Developpement en cours de la supervision via Wazuh (SIEM)


