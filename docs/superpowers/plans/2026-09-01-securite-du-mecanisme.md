# Plan d'implémentation — sécurité du mécanisme de nettoyage d'historique

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Objectif :** fermer l'escalade de privilèges du hook PAM (symlink sur
`~/.bash_history` tronqué puis `chown` sous euid=0) en abaissant explicitement les
privilèges vers le compte cible **avant** toute ouverture de fichier.

**Architecture :** le script se ré-exécute lui-même en `--wipe <home>` sous
l'identité du compte (`setpriv --reuid --regid --init-groups`, ou directement si
l'euid est déjà celui du compte), borné par `timeout 5`. Le `chown` disparaît. Le
mode installé passe de `0750` à `0755` (sinon le chemin abaissé est inexécutable et
le mécanisme devient silencieusement inopérant). Le corps du script existe en trois
exemplaires (canonique `files/`, inline du rôle standalone, copie `src:` du rôle
via-script) et les trois voies d'installation posent le même mode.

**Stack :** bash pur (script et tests, aucun framework), Ansible (2 rôles), Docker
(harnais non exécutés dans ce cycle).

**Spec :** `docs/superpowers/specs/2026-09-01-securite-du-mecanisme.md` — les
critères cités par numéro (« crit. N ») renvoient à sa section « Critères
d'acceptation ». Design : `.superpowers/sdd/2026-09-01-auto-update-securite-du-mecanisme/design-retenu.md`
(lecture seule, ne se rediscute pas).

## Contraintes globales

Chaque tâche est implicitement soumise à ces règles, copiées de la spec :

- Le mécanisme retourne **toujours 0** et n'écrit rien sur stdout/stderr en
  fonctionnement nominal ; **aucun test ne s'asserte sur un code de retour ou une
  absence d'erreur** — chaque assertion porte sur l'état observable du système de
  fichiers (contenu, taille, propriétaire, nature du fichier).
- Troncature, jamais suppression : le fichier n'est jamais `rm` par le mécanisme.
- La ligne PAM reste **strictement inchangée** :
  `session optional pam_exec.so seteuid /usr/local/sbin/wipe-history-on-logout.sh`.
- AlmaLinux 8+ / bash uniquement ; seules commandes hors builtins : `getent`
  (glibc), `timeout` (coreutils), `setpriv` (util-linux) — toutes du socle.
- Tests du dépôt : bash pur, assertions manuelles, fonctions `test_*` enregistrées
  par `run_test` — respecter ce style exactement, ne pas l'industrialiser. Aucun
  test ne requiert root, PAM, ni un second compte.
- Idempotence : `install.sh` et les rôles restent rejouables sans effet de bord.
- Aucun effet sur auditd/syslog/journalctl.
- **Git : commite ton travail sur la branche du cycle
  (`auto-update/2026-09-01-securite-du-mecanisme`), et seulement sur elle.** Aucune
  branche nouvelle, aucun push, aucun merge, aucun `--force`. Un commit par tâche,
  une fois ses étapes de vérification passées.
- Périmètre gelé — seuls fichiers modifiables : `files/wipe-history-on-logout.sh`,
  `install.sh`, `tests/` (y compris `tests/docker/`),
  `ansible/roles/ssh_history_wipe/tasks/main.yml`,
  `ansible/roles/ssh_history_wipe_standalone/tasks/main.yml`, `ansible/README.md`,
  `docs/manual-verification.md`, `README.md`, et `CLAUDE.md` **pour sa seule puce
  `seteuid`** (périmètre élargi par le maître : cette puce affirme l'exacte croyance
  fausse à l'origine de la faille, la laisser serait livrer une source de vérité qui
  contredit le correctif). Rien d'autre — en particulier ni `spec.md`/`plan.md` à la
  racine (artefacts périmés d'un cycle antérieur : ne pas les lire comme sources de
  vérité, ne pas les modifier), ni le ledger `.superpowers/`.

**Ordre des tâches :** 1 → 2 → 3 → 4 → 5 → 6. La tâche 3 dépend du corps produit en
tâche 1 ; les autres dépendances sont documentées dans chaque tâche.

---

### Tâche 1 : corps sécurisé du script canonique

**Fichiers :**
- Modifier : `files/wipe-history-on-logout.sh` (remplacement intégral)
- Test : `tests/test_wipe_history_on_logout.sh` (remplacement intégral : les
  5 tests existants sont conservés à l'identique, 6 tests s'ajoutent)

**Interfaces :**
- Produit : le script canonique avec trois surfaces — `truncate_history <home_dir>`
  (fonction, script sourcé, signature inchangée), l'invocation directe
  `--wipe <home_dir>`, et `main` (exécution directe par PAM, sans argument). La
  tâche 3 recopie ce corps **octet pour octet** dans le rôle standalone.
- Critères satisfaits : crit. 1 (symlink), 2 (chemin abaissé de bout en bout),
  3 (FIFO), 4 (historique absent), 5 (open_session), 6 (`PAM_USER` inconnu) + cas
  limite « uid vide » de la spec (§ Cas par cas, cas limites rattachés).

**Note d'ordre :** entre cette tâche et la tâche 3, l'inline du rôle standalone
dérive volontairement du canonique — état transitoire attendu, résorbé en tâche 3.

