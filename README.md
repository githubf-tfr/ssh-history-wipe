# ssh-history-wipe

Efface automatiquement `~/.bash_history` de chaque compte à la fermeture de
sa session SSH, sur des serveurs **AlmaLinux 8+**, sans intervention
manuelle après la mise en place initiale.

**But** : confidentialité/durcissement — éviter que des secrets tapés en
ligne de commande (mots de passe, tokens, clés) ne restent lisibles dans
l'historique local d'un compte. **N'a aucun effet sur les logs/audit
centralisés** (auditd, syslog, journalctl) : hors périmètre, jamais
altérés.

Cible : AlmaLinux 8+ uniquement, bash uniquement, tous les comptes y
compris root, sans configuration par compte.

## Mécanisme

Hook PAM (`pam_exec`) sur l'étape `session close` de la pile PAM de
`sshd` — indépendant du shell et de ses dotfiles, donc non contournable
par un utilisateur non-root qui éditerait son `~/.bashrc`.

```
/etc/pam.d/sshd
    session optional pam_exec.so seteuid /usr/local/sbin/wipe-history-on-logout.sh
```

- `optional` : un échec du script ne bloque/retarde jamais une
  déconnexion SSH ni ne verrouille un compte.
- `seteuid` : le script tourne avec les droits du compte qui se
  déconnecte.
- Le script **tronque** `~/.bash_history` (jamais de suppression du
  fichier).

Sur une coupure réseau brutale (`kill -9`, câble débranché), le nettoyage
n'a lieu qu'au moment où `sshd` détecte la connexion morte (timeouts
`ClientAliveInterval`) — délai possible, mais jamais manqué. C'est un
comportement accepté, pas un défaut à corriger.

Détail complet du design : [`spec.md`](spec.md). Plan d'implémentation
d'origine : [`plan.md`](plan.md).

## Structure du dépôt

```
ssh-history-wipe/
├── files/
│   └── wipe-history-on-logout.sh   # script PAM-exec : truncate_history() + main()
├── install.sh                      # installeur shell idempotent
├── ansible/                        # deux rôles Ansible équivalents à install.sh
│   ├── playbook.yml                 # via le script canonique (files/), pas de copie
│   ├── playbook-standalone.yml      # rôle autonome, script inline dans la tâche
│   └── roles/
│       ├── ssh_history_wipe/
│       └── ssh_history_wipe_standalone/
├── tests/
│   ├── test_wipe_history_on_logout.sh
│   ├── test_install.sh
│   ├── test_ansible_sync.sh        # détecte toute dérive du rôle autonome
│   └── docker/                     # automatisation des checks réels (sshd/PAM) via Docker
└── docs/
    └── manual-verification.md      # runbook des checks nécessitant un vrai sshd/PAM
```

## Déploiement

Deux voies, même artefact (script + ligne PAM) :

1. **Template de VM** (méthode principale, VMs futures) : `install.sh`
   exécuté une fois pendant la construction du golden image, avant sa
   conversion en template. Toute VM clonée a le mécanisme actif dès le
   premier boot.
2. **Rattrapage sur VMs existantes** : `install.sh` exécuté en root,
   localement ou à distance par SSH, sur les VMs AlmaLinux non issues du
   template à jour. Idempotent — ré-exécutable sans dupliquer la ligne
   PAM.

### Installeur shell

```bash
sudo bash install.sh
```

Chemins cibles surchargeables via variables d'environnement (défauts de
prod sinon) :

```bash
SCRIPT_DEST=/usr/local/sbin/wipe-history-on-logout.sh \
PAM_SSHD_FILE=/etc/pam.d/sshd \
sudo -E bash install.sh
```

À distance :

```bash
ssh root@host 'bash -s' < install.sh
```

### Rôles Ansible

Deux rôles équivalents fonctionnellement, compromis différent :

```bash
# via le script canonique (files/wipe-history-on-logout.sh), pas de copie
ansible-playbook -i <inventaire> ansible/playbook.yml --ask-become-pass

# rôle autonome (script inline dans la tâche, aucune dépendance externe)
ansible-playbook -i <inventaire> ansible/playbook-standalone.yml --ask-become-pass
```

Le premier lit `files/wipe-history-on-logout.sh` directement à l'exécution
(source unique, mais le rôle doit rester dans ce dépôt). Le second embarque
le script dans `tasks/main.yml` (extractible/publiable seul, mais
`tests/test_ansible_sync.sh` doit être relancé après toute modification du
script pour détecter une divergence).

Voir [`ansible/README.md`](ansible/README.md) pour le détail et les
variables disponibles.

## Tests

### Tests unitaires (bash pur, sans dépendance)

```bash
bash tests/test_wipe_history_on_logout.sh
bash tests/test_install.sh
```

Couvrent `truncate_history`/`main` (script de nettoyage, sans PAM ni
utilisateur système réel) et l'idempotence d'`install.sh` (chemins
redirigés vers un bac à sable).

### Vérification via Docker (checks avec un vrai sshd/PAM)

```bash
bash tests/docker/run-docker-verification.sh
```

Construit une image AlmaLinux 8 avec `sshd` + PAM, y applique
`install.sh`, et fait de vraies connexions SSH pour valider : artefacts
d'installation, nettoyage à la déconnexion (compte non-root et root),
non-blocage sur script cassé, idempotence d'`install.sh`, et nettoyage
sur coupure brutale (client gelé, détection via `ClientAliveInterval`).
Nécessite seulement un daemon Docker local, pas de VM/host réel.

Ne couvre **pas** la non-régression audit/logs : `auditd` a besoin d'un
accès au netlink d'audit du noyau et `journalctl` a besoin de systemd,
ni l'un ni l'autre n'étant significativement disponibles en conteneur.

### Vérification des rôles Ansible via Docker

```bash
bash tests/docker/run-ansible-docker-verification.sh playbook.yml
bash tests/docker/run-ansible-docker-verification.sh playbook-standalone.yml
```

Provisionne un conteneur AlmaLinux 8 **nu** (rien de préinstallé) depuis
l'hôte, via une vraie connexion SSH, avec le rôle Ansible demandé — comme
en production, pas de mécanisme déjà présent dans l'image. Vérifie les
artefacts, la ré-application idempotente (`changed=0`), et fait une vraie
session SSH interactive pour prouver que l'historique est absent avant
connexion et nettoyé après déconnexion normale (compte non-root et root).

### Runbook manuel (checks nécessitant un vrai host)

[`docs/manual-verification.md`](docs/manual-verification.md) — couvre les
items du plan qui exigent un vrai host AlmaLinux (non-régression
audit/logs notamment), en complément des checks automatisés ci-dessus.

## Contraintes

- AlmaLinux 8+ uniquement, bash uniquement.
- Aucune altération des logs/audit centralisés.
- Ne bloque/retarde jamais une fermeture de session SSH.
- `install.sh` et les deux rôles Ansible restent idempotents.

## Hors périmètre

- Autres shells que bash (zsh, fish...).
- Autres distributions que AlmaLinux 8+.
- Filet de sécurité à l'ouverture de session (nettoyage préventif en plus
  de celui à la fermeture) — la coupure brutale est traitée comme un
  délai accepté, pas comme un cas à corriger.
