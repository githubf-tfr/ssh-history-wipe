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
- **Dérive non couverte entre les trois variantes de déploiement** — seul le corps du script
  inline est protégé ; la ligne PAM, le mode `750` et le propriétaire ne le sont par aucun
  test de cohérence.
- **Doc de tête fausse sur le modèle de privilèges** — `README.md:29` et `CLAUDE.md:33`
  affirment que `seteuid` fait tourner le script avec les droits du compte, contredit par
  `spec.md:50-53` et le commentaire de `files/wipe-history-on-logout.sh:21-22`.
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

_(vide — journal ouvert le 2026-08-17, l'antériorité reste dans le git log)_
