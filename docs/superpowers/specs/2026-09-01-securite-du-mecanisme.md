# Spec — sécurité du mécanisme de nettoyage d'historique

## Contexte et problème

**Qui** : un utilisateur local non privilégié disposant d'un compte SSH — exactement la
population que le mécanisme est censé couvrir. **Avec quoi** : son propre
`~/.bash_history`, qu'il contrôle entièrement ; avant de se déconnecter, il le remplace
par un lien symbolique vers un fichier système appartenant à root (ex. `/etc/shadow`).
**Ce qu'il obtient aujourd'hui** : à sa déconnexion, le hook PAM s'exécute en pratique
avec euid=0 (l'option `seteuid` de `pam_exec` n'abaisse pas les privilèges de façon
fiable) ; la troncature suit le lien et vide le fichier système, puis le `chown` en
transfère la propriété à l'attaquant. Un mécanisme de confidentialité devient une
escalade de privilèges : un non-root fait tronquer puis s'approprier n'importe quel
fichier du système par root.

Toute défense « vérifier le chemin puis agir » sous root est une course (TOCTOU). La
protection exigée est **par construction** : aucune écriture n'a lieu tant que le
processus détient un privilège que le compte cible ne possède pas.

## Comportement attendu

Principe directeur, opposable à tous les cas ci-dessous : **la troncature s'exécute
avec exactement les droits du compte qui se déconnecte — jamais plus**. Le pire cas
atteignable par un compte est donc de tronquer un fichier qu'il pouvait déjà écrire
lui-même : aucun privilège gagné, quelle que soit la ruse (symlink, hardlink, course).

### Cas par cas

