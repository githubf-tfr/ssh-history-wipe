# ssh-history-wipe — version Ansible

Équivalent Ansible d'`install.sh` (voir `../spec.md`). Même
comportement, mêmes cibles : dépose le script de nettoyage avec les droits
`root:root` mode `750`, ajoute la ligne `pam_exec` dans le PAM stack de
`sshd` uniquement si elle n'y est pas déjà (idempotent via `lineinfile`).

Le rôle est **autonome** : `roles/ssh_history_wipe/files/wipe-history-on-logout.sh`
est une vraie copie du script (pas un symlink vers `../files/`), pour que le
rôle reste utilisable seul (extrait, publié, cloné sous Windows où les
symlinks Git posent souvent problème). En contrepartie, les deux copies
peuvent diverger silencieusement — `tests/test_ansible_sync.sh` échoue si
ce fichier n'est plus identique à `files/wipe-history-on-logout.sh` à la
racine du dépôt : à relancer après toute modification de l'un des deux.

## Usage

```bash
ansible-playbook -i <inventaire> playbook.yml --ask-become-pass
```

## Variables (`roles/ssh_history_wipe/defaults/main.yml`)

| Variable                             | Défaut                                   |
| ------------------------------------- | ----------------------------------------- |
| `ssh_history_wipe_script_dest`        | `/usr/local/sbin/wipe-history-on-logout.sh` |
| `ssh_history_wipe_pam_sshd_file`      | `/etc/pam.d/sshd`                         |

Surchargeables via `-e` ou `group_vars`, pour rediriger vers un bac à sable
en test — équivalent des variables d'environnement `SCRIPT_DEST` /
`PAM_SSHD_FILE` d'`install.sh`.

## Hors périmètre (identique à `install.sh`)

Pas de redémarrage de `sshd` — PAM est relu à chaque nouvelle session, le
mécanisme est actif dès la prochaine connexion.
