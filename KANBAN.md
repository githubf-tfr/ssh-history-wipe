# KANBAN — ssh-history-wipe

Journal daté du repo. Le *comment* générique est dans `README.md`, les conventions
dans `CLAUDE.md` ; ici, l'avancement, les décisions et les pièges rencontrés.
Tenu à la main.

## À faire

Constats hors thème remontés par le cycle auto-update du 2026-09-01 (thème gelé :
sécurité du mécanisme). Non traités par ce cycle.

- **Idempotence de l'installeur** — `install.sh:14` : `grep -qF` matche en sous-chaîne, donc
  une ligne PAM commentée satisfait le test et le hook n'est jamais réactivé en rattrapage,
  silencieusement.
- **Test de non-dérive Ansible cassé** — `tests/test_ansible_sync.sh:31` : dépend de PyYAML
  alors que la doc promet des tests bash pur sans dépendance externe ; échoue aujourd'hui
  avec un message indiscernable d'une vraie divergence.
- **Dérive non couverte entre les trois variantes de déploiement** — la ligne PAM et le
  propriétaire ne sont couverts par aucun test de cohérence. Le corps du script inline et le
  mode le sont désormais (cycle du 2026-09-01).
- **`CLAUDE.md:70` déclare le rôle Ansible hors scope** alors que `ansible/` porte deux rôles
  livrés, testés et documentés ; même contradiction dans `spec.md:114` et `:145`.
- **Section Structure de `CLAUDE.md` périmée** — ignore `ansible/`, `tests/docker/`,
  `test_ansible_sync.sh`, `spec.md`, `plan.md`, et affirme à tort que `truncate_history` est
  le seul point testable sans root.
- **`CLAUDE.md` gitignoré par un `.gitignore` non commité** — un clone du remote n'a ni l'un
  ni l'autre : les invariants du projet n'existent que sur cette machine.
- **`.superpowers/` non ignoré** — apparaît en `??` dans `git status`, risque de commit
  accidentel du ledger.
- **`plan.md` achevé conservé à la racine** et référencé par `README.md:40` comme doc
  vivante, alors qu'un plan achevé doit se fondre dans la doc pérenne puis se supprimer ;
  périmé de surcroît (chemins inexistants, Ansible déclaré hors scope, code dupliqué).
- **`spec.md` figé au statut « prêt pour plan d'implémentation »** du 2026-07-11, antérieur à
  la livraison, mais présenté comme le design de référence par `README.md:39`.

## En cours

_(rien)_

## Terminé

### 2026-09-01 — Escalade de privilèges du hook fermée

Un compte non-root pouvait remplacer son `~/.bash_history` par un lien symbolique vers un
fichier de root : le hook, qui tournait en réalité avec `euid=0` (l'option `seteuid` de
`pam_exec` n'abaisse pas les privilèges de façon fiable), suivait le lien, tronquait la cible
puis lui en transférait la propriété par un `chown` défensif. Un mécanisme de confidentialité
faisait donc gagner des privilèges.

Correctif : le script abaisse lui-même ses privilèges vers le compte cible
(`setpriv --reuid --regid --init-groups`) **avant toute ouverture de fichier**, puis se
ré-exécute en `--wipe <home>` sous cette identité, borné par `timeout 5`. Le `chown` a
disparu. La frontière de sécurité est l'abaissement, pas un test de chemin — toute défense
« vérifier puis agir » sous root serait une course.

Conséquence à connaître : le mode installé passe de `0750` à `0755`. Sans droit d'exécution
pour le compte cible, la ré-exécution abaissée serait impossible et le mécanisme deviendrait
**silencieusement inopérant** — il rend toujours 0 et n'écrit rien, donc rien ne le
signalerait. Les trois voies de déploiement posent le mode par la même opération que le
corps : un simple replay converge une machine restée en `0750`, sans étape manuelle.

Décisions actées : la ligne PAM reste **inchangée**, `seteuid` compris — inopérant mais
inoffensif dès lors que le script ne s'y fie plus ; le retirer créerait une dérive entre le
dépôt et le parc déjà installé. Les preuves qui exigent un vrai `sshd` (fermeture de la
faille, FIFO, convergence Ansible) sont des checks du runbook manuel, pas des tests
automatisés : `docs/manual-verification.md`, checks 8 à 10.

Spec : `docs/superpowers/specs/2026-09-01-securite-du-mecanisme.md`.

_(journal ouvert le 2026-08-17, l'antériorité reste dans le git log)_
