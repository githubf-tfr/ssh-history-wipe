# ssh-history-wipe — version Ansible

Équivalent Ansible d'`install.sh` (voir `../spec.md`). Même
comportement, mêmes cibles : dépose le script de nettoyage avec les droits
`root:root` mode `750`, ajoute la ligne `pam_exec` dans le PAM stack de
`sshd` uniquement si elle n'y est pas déjà (idempotent via `lineinfile`).

Le rôle est **autonome** : le contenu du script est écrit directement dans
`roles/ssh_history_wipe/tasks/main.yml` (`copy: content: |`), pas copié
depuis un fichier `.sh` externe ni un symlink. En contrepartie, ce contenu
inline peut diverger silencieusement de `files/wipe-history-on-logout.sh` à
la racine (utilisé par `install.sh`) — `tests/test_ansible_sync.sh` extrait
ce bloc et échoue s'il n'est plus identique : à relancer après toute
modification de l'un des deux.

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
