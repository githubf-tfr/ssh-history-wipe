# ssh-history-wipe — Effacement automatique de l'historique shell à la déconnexion SSH

**Date :** 2026-07-11
**Statut :** Design validé — prêt pour plan d'implémentation

## 1. Objectif

Effacer automatiquement l'historique des commandes bash (`~/.bash_history`) de
chaque compte à la fermeture de sa session SSH, sur des serveurs **AlmaLinux
8+**, sans qu'aucune intervention manuelle de l'administrateur ne soit
nécessaire après la mise en place initiale.

**Contexte et portée de sécurité :** l'administrateur du parc met en place ce
mécanisme sur ses propres serveurs dans un but de confidentialité/durcissement
— éviter que des secrets tapés en ligne de commande (mots de passe, tokens,
clés) ne restent lisibles dans l'historique local d'un compte. Ce mécanisme
**n'a aucun effet sur les journaux d'audit centralisés** (auditd, syslog
distant, journalctl, etc.) : ceux-ci sont hors périmètre et ne doivent pas être
altérés.

## 2. Principes directeurs

- **Non contournable par un utilisateur non-root.** Le mécanisme ne doit pas
  dépendre des dotfiles de l'utilisateur (`~/.bashrc`) : un utilisateur ne
  doit pas pouvoir le désactiver en éditant ses propres fichiers.
- **Ne jamais bloquer une déconnexion.** Une erreur du mécanisme de nettoyage
  ne doit jamais empêcher ou retarder la fermeture normale d'une session SSH,
  ni verrouiller un compte.
- **Uniforme sur tous les comptes**, y compris root, sans configuration par
  compte.
- **Ne touche jamais aux logs/audit.** Seul l'historique shell local est
  concerné.
- **YAGNI.** Un seul shell (bash) et une seule distribution cible
  (AlmaLinux 8+) ; pas de généralisation prématurée à d'autres shells ou
  distributions.

## 3. Mécanisme

Le nettoyage est déclenché par un hook **PAM** (`pam_exec`) sur l'étape
**`session close`** de la pile PAM de `sshd` — indépendant du shell et de ses
fichiers de configuration.

```
/etc/pam.d/sshd
    session optional pam_exec.so seteuid /usr/local/sbin/wipe-history-on-logout.sh
```

- **`optional`** : si le script échoue, la session se ferme normalement quand
  même — aucun risque de bloquer une déconnexion ou de verrouiller un compte.
- **`seteuid`** : le script s'exécute avec les droits de l'utilisateur qui se
  déconnecte, jamais avec des privilèges root sur les fichiers d'un autre
  compte.
- Le script (`/usr/local/sbin/wipe-history-on-logout.sh`, root:root, mode
  `750`) résout le `$HOME` du compte via `$PAM_USER` et **tronque**
  `~/.bash_history` (pas de suppression du fichier, pour ne pas perturber des
  permissions ou une surveillance d'inode existante). Si le `$HOME` n'existe
  pas ou n'est pas accessible, le script sort silencieusement en succès.

### Comportement pendant la session

L'historique reste actif normalement pendant la session (confort standard :
flèche haut, `Ctrl+R`) ; le nettoyage n'intervient qu'à la fermeture.

### Comportement sur coupure brutale

Sur une coupure réseau brutale ou un `kill -9`, la fermeture de session PAM
n'est déclenchée qu'au moment où `sshd` détecte que la connexion est morte
(timeouts TCP / `ClientAliveInterval`), pas instantanément. Le nettoyage a
donc lieu **avec un délai possible, mais pas manqué** — ce comportement est
accepté tel quel pour ce projet (pas de filet de sécurité supplémentaire au
moment de l'ouverture de session).

## 4. Déploiement

Le même artefact (script + ligne PAM) est appliqué par deux voies
complémentaires :

### 4.1 Template de VM (méthode principale, pour les VMs futures)

Le script d'installation (`install.sh`, section 4.2) est exécuté **une fois,
pendant la construction du golden image / template de VM**, avant sa
conversion en template. Toute VM clonée à partir de ce template a le
mécanisme actif dès son premier démarrage, sans aucune étape de
post-provisioning.

### 4.2 `install.sh` (rattrapage sur les VMs existantes)

Script shell **idempotent**, à exécuter en root sur chaque serveur — soit
localement, soit à distance via SSH (ex. `ssh root@host 'bash -s' <
install.sh`) — pour mettre à niveau les VMs AlmaLinux existantes qui n'ont pas
été créées à partir du template mis à jour.

Le script :
1. Dépose `/usr/local/sbin/wipe-history-on-logout.sh` avec les droits
   `root:root`, mode `750`.
2. Ajoute la ligne `session optional pam_exec.so seteuid
   /usr/local/sbin/wipe-history-on-logout.sh` dans `/etc/pam.d/sshd`,
   **uniquement si elle n'y est pas déjà** (pas de doublon en cas de
   ré-exécution).
3. Ne redémarre pas `sshd` : PAM est relu à chaque nouvelle session, donc le
   mécanisme est actif dès la prochaine connexion.

*(Un rôle Ansible équivalent est envisagé mais mis en standby — hors
périmètre de ce projet pour l'instant.)*

## 5. Gestion d'erreurs

- Script introuvable/illisible, `$HOME` absent ou non accessible : sortie
  silencieuse en succès (code retour 0), aucun impact sur la session.
- `pam_exec` en mode `optional` : un échec du script n'empêche jamais la
  fermeture de session.
- `install.sh` est conçu pour être ré-exécuté sans effet de bord
  (idempotence).

## 6. Tests

- **Nettoyage effectif** : se connecter en SSH sous un compte de test, taper
  des commandes, se déconnecter, vérifier que `~/.bash_history` est vide.
- **Compte root** : même vérification pour root.
- **Non-blocage** : simuler un échec du script (ex. permissions), vérifier
  que la déconnexion SSH reste normale.
- **Idempotence de `install.sh`** : l'exécuter deux fois de suite, vérifier
  l'absence de doublon dans `/etc/pam.d/sshd` et l'absence d'erreur.
- **Coupure brutale** : couper la connexion réseau brutalement, vérifier que
  `~/.bash_history` est bien vidé après le délai de détection par `sshd`
  (comportement attendu, documenté en section 3, pas un bug).
- **Non-régression audit** : vérifier qu'aucun log d'audit/syslog n'est
  altéré par le mécanisme.

## 7. Hors périmètre

- Autres shells que bash (zsh, fish, etc.).
- Autres distributions que AlmaLinux 8+.
- Rôle Ansible (mis en standby, à reprendre plus tard si besoin).
- Filet de sécurité à l'ouverture de session (nettoyage préventif en plus de
  celui à la fermeture) — coupure brutale traitée comme délai accepté, pas
  comme un cas à corriger.
- Toute altération des logs/audit centralisés.