Chaque cas décrit l'état observable du système de fichiers après fermeture d'une
session SSH (ou après l'événement PAM indiqué). « Ne doit surtout pas » est aussi
normatif que « fait ».

1. **Historique normal d'un compte ordinaire.** Après déconnexion :
   `~/.bash_history` existe, est vide (taille 0) et appartient au compte.
   Ne doit surtout pas : supprimer le fichier, toucher quoi que ce soit d'autre dans
   le home, changer le propriétaire vers root.
2. **`~/.bash_history` remplacé par un lien symbolique vers un fichier appartenant à
   root.** Le fichier pointé reste **intact** : contenu, taille et propriétaire
   inchangés. Le lien reste en place.
   Ne doit surtout pas : suivre le lien, tronquer la cible, en transférer la
   propriété, supprimer le lien.
3. **`~/.bash_history` absent.** Rien n'est créé — un compte sans historique n'a rien
   à nettoyer. Le home reste identique.
   Ne doit surtout pas : créer le fichier (a fortiori appartenant à root).
4. **`~/.bash_history` remplacé par une FIFO.** La FIFO est laissée en place,
   intacte ; la déconnexion n'est pas retardée au-delà de la borne du contrat
   (5 secondes, voir « Contrat du script »).
   Ne doit surtout pas : écrire dans la FIFO, rester bloqué sur son ouverture,
   retarder ou bloquer la fermeture de session.
5. **Fermeture de session de root lui-même.** `/root/.bash_history` est tronqué
   (existe, vide, appartient à root) : root nettoie son propre home, aucune escalade
   possible.
   Ne doit surtout pas : être exempté du nettoyage.
6. **`PAM_USER` inconnu de `getent`.** No-op silencieux, succès.
   Ne doit surtout pas : écrire quoi que ce soit, échouer, bloquer la fermeture.
7. **`PAM_TYPE` d'ouverture de session.** No-op silencieux : aucun nettoyage à la
   connexion.
   Ne doit surtout pas : tronquer ou créer `~/.bash_history` au login (un historique
   créé root au login verrouillerait l'écriture d'historique pour toute la session).

Cas limites rattachés : entrée `getent` présente mais uid vide → no-op silencieux ;
champ home vide ou ne désignant pas un répertoire existant → no-op silencieux. Dans
tous les cas, code de retour 0.

### L'échec silencieux est un mode d'échec de première classe

Le mécanisme retourne **toujours 0** et n'écrit **rien** sur ses sorties : c'est le
prix de l'invariant « ne jamais bloquer une déconnexion ». La contrepartie est qu'un
mécanisme inopérant est indiscernable d'un mécanisme sain par son code de retour — un
script installé avec un mode qui empêche sa ré-exécution après abaissement de
privilèges ne nettoierait plus jamais rien, sur tous les comptes non-root, sans
qu'aucune commande n'échoue. En conséquence : **aucun critère d'acceptation de cette
spec ne peut se contenter d'un code de retour**. Chaque critère fonctionnel s'asserte
sur l'état observable du système de fichiers — contenu, taille, propriétaire, nature
du fichier, horodatage — jamais sur le succès de la commande.

### Invariants du projet (inchangés, opposables à cette spec)

- Le hook PAM `session optional` ne bloque ni ne retarde jamais une déconnexion SSH,
  quel que soit le sort du script (absent, cassé, expiré, dépendance manquante).
- Troncature, jamais suppression : le fichier n'est jamais `rm`.
- Aucun effet sur auditd, syslog, journalctl — jamais altérés, quelle que soit la
  situation.
- AlmaLinux 8+ uniquement, bash uniquement ; les seules commandes requises
  appartiennent au socle de la distribution.
- Déploiement idempotent : chaque voie est rejouable sans effet de bord, l'état est
  détecté sur le système réel.
- Non contournable par les dotfiles : le point d'accroche reste PAM.

## Contrat du script

Le script installé est `/usr/local/sbin/wipe-history-on-logout.sh`, propriété
`root:root`, mode **`0755`**, **non setuid**. Le mode `0755` fait partie du contrat :
le compte cible doit pouvoir exécuter le script après abaissement de privilèges — un
mode plus restrictif rend le mécanisme silencieusement inopérant (mode d'échec de
première classe ci-dessus).

Trois surfaces publiques :

### `truncate_history <home_dir>` (fonction, script sourcé)

Sourceable et testable sans root ni PAM ; signature inchangée.

- `<home_dir>` absent, vide ou non-répertoire → aucune écriture, retour 0.
- `<home_dir>/.bash_history` absent, lien symbolique, ou tout sauf un fichier
  régulier (FIFO, répertoire, socket) → laissé intact, aucune création, retour 0.
  Ce garde est un **filet anti-hors-cible best-effort, explicitement pas une
  frontière de sécurité** : la frontière est l'abaissement de privilèges en amont ;
  même contourné par une course, le pire cas est la troncature d'un fichier que le
  compte pouvait déjà écrire.
- Fichier régulier → tronqué en place (taille 0), jamais supprimé, propriétaire
  inchangé. Un refus d'ouverture (droits insuffisants) est absorbé en silence.
- Retour : toujours 0.

### Invocation `--wipe <home_dir>` (exécution directe)

Appelle `truncate_history <home_dir>` puis sort en 0, sans filtre PAM. C'est le
**seul** chemin qui touche le fichier, et il s'exécute avec les seuls droits de son
appelant : le script n'étant pas setuid, un utilisateur qui l'invoque directement ne
peut rien tronquer qu'il ne pouvait déjà tronquer lui-même.

### `main` (exécution directe par PAM, sans argument)

Ordre d'évaluation, chaque sortie en code 0 :

1. `PAM_TYPE` différent de `close_session` (ou absent) → ne fait rien.
2. `PAM_USER` vide ou absent → ne fait rien.
3. Résolution du compte en une seule lecture `getent passwd` : home, uid, gid.
   Entrée absente ou uid vide → ne fait rien.
4. Dispatch selon l'euid courant :
   - **euid = uid cible** (abaissement déjà effectif, ou root fermant sa propre
     session) : ré-exécute le script en `--wipe <home>`, borné à **5 secondes**.
   - **euid = 0 et uid cible ≠ 0** (cas réel aujourd'hui) : abaisse uid et gid —
     réels et effectifs — et les groupes supplémentaires vers ceux du compte cible,
     **puis** ré-exécute le script en `--wipe <home>`, le tout borné à 5 secondes.
     L'abaissement précède toute ouverture de fichier : c'est la frontière de
     sécurité.
   - **euid ≠ 0 et ≠ uid cible** (état anormal) : ne fait rien.
5. Code de retour de `main` : **toujours 0**, quel que soit le sort de la commande
   abaissée (échec, dépassement de borne, outil manquant). Aucune sortie sur
   stdout/stderr en fonctionnement nominal.

La borne de 5 secondes garantit qu'une cible piégée qui bloquerait une ouverture
(FIFO sans lecteur) ne retarde jamais la fermeture de session.

La ligne PAM reste strictement inchangée :
`session optional pam_exec.so seteuid /usr/local/sbin/wipe-history-on-logout.sh`.
`seteuid`, inopérant mais inoffensif, est toléré parce que le script **ne suppose
plus** qu'il abaisse quoi que ce soit.

## Déploiement et convergence

Trois voies, un même artefact : le corps du script (identique dans ses trois
exemplaires), le mode `0755` `root:root`, et la ligne PAM inchangée ajoutée seulement
si absente.

| Voie | Corps du script | Mode | Ligne PAM |
|---|---|---|---|
| `install.sh` (template de VM au build du golden image, et rattrapage sur VM existante) | copié depuis `files/wipe-history-on-logout.sh` | `0755` posé inconditionnellement | ajoutée si absente, jamais dupliquée |
| Rôle Ansible `ssh_history_wipe` | `src:` vers `files/wipe-history-on-logout.sh` — suit la source de vérité | `mode: "0755"` | idem, via `lineinfile` |
| Rôle Ansible `ssh_history_wipe_standalone` | inline dans `tasks/main.yml`, identique au canonique (non-dérive vérifiée par test) | `mode: "0755"` | idem |

**Convergence sans étape manuelle.** Une machine déjà installée porte l'ancien script
en `0750`. Le mode et le contenu étant posés par la même opération dans chaque voie,
un simple replay (`install.sh` rejoué, ou playbook réappliqué) converge contenu **et**
mode en une exécution ; aucune machine ne peut rester dans l'état mixte « nouveau
script + ancien mode ». La ligne PAM existante est détectée et jamais dupliquée.

La documentation qui mentionne le mode (`ansible/README.md`, runbook
`docs/manual-verification.md`) est mise à jour en cohérence (`750` → `755`).

## Critères d'acceptation

Deux niveaux : **[auto]** — test automatisé du dépôt, bash pur, sans framework, sans
root, sans PAM, sans second compte ; **[runbook]** — `docs/manual-verification.md`,
vrai sshd/PAM et second compte, exécuté par un humain (une automatisation ultérieure
de ces checks est un choix de plan, pas de spec).

Règle transversale, opposable à chaque critère : **aucun critère ne s'asserte sur un
code de retour ou une absence d'erreur** — le mécanisme rend toujours 0 en silence.
Chaque assertion porte sur l'état observable du système de fichiers.

1. **[auto]** `truncate_history` sur un home dont `.bash_history` est un lien
   symbolique vers un fichier témoin hors du home : le témoin est **intact**
   (contenu identique) et le lien est toujours en place, non suivi.
2. **[auto] Le chemin abaissé s'exécute de bout en bout — critère central de cette
   spec.** Propriété exigée du critère : il ne peut **pas** être satisfait par un
   test qui appelle `truncate_history` ou `main` autrement que comme PAM le fait. Le
   test exécute le **fichier script directement** (pas sourcé), avec `PAM_TYPE` de
   fermeture de session et `PAM_USER` résolu vers un home de test portant un
   `.bash_history` non vide, et asserte que ce fichier est **vide après l'appel**.
   Ce critère traverse le dispatch, la ré-exécution `--wipe` et l'exécutabilité du
   fichier : il doit échouer si l'un des trois se casse — il aurait détecté un mode
   rendant le chemin abaissé inexécutable (mécanisme silencieusement inopérant). La
   branche d'abaissement effectif depuis euid=0 lui échappe (elle exige root) : elle
   est couverte par le critère 13.
3. **[auto]** `truncate_history` sur un home dont `.bash_history` est une FIFO : la
   FIFO est toujours en place, toujours une FIFO, et l'appel rend la main (pas de
   blocage).
4. **[auto]** `truncate_history` sur un home sans `.bash_history` : aucun fichier
   créé, le home est inchangé.
5. **[auto]** `main` avec `PAM_TYPE` d'ouverture de session : aucune tentative de
   nettoyage (aucune résolution de compte, aucun accès au home).
6. **[auto]** `main` avec `PAM_USER` inconnu de la résolution de compte : aucune
   écriture nulle part.
7. **[auto]** Les **trois** voies d'installation posent le mode `0755` :
   `install.sh` vérifié par exécution redirigée vers un bac à sable (`SCRIPT_DEST`,
   `PAM_SSHD_FILE`), les deux rôles vérifiés sur leur déclaration de mode.
8. **[auto]** **Convergence depuis `0750`** : une cible pré-existante en mode `0750`
   avec l'ancien corps, après un simple replay d'`install.sh`, porte le nouveau
   corps **et** le mode `0755` — c'est la propriété qui protège le parc existant.
9. **[auto]** Le corps inline du rôle standalone est identique octet pour octet au
   script canonique (non-dérive).
10. **[auto]** `install.sh` rejoué deux fois : la ligne PAM attendue est présente
    exactement une fois, à l'identique.
11. **[runbook] Preuve de fermeture de la faille.** Depuis un compte non-root :
    `~/.bash_history` remplacé par un lien symbolique vers un fichier appartenant à
    root, session SSH réelle ouverte puis fermée. Le fichier pointé est **intact**
    (contenu et taille inchangés) et son **propriétaire inchangé** (aucun transfert).
12. **[runbook]** `~/.bash_history` remplacé par une FIFO, session SSH réelle
    fermée : la déconnexion n'est pas retardée au-delà de la borne de 5 secondes, la
    FIFO est laissée en place.
13. **[runbook] Non-régression fonctionnelle.** Session SSH réelle d'un compte
    non-root, commandes tapées, historique forcé sur disque, déconnexion :
    `~/.bash_history` **existe, est vide, appartient au compte** — preuve en
    conditions réelles que la branche d'abaissement depuis euid=0 s'exécute sous
    l'identité du compte et tronque.
14. **[runbook]** Session SSH réelle de root : `/root/.bash_history` existe, vide,
    appartient à root.
15. **[runbook]** Non-régression audit : auditd et journalctl continuent
    d'enregistrer normalement pendant et après les checks ci-dessus ; aucun journal
    vidé ni altéré.
16. **[runbook]** Machine convergée par replay d'un rôle Ansible depuis l'état
    `0750` : script en `0755` avec le nouveau corps après réapplication du playbook,
    sans étape manuelle.

## Hors périmètre

- **Logs et audit centralisés** (auditd, syslog, journalctl) : jamais altérés, hors
  champ du mécanisme ; seule leur non-régression est vérifiée (critère 15).
- **Autres shells que bash** (zsh, fish…) et **autres distributions qu'AlmaLinux 8+**.
- **Filet de sécurité à l'ouverture de session** et traitement de la **coupure
  brutale** au-delà du comportement accepté (nettoyage différé jusqu'à détection de
  la connexion morte) : décisions actées, pas des gaps.
- **Modification de la ligne PAM** (retrait ou remplacement de `seteuid`) : la ligne
  reste inchangée pour ne pas créer de dérive dépôt↔parc.
- **Protection contre un attaquant déjà root** : root peut par définition tout faire ;
  le modèle de menace s'arrête au compte local non privilégié.
- **Automatisation (Docker ou autre) des checks du runbook** : choix de plan, pas de
  spec ; le niveau normatif de ces preuves reste le runbook manuel.
