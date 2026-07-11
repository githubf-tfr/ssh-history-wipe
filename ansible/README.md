# ssh-history-wipe — versions Ansible

Équivalent Ansible d'`install.sh` (voir `../spec.md`). Même
comportement, mêmes cibles : dépose le script de nettoyage avec les droits
`root:root` mode `750`, ajoute la ligne `pam_exec` dans le PAM stack de
`sshd` uniquement si elle n'y est pas déjà (idempotent via `lineinfile`).

Deux rôles au choix, même comportement final, compromis différent :

## `ssh_history_wipe` — via le script source (`playbook.yml`)

```bash
ansible-playbook -i <inventaire> playbook.yml --ask-become-pass
```

La tâche `copy` référence `files/wipe-history-on-logout.sh` directement
(`src: "{{ playbook_dir }}/../files/wipe-history-on-logout.sh"`) — une seule
source, partagée avec `install.sh`, jamais de contenu dupliqué. Nécessite
que le rôle reste utilisé depuis ce dépôt (pas extractible tout seul).

## `ssh_history_wipe_standalone` — autonome (`playbook-standalone.yml`)

```bash
ansible-playbook -i <inventaire> playbook-standalone.yml --ask-become-pass
```

Le contenu du script est écrit directement dans
`roles/ssh_history_wipe_standalone/tasks/main.yml` (`copy: content: |`) —
aucune dépendance à un fichier externe, le rôle est extractible/publiable
seul. En contrepartie, ce contenu inline peut diverger silencieusement de
`files/wipe-history-on-logout.sh` — `tests/test_ansible_sync.sh` extrait ce
bloc et échoue s'il n'est plus identique : à relancer après toute
modification de l'un des deux.

## Variables (`defaults/main.yml` de chaque rôle)

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