- [ ] **Étape 1 : écrire les tests (nouveaux tests d'abord, implémentation ensuite)**

Remplacer intégralement `tests/test_wipe_history_on_logout.sh` par :

```bash
#!/bin/bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
target="$here/../files/wipe-history-on-logout.sh"
fail=0

run_test() {
    local name="$1"
    shift
    if "$@"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        fail=1
    fi
}

test_truncates_existing_history() {
    local tmp
    tmp="$(mktemp -d)"
    echo "ls -la" > "$tmp/.bash_history"
    echo "cat /etc/shadow" >> "$tmp/.bash_history"
    ( source "$target"; truncate_history "$tmp" )
    [ -f "$tmp/.bash_history" ] || { rm -rf "$tmp"; return 1; }
    [ -s "$tmp/.bash_history" ] && { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
}

test_missing_home_is_noop() {
    ( source "$target"; truncate_history "/nonexistent/path/does-not-exist" )
    [ $? -eq 0 ]
}

test_main_without_pam_user_is_noop() {
    local out
    out="$(unset PAM_USER; export PAM_TYPE=close_session; source "$target"; main; echo "exit:$?")"
    [ "$out" = "exit:0" ]
}

# PAM invokes the "session" line at both open and close; main must only act
# on close_session (see comment in files/wipe-history-on-logout.sh). Shadow
# getent so the test proves cleanup was never attempted, without touching
# any real user's home directory.
test_main_skips_open_session() {
    local marker called
    marker="$(mktemp)"
    (
        getent() { echo "CALLED" >> "$marker"; }
        export PAM_TYPE=open_session
        export PAM_USER=root
        source "$target"
        main
    )
    called="$(cat "$marker")"
    rm -f "$marker"
    [ -z "$called" ]
}

test_main_proceeds_on_close_session() {
    local marker called
    marker="$(mktemp)"
    (
        getent() { echo "CALLED" >> "$marker"; }
        export PAM_TYPE=close_session
        export PAM_USER=root
        source "$target"
        main
    )
    called="$(cat "$marker")"
    rm -f "$marker"
    [ -n "$called" ]
}

# --- Security fix (2026-09-01): the guard and the dropped-privilege path ---

# Crit. 1: a symlinked ~/.bash_history must never be followed - the witness
# file it points to stays intact and the link stays in place.
test_symlink_history_leaves_witness_intact() {
    local tmp home witness
    tmp="$(mktemp -d)"
    home="$tmp/home"
    witness="$tmp/witness"
    mkdir "$home"
    printf 'contenu-temoin\n' > "$witness"
    ln -s "$witness" "$home/.bash_history"
    ( source "$target"; truncate_history "$home" )
    [ "$(cat "$witness")" = "contenu-temoin" ] || { rm -rf "$tmp"; return 1; }
    [ -L "$home/.bash_history" ] || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
}

# Crit. 3: a FIFO in place of ~/.bash_history is left untouched and the call
# returns (no hang on open). timeout only bounds a would-be hang: exit 124
# means the call blocked, which is the failure this test guards against.
test_fifo_history_left_in_place() {
    local tmp status
    tmp="$(mktemp -d)"
    mkfifo "$tmp/.bash_history"
    timeout 5 bash -c "source '$target'; truncate_history '$tmp'"
    status=$?
    [ "$status" -ne 124 ] || { rm -rf "$tmp"; return 1; }
    [ -p "$tmp/.bash_history" ] || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
}

# Crit. 4: an account without history has nothing to clean - the file must
# not be created (a root-owned one would lock history writing at login).
test_absent_history_not_created() {
    local tmp
    tmp="$(mktemp -d)"
    ( source "$target"; truncate_history "$tmp" )
    [ ! -e "$tmp/.bash_history" ] || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
}

# Crit. 2 - central criterion: the dropped-privilege path runs end to end,
# exactly the way PAM invokes it (direct execution of the file, not sourced).
# A fake getent ahead of PATH resolves PAM_USER to a sandbox home owned by
# the current user, whose uid equals the current euid, so main takes the
# "euid = target uid" branch: main -> dispatch -> timeout -> re-exec with
# --wipe -> truncate_history. The script copy carries the contract mode 0755;
# the test fails if the dispatch, the re-exec or the executability breaks
# (e.g. a mode that stops the re-exec would leave the file non-empty).
test_pam_exec_path_wipes_history_end_to_end() {
    local tmp script home fakebin
    tmp="$(mktemp -d)"
    script="$tmp/wipe-history-on-logout.sh"
    cp "$target" "$script"
    chmod 755 "$script"
    home="$tmp/home"
    mkdir "$home"
    printf 'echo secret\n' > "$home/.bash_history"
    fakebin="$tmp/bin"
    mkdir "$fakebin"
    cat > "$fakebin/getent" <<FAKE
#!/bin/bash
printf '%s\n' "testuser:x:$(id -u):$(id -g)::$home:/bin/bash"
FAKE
    chmod 755 "$fakebin/getent"
    env PATH="$fakebin:$PATH" PAM_TYPE=close_session PAM_USER="$(id -un)" "$script"
    [ -f "$home/.bash_history" ] || { rm -rf "$tmp"; return 1; }
    [ -s "$home/.bash_history" ] && { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
}

# Crit. 6: PAM_USER unknown to account resolution - nothing written anywhere.
# HOME points at a sandbox with a non-empty history to catch any wrongful
# fallback on the caller's environment.
test_main_unknown_user_writes_nothing() {
    local tmp script home fakebin
    tmp="$(mktemp -d)"
    script="$tmp/wipe-history-on-logout.sh"
    cp "$target" "$script"
    chmod 755 "$script"
    home="$tmp/home"
    mkdir "$home"
    printf 'echo secret\n' > "$home/.bash_history"
    fakebin="$tmp/bin"
    mkdir "$fakebin"
    printf '#!/bin/bash\nexit 2\n' > "$fakebin/getent"
    chmod 755 "$fakebin/getent"
    env PATH="$fakebin:$PATH" HOME="$home" PAM_TYPE=close_session PAM_USER=ghost "$script"
    [ "$(cat "$home/.bash_history")" = "echo secret" ] || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
}

# Spec edge case: a passwd entry with an empty uid field must be a silent
# no-op (7 colon-separated fields: name:passwd:uid:gid:gecos:home:shell,
# uid and gid left empty here).
test_main_empty_uid_writes_nothing() {
    local tmp script home fakebin
    tmp="$(mktemp -d)"
    script="$tmp/wipe-history-on-logout.sh"
    cp "$target" "$script"
    chmod 755 "$script"
    home="$tmp/home"
    mkdir "$home"
    printf 'echo secret\n' > "$home/.bash_history"
    fakebin="$tmp/bin"
    mkdir "$fakebin"
    cat > "$fakebin/getent" <<FAKE
#!/bin/bash
printf '%s\n' "ghost:x::::$home:/bin/bash"
FAKE
    chmod 755 "$fakebin/getent"
    env PATH="$fakebin:$PATH" PAM_TYPE=close_session PAM_USER=ghost "$script"
    [ "$(cat "$home/.bash_history")" = "echo secret" ] || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    return 0
}

run_test "truncates existing history" test_truncates_existing_history
run_test "missing home is a silent no-op" test_missing_home_is_noop
run_test "main without PAM_USER is a no-op" test_main_without_pam_user_is_noop
run_test "main skips PAM_TYPE=open_session (no cleanup attempted)" test_main_skips_open_session
run_test "main proceeds on PAM_TYPE=close_session" test_main_proceeds_on_close_session
run_test "symlinked history leaves target intact" test_symlink_history_leaves_witness_intact
run_test "FIFO history left in place, no hang" test_fifo_history_left_in_place
run_test "absent history is not created" test_absent_history_not_created
run_test "PAM exec path wipes history end to end" test_pam_exec_path_wipes_history_end_to_end
run_test "unknown PAM_USER writes nothing" test_main_unknown_user_writes_nothing
run_test "empty uid in passwd entry writes nothing" test_main_empty_uid_writes_nothing

exit $fail
```

- [ ] **Étape 2 : exécuter la suite et constater l'échec**

Exécuter : `bash tests/test_wipe_history_on_logout.sh`

Attendu contre l'ancien corps (vérifié lors de la rédaction de ce plan) :

```
PASS: truncates existing history
PASS: missing home is a silent no-op
PASS: main without PAM_USER is a no-op
PASS: main skips PAM_TYPE=open_session (no cleanup attempted)
PASS: main proceeds on PAM_TYPE=close_session
FAIL: symlinked history leaves target intact
FAIL: FIFO history left in place, no hang
FAIL: absent history is not created
PASS: PAM exec path wipes history end to end
PASS: unknown PAM_USER writes nothing
FAIL: empty uid in passwd entry writes nothing
```

Code de sortie 1. Le test FIFO prend ~5 s ici (l'ancien corps bloque sur l'`open`
de la FIFO, c'est le `timeout` du test qui le tue — exit 124 → FAIL). Deux nouveaux
tests passent déjà contre l'ancien corps, c'est attendu et documenté : « PAM exec
path… » (l'ancien script tronque directement dans le processus, sans dispatch — le
test protège le **nouveau** chemin : il échouera si le dispatch, la ré-exécution
`--wipe` ou l'exécutabilité du fichier se cassent) et « unknown PAM_USER… »
(l'ancien corps était déjà no-op sur home vide). Si un autre résultat apparaît,
s'arrêter et investiguer avant de continuer.

- [ ] **Étape 3 : remplacer intégralement le corps du script**

Remplacer intégralement `files/wipe-history-on-logout.sh` par (le fichier garde son
bit exécutable) :

```bash
#!/bin/bash
set -u

truncate_history() {
    local home="$1" hist="$1/.bash_history"
    [ -d "$home" ] || return 0
    # Only clean a regular file that is not a symlink. Best-effort
    # off-target guard, NOT the security boundary: the boundary is the
    # privilege drop done in main() before any file is opened. Even if
    # this guard were raced, the worst case is truncating a file the
    # account could already write to itself.
    [ -f "$hist" ] && [ ! -L "$hist" ] || return 0
    : > "$hist" 2>/dev/null
    return 0
}

main() {
    # PAM invokes a "session" line at both open and close; without this
    # check the script also fires at login, truncating/creating
    # .bash_history as root and locking the user out of writing to it
    # for the rest of the session.
    [ "${PAM_TYPE:-}" = "close_session" ] || return 0
    [ -n "${PAM_USER:-}" ] || return 0
    local entry uid gid home
    entry="$(getent passwd "$PAM_USER" 2>/dev/null)"
    [ -n "$entry" ] || return 0
    IFS=: read -r _ _ uid gid _ home _ <<< "$entry"
    [ -n "$uid" ] || return 0
    # seteuid on the PAM line does not reliably drop privileges (euid=0
    # observed even with it set). The drop happens HERE, explicitly,
    # before any file is opened - this is the security boundary. timeout
    # bounds a booby-trapped target that would block on open (e.g. a
    # FIFO with no reader) so a logout is never delayed.
    if [ "$EUID" = "$uid" ]; then
        # Drop already effective, or root closing its own session.
        timeout 5 "$0" --wipe "$home" >/dev/null 2>&1
    elif [ "$EUID" = "0" ] && [ "$uid" != "0" ]; then
        timeout 5 setpriv --reuid "$uid" --regid "$gid" --init-groups -- \
            "$0" --wipe "$home" >/dev/null 2>&1
    fi
    # euid neither 0 nor the target uid: abnormal state, do nothing.
    return 0
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ "${1:-}" = "--wipe" ]; then
        truncate_history "${2:-}"
        exit 0
    fi
    main
    exit 0
fi
```

Points non négociables de ce corps : l'abaissement (`setpriv`) précède toute
ouverture de fichier ; le `chown` de l'ancien corps a **disparu** (il était la
moitié aval du vecteur d'escalade) ; `--wipe` ne porte aucun filtre PAM et
n'agit qu'avec les droits de son appelant (le script n'est pas setuid) ; `main`
retourne toujours 0 et ne produit aucune sortie.

- [ ] **Étape 4 : exécuter la suite et constater le succès**

Exécuter : `bash tests/test_wipe_history_on_logout.sh`

Attendu : 11 lignes `PASS`, code de sortie 0 (vérifié lors de la rédaction de ce
plan, bash 5.x). Le test FIFO rend la main immédiatement désormais (le garde
`[ -f ]` rejette la FIFO sans l'ouvrir).

---

### Tâche 2 : `install.sh` — mode 0755 et convergence depuis 0750

**Fichiers :**
- Modifier : `install.sh` (ligne 11)
- Test : `tests/test_install.sh` (remplacement intégral : 3 tests existants dont
  un mis à jour — assertion ligne 29 et libellé ligne 59 du fichier actuel — plus
  1 test de convergence ajouté)

**Interfaces :**
- Consomme : le corps canonique produit en tâche 1 (le test de convergence diffe
  la cible contre `files/wipe-history-on-logout.sh`).
- Produit : `install.sh` posant `chmod 755` inconditionnellement — propriété de
  convergence utilisée par la doc (tâche 5).
- Critères satisfaits : crit. 7 (voie `install.sh`), crit. 8 (convergence depuis
  `0750`), crit. 10 (ligne PAM unique après double replay — test existant
  conservé).

- [ ] **Étape 1 : mettre à jour les tests**

Remplacer intégralement `tests/test_install.sh` par :

```bash
#!/bin/bash
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installer="$here/../install.sh"
canonical="$here/../files/wipe-history-on-logout.sh"
fail=0

run_test() {
    local name="$1"
    shift
    if "$@"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        fail=1
    fi
}

# The contract mode is 0755: the dropped-privilege re-exec needs the target
# account to be able to execute the script (a stricter mode makes the
# mechanism silently inoperative - first-class failure mode, see spec).
test_installs_script_with_correct_mode() {
    local tmp dest pamfile
    tmp="$(mktemp -d)"
    dest="$tmp/wipe-history-on-logout.sh"
    pamfile="$tmp/sshd"
    : > "$pamfile"
    SCRIPT_DEST="$dest" PAM_SSHD_FILE="$pamfile" bash "$installer" >/dev/null
    [ -f "$dest" ] || { rm -rf "$tmp"; return 1; }
    local mode
    mode="$(stat -c '%a' "$dest")"
    rm -rf "$tmp"
    [ "$mode" = "755" ]
}

test_adds_pam_line() {
    local tmp dest pamfile
    tmp="$(mktemp -d)"
    dest="$tmp/wipe-history-on-logout.sh"
    pamfile="$tmp/sshd"
    : > "$pamfile"
    SCRIPT_DEST="$dest" PAM_SSHD_FILE="$pamfile" bash "$installer" >/dev/null
    local count
    count="$(grep -cF "session optional pam_exec.so seteuid $dest" "$pamfile")"
    rm -rf "$tmp"
    [ "$count" = "1" ]
}

test_rerun_does_not_duplicate_pam_line() {
    local tmp dest pamfile
    tmp="$(mktemp -d)"
    dest="$tmp/wipe-history-on-logout.sh"
    pamfile="$tmp/sshd"
    : > "$pamfile"
    SCRIPT_DEST="$dest" PAM_SSHD_FILE="$pamfile" bash "$installer" >/dev/null
    SCRIPT_DEST="$dest" PAM_SSHD_FILE="$pamfile" bash "$installer" >/dev/null
    local count
    count="$(grep -cF "session optional pam_exec.so seteuid $dest" "$pamfile")"
    rm -rf "$tmp"
    [ "$count" = "1" ]
}

# Crit. 8: a target already deployed with the old body and the old 0750 mode
# must converge to the new body AND mode 0755 after a single replay - the
# property that protects the existing fleet (no mixed "new script + old
# mode" state possible).
test_converges_from_old_mode_750() {
    local tmp dest pamfile mode
    tmp="$(mktemp -d)"
    dest="$tmp/wipe-history-on-logout.sh"
    pamfile="$tmp/sshd"
    : > "$pamfile"
    printf '#!/bin/bash\n# old body\n' > "$dest"
    chmod 750 "$dest"
    SCRIPT_DEST="$dest" PAM_SSHD_FILE="$pamfile" bash "$installer" >/dev/null
    mode="$(stat -c '%a' "$dest")"
    diff -q "$dest" "$canonical" >/dev/null || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    [ "$mode" = "755" ]
}

run_test "installs script with mode 755" test_installs_script_with_correct_mode
run_test "adds the PAM line" test_adds_pam_line
run_test "re-running does not duplicate the PAM line" test_rerun_does_not_duplicate_pam_line
run_test "single replay converges body and mode from an old 0750 install" test_converges_from_old_mode_750
```

- [ ] **Étape 2 : exécuter la suite et constater l'échec**

Exécuter : `bash tests/test_install.sh`

Attendu contre l'`install.sh` actuel (vérifié lors de la rédaction de ce plan) :

```
FAIL: installs script with mode 755
PASS: adds the PAM line
PASS: re-running does not duplicate the PAM line
FAIL: single replay converges body and mode from an old 0750 install
```

Code de sortie 1 (l'installeur actuel pose `chmod 750`, la cible reste en `750`).

- [ ] **Étape 3 : corriger `install.sh`**

Une seule ligne change. Diff exact :

```diff
-chmod 750 "$SCRIPT_DEST"
+chmod 755 "$SCRIPT_DEST"
```

Le reste du fichier (copie depuis `files/`, `chown root:root`, ajout conditionnel
de la ligne PAM via `grep -qF`) est strictement inchangé.

- [ ] **Étape 4 : exécuter la suite et constater le succès**

Exécuter : `bash tests/test_install.sh`

Attendu : 4 lignes `PASS`, code de sortie 0 (vérifié lors de la rédaction de ce
plan : mode `755`, corps identique au canonique, ligne PAM unique).

---

### Tâche 3 : rôles Ansible — mode 0755 et inline resynchronisé

**Fichiers :**
- Modifier : `ansible/roles/ssh_history_wipe/tasks/main.yml` (ligne 8)
- Modifier : `ansible/roles/ssh_history_wipe_standalone/tasks/main.yml`
  (remplacement intégral)
- Test : `tests/test_ansible_sync.sh` (ajout de 2 tests ; le test PyYAML existant
  est conservé à l'identique)

**Interfaces :**
- Consomme : le corps canonique de la tâche 1 — l'inline du rôle standalone doit
  lui être identique **octet pour octet** (indentation YAML de 6 espaces en plus
  sur chaque ligne non vide, lignes vides laissées vides).
- Produit : les deux rôles déclarant `mode: "0755"` ; le rôle via-script suit le
  canonique automatiquement par `src:` (aucun changement de corps à y faire).
- Critères satisfaits : crit. 7 (voies Ansible), crit. 9 (non-dérive de l'inline).

- [ ] **Étape 1 : ajouter les tests de mode**

Remplacer intégralement `tests/test_ansible_sync.sh` par :

```bash
#!/bin/bash
# The standalone role (roles/ssh_history_wipe_standalone) embeds the cleanup
# script's source directly in tasks/main.yml (content: |) so it has no
# external file dependency - but that means it can drift silently from
# files/wipe-history-on-logout.sh. This test extracts that inline block and
# diffs it against the canonical script to catch that.
#
# The other role (roles/ssh_history_wipe) reads files/wipe-history-on-logout.sh
# directly via `src:` at apply time, so there's nothing to drift there - no
# equivalent check needed for it.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
canonical="$here/../files/wipe-history-on-logout.sh"
tasks_file="$here/../ansible/roles/ssh_history_wipe_standalone/tasks/main.yml"
via_script_tasks_file="$here/../ansible/roles/ssh_history_wipe/tasks/main.yml"
fail=0

run_test() {
    local name="$1"
    shift
    if "$@"; then
        echo "PASS: $name"
    else
        echo "FAIL: $name"
        fail=1
    fi
}

test_standalone_inline_script_matches_canonical() {
    local extracted
    extracted="$(mktemp)"
    python3 - "$tasks_file" > "$extracted" <<'PYEOF'
import sys
import yaml

with open(sys.argv[1]) as f:
    tasks = yaml.safe_load(f)

for task in tasks:
    copy_args = task.get("ansible.builtin.copy")
    if copy_args and "content" in copy_args:
        sys.stdout.write(copy_args["content"])
        break
PYEOF
    diff "$extracted" "$canonical" >/dev/null 2>&1
    local result=$?
    rm -f "$extracted"
    return $result
}

# Crit. 7 (Ansible paths): both roles must declare the 0755 contract mode -
# a stricter mode makes the dropped-privilege re-exec impossible and the
# mechanism silently inoperative (see spec, first-class failure mode).
test_via_script_role_declares_mode_0755() {
    grep -q 'mode: "0755"' "$via_script_tasks_file"
}

test_standalone_role_declares_mode_0755() {
    grep -q 'mode: "0755"' "$tasks_file"
}

run_test "standalone role's inline script content matches files/wipe-history-on-logout.sh" \
    test_standalone_inline_script_matches_canonical
run_test "via-script role declares mode 0755" test_via_script_role_declares_mode_0755
run_test "standalone role declares mode 0755" test_standalone_role_declares_mode_0755

exit $fail
```

- [ ] **Étape 2 : exécuter la suite et constater l'échec**

Exécuter : `bash tests/test_ansible_sync.sh`

Attendu contre les rôles actuels :

```
FAIL: standalone role's inline script content matches files/wipe-history-on-logout.sh
FAIL: via-script role declares mode 0755
FAIL: standalone role declares mode 0755
```

⚠️ Le premier `FAIL` est **ambigu sur cette machine** : PyYAML est absent
(`python3 -c "import yaml"` → `ModuleNotFoundError`, constat hors thème déjà au
`KANBAN.md`, **ne pas corriger la dépendance** — hors périmètre). Il échouerait ici
même sans dérive. Seuls les deux `FAIL` de mode sont le fail-first attendu de cette
étape.

- [ ] **Étape 3 : corriger le rôle via-script**

Dans `ansible/roles/ssh_history_wipe/tasks/main.yml`, une seule ligne change :

```diff
-    mode: "0750"
+    mode: "0755"
```

Le reste (tâche `copy` avec `src:` vers le canonique, tâche `lineinfile` avec la
ligne PAM inchangée) est strictement conservé.

- [ ] **Étape 4 : réécrire le rôle standalone**

Remplacer intégralement `ansible/roles/ssh_history_wipe_standalone/tasks/main.yml`
par le contenu ci-dessous. Pour garantir l'identité octet pour octet, **ne pas
recopier l'inline à la main** : le régénérer mécaniquement depuis le canonique —
`sed 's/^./      &/' files/wipe-history-on-logout.sh` produit exactement le bloc à
placer sous `content: |` (6 espaces devant chaque ligne non vide, lignes vides
inchangées). Résultat attendu :

```yaml
---
- name: Deploy history cleanup script
  ansible.builtin.copy:
    dest: "{{ ssh_history_wipe_script_dest }}"
    owner: root
    group: root
    mode: "0755"
    content: |
      #!/bin/bash
      set -u

      truncate_history() {
          local home="$1" hist="$1/.bash_history"
          [ -d "$home" ] || return 0
          # Only clean a regular file that is not a symlink. Best-effort
          # off-target guard, NOT the security boundary: the boundary is the
          # privilege drop done in main() before any file is opened. Even if
          # this guard were raced, the worst case is truncating a file the
          # account could already write to itself.
          [ -f "$hist" ] && [ ! -L "$hist" ] || return 0
          : > "$hist" 2>/dev/null
          return 0
      }

      main() {
          # PAM invokes a "session" line at both open and close; without this
          # check the script also fires at login, truncating/creating
          # .bash_history as root and locking the user out of writing to it
          # for the rest of the session.
          [ "${PAM_TYPE:-}" = "close_session" ] || return 0
          [ -n "${PAM_USER:-}" ] || return 0
          local entry uid gid home
          entry="$(getent passwd "$PAM_USER" 2>/dev/null)"
          [ -n "$entry" ] || return 0
          IFS=: read -r _ _ uid gid _ home _ <<< "$entry"
          [ -n "$uid" ] || return 0
          # seteuid on the PAM line does not reliably drop privileges (euid=0
          # observed even with it set). The drop happens HERE, explicitly,
          # before any file is opened - this is the security boundary. timeout
          # bounds a booby-trapped target that would block on open (e.g. a
          # FIFO with no reader) so a logout is never delayed.
          if [ "$EUID" = "$uid" ]; then
              # Drop already effective, or root closing its own session.
              timeout 5 "$0" --wipe "$home" >/dev/null 2>&1
          elif [ "$EUID" = "0" ] && [ "$uid" != "0" ]; then
              timeout 5 setpriv --reuid "$uid" --regid "$gid" --init-groups -- \
                  "$0" --wipe "$home" >/dev/null 2>&1
          fi
          # euid neither 0 nor the target uid: abnormal state, do nothing.
          return 0
      }

      if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
          if [ "${1:-}" = "--wipe" ]; then
              truncate_history "${2:-}"
              exit 0
          fi
          main
          exit 0
      fi

- name: Ensure pam_exec session-close line is present in sshd PAM stack
  ansible.builtin.lineinfile:
    path: "{{ ssh_history_wipe_pam_sshd_file }}"
    line: "session optional pam_exec.so seteuid {{ ssh_history_wipe_script_dest }}"
    insertafter: eof
    state: present
```

- [ ] **Étape 5 : exécuter la suite et constater le succès (modulo PyYAML)**

Exécuter : `bash tests/test_ansible_sync.sh`

Attendu sur cette machine :

```
FAIL: standalone role's inline script content matches files/wipe-history-on-logout.sh
PASS: via-script role declares mode 0755
PASS: standalone role declares mode 0755
```

Le `FAIL` restant est l'échec d'environnement connu (PyYAML absent), pas une
régression — voir l'étape 6 pour la distinction. Sur une machine avec PyYAML, les
trois tests doivent être `PASS`.

- [ ] **Étape 6 : prouver la non-dérive sans PyYAML**

Exécuter (extraction mécanique du bloc inline, validée lors de la rédaction de ce
plan) :

```bash
awk 'f && /^- name:/{exit} f {sub(/^      /,""); print} /^    content: \|$/{f=1}' \
    ansible/roles/ssh_history_wipe_standalone/tasks/main.yml \
    | sed -e '${/^$/d}' \
    | diff - files/wipe-history-on-logout.sh && echo NON-DERIVE-OK
```

Attendu : aucune sortie de `diff`, puis `NON-DERIVE-OK`. Toute autre sortie =
vraie dérive de l'étape 4, à corriger avant de continuer. (Le `sed` retire la
ligne vide finale que l'extraction produit — le bloc `content: |` est suivi d'une
ligne vide de séparation YAML.)

---

### Tâche 4 : harnais Docker — cohérence 0755 (non exécutés dans ce cycle)

**Fichiers :**
- Modifier : `tests/docker/run-docker-verification.sh` (lignes 77, 102, 135 du
  fichier actuel)
- Modifier : `tests/docker/run-ansible-docker-verification.sh` (lignes 93, 130 du
  fichier actuel)

**Interfaces :**
- Consomme : le mode contractuel `0755` (tâches 2 et 3).
- Produit : des harnais cohérents avec le nouveau contrat, prêts pour une
  exécution ultérieure sur une machine avec démon Docker.
- Critères : aucun critère `[auto]` ne repose sur ces harnais ; ils restent une
  automatisation d'appoint des checks du runbook (le niveau normatif des critères
  11-16 est le runbook manuel, cf. spec « Hors périmètre »).

⚠️ **Ces harnais exigent un démon Docker, absent de cette machine : ils ne sont
pas exécutés dans ce cycle.** La mise à jour est purement de cohérence (les cinq
points ci-dessous, rien d'autre — pas de nouveau check Docker) et se vérifie par
`bash -n`. Leur première exécution réelle se fera hors cycle, avec le runbook.

- [ ] **Étape 1 : `run-docker-verification.sh` — trois points**

Dans `test_install_artifacts` (ligne 77 actuelle) :

```diff
-    [ "$mode" = "750" ] || return 1
+    [ "$mode" = "755" ] || return 1
```

Dans `test_nonblocking_on_failure` (ligne 102 actuelle, restauration du mode après
le `chmod 000` volontaire) :

```diff
-    docker exec "$container" chmod 750 /usr/local/sbin/wipe-history-on-logout.sh
+    docker exec "$container" chmod 755 /usr/local/sbin/wipe-history-on-logout.sh
```

Libellé du `run_test` (ligne 135 actuelle) :

```diff
-run_test "install artifacts present (script mode 750, PAM line)" test_install_artifacts
+run_test "install artifacts present (script mode 755, PAM line)" test_install_artifacts
```

- [ ] **Étape 2 : `run-ansible-docker-verification.sh` — deux points**

Dans `test_install_artifacts` (ligne 93 actuelle) :

```diff
-    [ "$mode" = "750" ] || return 1
+    [ "$mode" = "755" ] || return 1
```

Libellé du `run_test` (ligne 130 actuelle) :

```diff
-run_test "install artifacts present (script mode 750, PAM line)" test_install_artifacts
+run_test "install artifacts present (script mode 755, PAM line)" test_install_artifacts
```

- [ ] **Étape 3 : vérifier la syntaxe (seule vérification possible ici)**

Exécuter :

```bash
bash -n tests/docker/run-docker-verification.sh
bash -n tests/docker/run-ansible-docker-verification.sh
grep -rn '750' tests/docker/*.sh || echo AUCUNE-MENTION-750
```

Attendu : aucune erreur de syntaxe, puis `AUCUNE-MENTION-750` (plus aucune mention
de l'ancien mode dans les harnais).

---

### Tâche 5 : documentation — mode, notes et nouveaux checks du runbook

**Fichiers :**
- Modifier : `ansible/README.md` (ligne 5 actuelle)
- Modifier : `docs/manual-verification.md` (note d'en-tête, checks 1 et 4,
  nouveaux checks 8-10)
- Modifier : `README.md` (puce `seteuid` de la section « Mécanisme », rendue
  fausse par le correctif)
- Modifier : `CLAUDE.md` (ligne 33, puce `seteuid` de la section « Mécanisme » —
  même correction, périmètre élargi par le maître)

**Interfaces :**
- Consomme : le contrat `0755` et le flux abaissé (tâches 1-3).
- Critères satisfaits : crit. 11, 12 et 16 (côté rédaction des checks `[runbook]` ;
  leur **exécution** revient à un humain sur un vrai host, hors de ce plan) ;
  crit. 13, 14, 15 sont déjà couverts par les checks 2, 3 et 7 existants du
  runbook, inchangés.

- [ ] **Étape 1 : `ansible/README.md`**

Dans le premier paragraphe (ligne 5 actuelle) :

```diff
-comportement, mêmes cibles : dépose le script de nettoyage avec les droits
-`root:root` mode `750`, ajoute la ligne `pam_exec` dans le PAM stack de
+comportement, mêmes cibles : dépose le script de nettoyage avec les droits
+`root:root` mode `755`, ajoute la ligne `pam_exec` dans le PAM stack de
```

- [ ] **Étape 2 : `docs/manual-verification.md` — corrections des passages faux**

Trois retouches sur l'existant.

Check 1, sortie attendue de `ls -l` (ligne 38 actuelle) :

```diff
-ls -l /usr/local/sbin/wipe-history-on-logout.sh   # root root, -rwxr-x---
+ls -l /usr/local/sbin/wipe-history-on-logout.sh   # root root, -rwxr-xr-x
```

Check 4, restauration du mode (ligne 78 actuelle) :

```diff
-sudo chmod 750 /usr/local/sbin/wipe-history-on-logout.sh
+sudo chmod 755 /usr/local/sbin/wipe-history-on-logout.sh
```

Note du 2026-07-11 : sa dernière phrase présente le `chown` défensif comme le
correctif en vigueur alors qu'il disparaît. La remplacer :

```diff
-was still open*, before logout, rather than only checking the automated
-script's PASS/FAIL output. Fixed by gating on `$PAM_TYPE = close_session`
-and adding a defensive `chown` — see `files/wipe-history-on-logout.sh`.
+was still open*, before logout, rather than only checking the automated
+script's PASS/FAIL output. Fixed by gating on `$PAM_TYPE = close_session`,
+initially completed by a defensive `chown` — since removed, see the
+2026-09-01 note below.
```

- [ ] **Étape 3 : `docs/manual-verification.md` — note datée du correctif**

Insérer, immédiatement après la note du 2026-07-11 (avant la section `## 1.
Install`) :

````markdown
**Note (2026-09-01):** the defensive `chown` mentioned above has been
removed: running with euid=0 (the PAM `seteuid` option does not reliably
drop privileges), it followed a symlinked `~/.bash_history` — truncating
then handing ownership of any root-owned file to the attacker (privilege
escalation). The script now drops privileges itself, before any file is
opened: it re-executes as `<script> --wipe <home>` under the target
account's identity (`setpriv --reuid --regid --init-groups`), bounded by
`timeout 5`. The installed mode is `0755` so the re-exec still works after
the drop (a stricter mode would make the mechanism silently inoperative).
The PAM line is unchanged. Checks 8-10 below prove the fix; they are not
covered by the Docker harness — this manual runbook is their normative
level.
````

- [ ] **Étape 4 : `docs/manual-verification.md` — nouveaux checks 8-10**

Ajouter en fin de fichier (après le check 7) :

````markdown
## 8. Symlink attack is neutralized (privilege escalation fix)

As admin, create a root-owned witness file with known content:

```bash
ssh admin@host "echo witness-content | sudo tee /root/wipe-test-witness >/dev/null"
```

From the attacker's (non-root) account, point the history at it, then log
out:

```bash
ssh testuser@host
ln -sf /root/wipe-test-witness ~/.bash_history
exit
```

Then, as admin:

```bash
ssh admin@host "sudo stat -c '%s %U' /root/wipe-test-witness; sudo cat /root/wipe-test-witness; sudo ls -l /home/testuser/.bash_history"
```

Expected: the witness file still contains `witness-content` (16 bytes),
its owner is still `root` (no truncation, no ownership transfer), and
`/home/testuser/.bash_history` is still a symlink pointing at it. Clean up
afterwards (`sudo rm /root/wipe-test-witness`, restore the account's
`~/.bash_history` by removing the symlink).

## 9. FIFO in place of the history does not delay logout

From a non-root account, replace the history with a FIFO, then log out
while timing the disconnect:

```bash
ssh testuser@host
rm -f ~/.bash_history && mkfifo ~/.bash_history
exit   # measure: the disconnect must complete without noticeable delay
```

Expected: the logout completes normally — any extra delay stays under the
script's 5-second `timeout` bound. Then, as admin:

```bash
ssh admin@host "sudo stat -c '%F' /home/testuser/.bash_history"
```

Expected: `fifo` — the FIFO is left in place, nothing was written to it.
Clean up by removing the FIFO afterwards.

## 10. Ansible replay converges an old 0750 deployment

On a host still carrying the previous deployment (script mode `750`, old
body):

```bash
ssh admin@host "stat -c '%a' /usr/local/sbin/wipe-history-on-logout.sh"   # 750 before
ansible-playbook -i <inventory> ansible/playbook.yml --ask-become-pass    # or playbook-standalone.yml
ssh admin@host "stat -c '%a' /usr/local/sbin/wipe-history-on-logout.sh; sudo grep -c setpriv /usr/local/sbin/wipe-history-on-logout.sh; grep -c wipe-history-on-logout.sh /etc/pam.d/sshd"
```

Expected: mode `755`, `setpriv` present in the deployed body (new script),
and exactly `1` PAM line — converged by a single replay, no manual step.
The same property holds for `install.sh` replayed on such a host (covered
automatically by `tests/test_install.sh`).
````

- [ ] **Étape 5 : `README.md` — puce `seteuid`**

Dans la section « Mécanisme », la puce actuelle est rendue fausse par le
correctif :

```diff
-- `seteuid` : le script tourne avec les droits du compte qui se
-  déconnecte.
+- `seteuid` : conservé sur la ligne PAM mais non fiable (euid=0 observé) —
+  le script n'en dépend plus : il abaisse lui-même ses privilèges
+  (`setpriv`) vers le compte qui se déconnecte avant toute écriture, et
+  tronque sous cette identité.
```

Aucune autre modification du `README.md` : les renvois périmés vers `spec.md` /
`plan.md` à la racine sont un constat hors thème déjà porté au `KANBAN.md`, hors
périmètre de ce cycle.

- [ ] **Étape 6 : `CLAUDE.md` — puce `seteuid`**

Le `CLAUDE.md` du dépôt affirme la croyance exacte que le correctif invalide. Ligne 33 :

```diff
-- **`seteuid`** : le script tourne avec les droits du compte qui se déconnecte.
+- **`seteuid`** : conservé sur la ligne PAM, mais **non fiable** (euid=0 observé
+  malgré lui) — le script ne s'y fie plus : il abaisse lui-même ses privilèges vers
+  le compte cible (`setpriv --reuid --regid --init-groups`, puis ré-exécution en
+  `--wipe <home>` bornée par `timeout 5`) avant toute ouverture de fichier. C'est là
+  qu'est la frontière de sécurité. Le mode installé est `0755` — un mode plus strict
+  rendrait la ré-exécution abaissée impossible et le mécanisme silencieusement
+  inopérant.
```

Aucune autre modification du `CLAUDE.md` : sa réduction éventuelle est hors thème.

- [ ] **Étape 7 : relecture de cohérence**

Exécuter :

```bash
grep -rn '750' README.md CLAUDE.md ansible/README.md docs/manual-verification.md || echo AUCUNE-MENTION-750
```

Attendu : la seule mention restante de `750` est celle du check 10 du runbook (et
de la note 2026-09-01 si formulée avec « 0750 »), qui décrivent l'**ancien** état
à faire converger — toute autre mention est un oubli à corriger.

---

### Tâche 6 : vérification finale — exécuter les trois suites

**Fichiers :** aucun fichier modifié. Cette tâche exécute et **rapporte la sortie
réelle** — jamais « devrait passer ».

- [ ] **Étape 1 : exécuter les trois suites**

```bash
bash tests/test_wipe_history_on_logout.sh; echo "exit:$?"
bash tests/test_install.sh; echo "exit:$?"
bash tests/test_ansible_sync.sh; echo "exit:$?"
```

Attendu :

- `test_wipe_history_on_logout.sh` : 11 `PASS`, `exit:0`.
- `test_install.sh` : 4 `PASS`, `exit:0`.
- `test_ansible_sync.sh` : 2 `PASS` (les tests de mode) et 1 `FAIL`
  (`standalone role's inline script content matches …`), `exit:1` — voir étape 2.

- [ ] **Étape 2 : qualifier l'échec PyYAML (connu, hors thème)**

Le test de non-dérive dépend de PyYAML, absent de cette machine — constat hors
thème déjà porté au `KANBAN.md`, **ne pas corriger la dépendance**. Distinguer
l'échec connu d'une vraie régression :

```bash
python3 -c "import yaml" 2>&1
```

- `ModuleNotFoundError: No module named 'yaml'` → le `FAIL` est l'échec
  d'environnement connu. Confirmer alors la non-dérive par la voie sans PyYAML
  (même commande qu'en tâche 3, étape 6) :

  ```bash
  awk 'f && /^- name:/{exit} f {sub(/^      /,""); print} /^    content: \|$/{f=1}' \
      ansible/roles/ssh_history_wipe_standalone/tasks/main.yml \
      | sed -e '${/^$/d}' \
      | diff - files/wipe-history-on-logout.sh && echo NON-DERIVE-OK
  ```

  Attendu : `NON-DERIVE-OK`. La suite est alors considérée verte au sens de ce
  cycle.
- Si `import yaml` **réussit** et que le test échoue quand même → vraie dérive
  inline↔canonique : régression de la tâche 3, à corriger avant de conclure.

- [ ] **Étape 3 : vérifier les harnais Docker sans les exécuter**

```bash
bash -n tests/docker/run-docker-verification.sh && bash -n tests/docker/run-ansible-docker-verification.sh && echo SYNTAXE-OK
```

Attendu : `SYNTAXE-OK`. Rappeler explicitement dans le rapport final que ces
harnais **n'ont pas été exécutés** (démon Docker absent) et que les critères 11 à
16 de la spec restent à prouver via `docs/manual-verification.md` (checks 2, 3, 7,
8, 9, 10) sur un vrai host AlmaLinux — exécution humaine, hors de ce plan.

- [ ] **Étape 4 : rapport**

Rapporter la sortie brute des trois suites, le verdict PyYAML (étape 2) et l'état
des harnais Docker (étape 3). Aucun critère ne se conclut sur un code de retour
seul : citer les lignes `PASS`/`FAIL` réelles.

---

## Couverture des critères de la spec

| Critère | Où |
|---|---|
| 1 (symlink, témoin intact) | T1, `test_symlink_history_leaves_witness_intact` |
| 2 (chemin abaissé de bout en bout) | T1, `test_pam_exec_path_wipes_history_end_to_end` |
| 3 (FIFO intacte, pas de blocage) | T1, `test_fifo_history_left_in_place` |
| 4 (historique absent non créé) | T1, `test_absent_history_not_created` |
| 5 (open_session no-op) | T1, `test_main_skips_open_session` (existant) |
| 6 (`PAM_USER` inconnu) | T1, `test_main_unknown_user_writes_nothing` |
| 7 (mode 0755, trois voies) | T2 (`test_installs_script_with_correct_mode`) + T3 (2 tests de mode) |
| 8 (convergence depuis 0750) | T2, `test_converges_from_old_mode_750` |
| 9 (non-dérive inline) | T3 (test PyYAML conservé + preuve awk) |
| 10 (ligne PAM unique) | T2, `test_rerun_does_not_duplicate_pam_line` (existant) |
| 11 (preuve de fermeture de la faille) | T5, runbook check 8 — exécution humaine |
| 12 (FIFO, déconnexion non retardée) | T5, runbook check 9 — exécution humaine |
| 13 (non-régression fonctionnelle) | runbook check 2 existant, inchangé |
| 14 (session root) | runbook check 3 existant, inchangé |
| 15 (non-régression audit) | runbook check 7 existant, inchangé |
| 16 (convergence Ansible) | T5, runbook check 10 — exécution humaine |

## Notes de rédaction (vérifiées à l'écriture de ce plan)

- Tous les extraits de code de ce plan ont été **exécutés et validés** en
  scratchpad avant écriture : la suite de la tâche 1 rend 11/11 `PASS` contre le
  nouveau corps et exactement les 4 `FAIL` annoncés contre l'ancien ; le test de
  convergence de la tâche 2 rend `755`/corps identique contre l'installeur corrigé
  et `750` contre l'actuel ; l'aller-retour indentation `sed` ↔ extraction `awk`
  de la tâche 3 est prouvé octet pour octet ; `setpriv`, `timeout` et `getent`
  sont présents localement ; PyYAML est absent (`ModuleNotFoundError` reproduit).
- Le harnais Docker n'acquiert **aucun nouveau check** (automatiser les critères
  11/12/16 serait un choix possible, mais livrer du code Docker invérifiable ici
  serait du non-exécuté ; le niveau normatif reste le runbook — conforme à la
  spec, « Hors périmètre »).
- `CLAUDE.md` du dépôt affirmait « `seteuid` : le script tourne avec les droits du
  compte qui se déconnecte » — exactement la croyance fausse à l'origine de la
  faille. **Arbitrage du maître : périmètre élargi à cette seule puce**, corrigée en
  tâche 5, étape 6.
- **Arbitrage du maître sur git** : la contrainte globale « aucune commande git »
  proposée par le rédacteur est remplacée par la variante « implémenteur » du cycle
  — chaque tâche commite sur la branche du cycle, conformément à
  `superpowers:subagent-driven-development`.
