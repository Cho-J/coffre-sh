#!/usr/bin/env bash
#===============================================================================
#  coffre.sh — coffre chiffré LUKS + clés GPG + accès SSH
#  Projet académique — administration Linux avancée
#
#  Chaîne imposée : dd -> losetup -> luksFormat -> luksOpen -> mkfs.ext4
#
#  Verbes : install | open | close | export | import | ssh
#  Raccourcis (.bashrc) : O=open C=close I=import IP=import --private
#                         E=export EP=export --private S=ssh   (maj -> pas de conflit 'ip')
#  Journal : $VAULT_MOUNT/journal.log (dans le coffre, append-only +a)
#
#  Idée clé : moindre privilège. root pour LUKS/mount ; GPG/SSH via run_as_user
#  sous l'utilisateur réel ($SUDO_USER) -> clés dans SON trousseau, pas /root.
#===============================================================================

# garde-fous : -e stop si erreur / -u var non définie = erreur / pipefail
# IFS sans espace -> pas de word-splitting accidentel (remis localement au besoin)
set -euo pipefail
IFS=$'\n\t'

#-------------------------------------------------------------------------------
# 0. CONFIG (tout surchargeable par variable d'env)
#-------------------------------------------------------------------------------
VAULT_CONTAINER="${VAULT_CONTAINER:-/opt/coffre/coffre.img}"  # fichier conteneur
VAULT_MOUNT="${VAULT_MOUNT:-/mnt/coffre}"                     # point de montage
VAULT_MAPPER="${VAULT_MAPPER:-sec_env}"                       # nom mapping LUKS
VAULT_SIZE_GB="${VAULT_SIZE_GB:-5}"                           # 5 Go imposé
VAULT_LABEL="${VAULT_LABEL:-coffre}"                          # label ext4
# /dev/zero = rapide (démo) ; /dev/urandom = plus sûr mais lent
DD_SOURCE="${DD_SOURCE:-/dev/zero}"

# GPG : clé générée par install, SANS e-mail (UID = nom). Ciblage par fingerprint.
GPG_NAME="${GPG_NAME:-soutenance_key}"
GPG_KEYSIZE="${GPG_KEYSIZE:-4096}"
GPG_EXPIRE="${GPG_EXPIRE:-1y}"
GPG_ID="${GPG_ID:-$GPG_NAME}"   # réécrit avec le fingerprint dans install

# utilisateur réel (avant sudo) -> pour ne pas écrire dans /root
REAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6)"
REAL_HOME="${REAL_HOME:-$HOME}"

# chemin absolu du script (figé dans les raccourcis O/C/... -> marchent partout)
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "$0")"

# chemins internes au coffre
V_GPG_DIR="$VAULT_MOUNT/gpg"
V_GPG_PUB="$V_GPG_DIR/public"
V_GPG_PRIV="$V_GPG_DIR/private"
V_SSH_DIR="$VAULT_MOUNT/ssh"
V_SSH_CONF="$V_SSH_DIR/config"
V_SSH_KEYS="$V_SSH_DIR/keys"
V_SSH_ALIAS="$V_SSH_DIR/evsh.aliases"
V_JOURNAL="$VAULT_MOUNT/journal.log"                  # journal (dans le coffre)
ALIAS_LINK="$REAL_HOME/.config/coffre-aliases"        # symlink vers l'alias evsh
SHORTCUTS_FILE="$REAL_HOME/.config/coffre-shortcuts"  # raccourcis (sourcé par .bashrc)

# gpg ou gpg2 selon la distrib
GPG_BIN="$(command -v gpg 2>/dev/null || command -v gpg2 2>/dev/null || true)"

SUBCMD=""   # rempli par le dispatcher (messages d'erreur)

#-------------------------------------------------------------------------------
# 1. FONCTIONS UTILITAIRES
#-------------------------------------------------------------------------------
info() { printf '[INFO] %s\n'  "$*"; }              # message neutre
ok()   { printf '[OK]   %s\n'  "$*"; }              # succès
warn() { printf '[ATTN] %s\n'  "$*" >&2; }          # avertissement (sur stderr)
die()  { printf '[ERR]  %s\n'  "$*" >&2; exit 1; }  # erreur fatale -> quitte

# journal : ligne horodatée dans le coffre. Seulement si monté.
# lève +a, écrit, repose +a. Erreurs silencieuses (ne doit rien casser).
journal() {
    local action="$*" ts
    mountpoint -q "$VAULT_MOUNT" 2>/dev/null || return 0   # rien si coffre fermé
    ts="$(date '+%Y-%m-%d %H:%M:%S')"                       # horodatage
    chattr -a "$V_JOURNAL" 2>/dev/null || true             # lever append-only
    printf '%s  %-12s  %s\n' "$ts" "$REAL_USER" "$action" >> "$V_JOURNAL" 2>/dev/null || true   # ajoute la ligne
    chown_real "$V_JOURNAL" 2>/dev/null || true            # rendre à l'utilisateur
    chmod 640 "$V_JOURNAL" 2>/dev/null || true             # perms
    chattr +a "$V_JOURNAL" 2>/dev/null || true             # re-verrouille +a
}

# confirm y/N : vrai seulement si y/Y/o/O. Vide = non.
confirm() {
    local prompt="$1" ans=""
    printf '%s [y/N] ' "$prompt" >&2   # question sur stderr
    IFS= read -r ans || true           # lit la réponse
    case "$ans" in
        [yY]|[oO]) return 0 ;;         # oui
        *)         return 1 ;;         # tout le reste = non
    esac
}

# root requis (losetup/cryptsetup/mount). On explique, on ne force pas sudo.
need_root() {
    [ "$(id -u)" -eq 0 ] || die "Sous-commande '$SUBCMD' : privilèges root requis (losetup/cryptsetup/mount). Relancez : sudo $0 $SUBCMD"
}

# vérifie les binaires requis, les signale tous d'un coup
need_deps() {
    local d miss=()
    for d in "$@"; do command -v "$d" >/dev/null 2>&1 || miss+=("$d"); done   # collecte les absents
    [ "${#miss[@]}" -eq 0 ] || die "Dépendances manquantes : ${miss[*]}"      # échoue si liste non vide
}

# installe les deps si absentes (poste autonome). Idempotent. apt-get (stable en script).
bootstrap_deps() {
    if command -v cryptsetup >/dev/null 2>&1 \
    && command -v gpg        >/dev/null 2>&1 \
    && command -v ssh        >/dev/null 2>&1; then
        return 0                          # tout est là -> ne rien faire (idempotent)
    fi

    if command -v apt-get >/dev/null 2>&1; then
        info "Installation des dépendances (cryptsetup, gnupg, openssh-client)..."
        apt-get update                    # rafraîchir les listes
        apt-get install -y cryptsetup gnupg openssh-client
        GPG_BIN="$(command -v gpg 2>/dev/null || command -v gpg2 2>/dev/null || true)"  # recalcul chemin
    else
        warn "apt-get introuvable : installez manuellement cryptsetup, gnupg et openssh-client."
    fi
}

# exécute une commande sous l'utilisateur réel (redescend de root si besoin)
run_as_user() {
    if [ "$(id -u)" -eq 0 ] && [ "$REAL_USER" != "root" ]; then
        sudo -u "$REAL_USER" -- "$@"      # root -> on redescend vers l'utilisateur
    else
        "$@"                              # déjà utilisateur : exécuter tel quel
    fi
}

# rend un fichier à l'utilisateur réel (no-op si pas root)
chown_real() {
    if [ "$(id -u)" -eq 0 ] && [ "$REAL_USER" != "root" ]; then
        chown "$REAL_USER":"$(id -gn "$REAL_USER")" "$@"   # user:groupe
    fi
}

is_mounted() { mountpoint -q "$VAULT_MOUNT"; }              # coffre monté ?
mapper_exists() { [ -e "/dev/mapper/$VAULT_MAPPER" ]; }     # mapping LUKS ouvert ?

# loop device associé au conteneur (vide si aucun)
loop_of() {
    losetup -j "$VAULT_CONTAINER" 2>/dev/null | awk -F: 'NR==1{print $1}'   # -j = cherche par fichier
}

#-------------------------------------------------------------------------------
# 2. TEMPLATES ÉCRITS DANS LE COFFRE
#-------------------------------------------------------------------------------
# config SSH durcie, utilisable via ssh -F
_write_ssh_template() {
    cat > "$V_SSH_CONF" <<EOF
# Config SSH du coffre — ssh -F "$V_SSH_CONF"
Host *
    # n'offrir QUE la clé IdentityFile (anti key-fishing)
    IdentitiesOnly yes
    # confirme si la clé d'hôte change (anti-MITM)
    StrictHostKeyChecking ask
    HashKnownHosts yes
    # known_hosts propre au coffre (rien ne fuit vers ~/.ssh)
    UserKnownHostsFile $V_SSH_DIR/known_hosts
    ServerAliveInterval 60
    ServerAliveCountMax 3

# --- hôtes importés ajoutés ci-dessous ---
# Exemple de bloc :
#   Host p2
#       HostName 192.0.2.2
#       User root
#       IdentityFile $V_SSH_KEYS/id_p2
EOF
}

# alias evsh (imposé par le sujet)
_write_alias_file() {
    cat > "$V_SSH_ALIAS" <<EOF
# alias du coffre — chargé quand le coffre est monté
alias evsh="ssh -F $V_SSH_CONF"
EOF
}

# écrit les raccourcis O/C/I/IP/E/EP/S + le bandeau de prompt, sourcés par .bashrc.
# chemin du script figé (absolu) -> marchent partout. Fichier HORS coffre (sinon
# O/... disparaîtraient coffre fermé). Aucun secret dedans.
_write_shortcuts_file() {
    run_as_user mkdir -p "$REAL_HOME/.config"
    # heredoc non-quoté : fige $SCRIPT_PATH/$VAULT_MOUNT ; \$ = variables runtime
    run_as_user tee "$SHORTCUTS_FILE" >/dev/null <<EOF
# raccourcis du coffre (généré) — sourcé par ~/.bashrc
# script figé : $SCRIPT_PATH
_COFFRE_SCRIPT="$SCRIPT_PATH"
_COFFRE_MOUNT="$VAULT_MOUNT"

# coffre monté ? (0 = oui)
_coffre_is_open() { mountpoint -q "\$_COFFRE_MOUNT" 2>/dev/null; }

# bandeau (coffre ouvert) : recalculé à chaque prompt -> apparaît/disparaît seul
_coffre_prompt() {
    if _coffre_is_open; then
        case "\${PS1:-}" in
            *"(coffre ouvert)"*) : ;;
            *) PS1="(coffre ouvert) \${PS1:-}" ;;
        esac
    else
        PS1="\${PS1:-}"; PS1="\${PS1/(coffre ouvert) /}"
    fi
}
case "\${PROMPT_COMMAND:-}" in
    *_coffre_prompt*) : ;;
    *) PROMPT_COMMAND="_coffre_prompt\${PROMPT_COMMAND:+; \$PROMPT_COMMAND}" ;;
esac

# raccourcis (maj -> pas de conflit avec 'ip')
# O : cd fait ici (un script ne peut pas cd le shell parent)
O() {
    sudo "\$_COFFRE_SCRIPT" open && cd "\$_COFFRE_MOUNT" || return
}
# C : sortir du coffre d'abord (sinon umount échoue : répertoire occupé)
C() {
    case "\$PWD" in "\$_COFFRE_MOUNT"*) cd "\$HOME" ;; esac
    sudo "\$_COFFRE_SCRIPT" close
}
S()  { "\$_COFFRE_SCRIPT" ssh "\$@"; }              # import SSH différé
I()  { "\$_COFFRE_SCRIPT" import "\$@"; }           # import GPG pub
IP() { "\$_COFFRE_SCRIPT" import --private "\$@"; } # + priv
E()  { "\$_COFFRE_SCRIPT" export "\$@"; }           # export GPG pub
EP() { "\$_COFFRE_SCRIPT" export --private "\$@"; } # + priv
EOF
    chown_real "$SHORTCUTS_FILE" 2>/dev/null || true
    chmod 644 "$SHORTCUTS_FILE" 2>/dev/null || true
}

# symlink alias evsh + sourcing alias & raccourcis dans .bashrc (idempotent)
_install_alias_symlink() {
    run_as_user mkdir -p "$REAL_HOME/.config"
    run_as_user ln -sfn "$V_SSH_ALIAS" "$ALIAS_LINK"   # -n/-f : écrase proprement
    local bashrc="$REAL_HOME/.bashrc"

    # alias evsh (cible dans le coffre : [ -r ] -> inoffensif si absent)
    if ! run_as_user grep -qF "$ALIAS_LINK" "$bashrc" 2>/dev/null; then
        printf '\n# Alias du coffre (généré par coffre.sh)\n[ -r "%s" ] && . "%s"\n' \
            "$ALIAS_LINK" "$ALIAS_LINK" | run_as_user tee -a "$bashrc" >/dev/null
    fi

    # raccourcis O/C/... (hors coffre : toujours dispos)
    if ! run_as_user grep -qF "$SHORTCUTS_FILE" "$bashrc" 2>/dev/null; then
        printf '\n# Raccourcis du coffre (généré par coffre.sh)\n[ -r "%s" ] && . "%s"\n' \
            "$SHORTCUTS_FILE" "$SHORTCUTS_FILE" | run_as_user tee -a "$bashrc" >/dev/null
    fi
}

#-------------------------------------------------------------------------------
# 3. PARSING SSH (~/.ssh/config)
#-------------------------------------------------------------------------------
# liste les hosts déclarés (hors joker *), dédupliqués
ssh_list_hosts() {
    local cfg="$1" line trimmed kw rest tok
    while IFS= read -r line || [ -n "$line" ]; do    # lit ligne par ligne (|| -n : dernière sans \n)
        trimmed="${line#"${line%%[![:space:]]*}"}"   # left-trim (retire espaces de début)
        trimmed="${trimmed%%#*}"                      # vire commentaire de fin
        [ -z "${trimmed//[[:space:]]/}" ] && continue # ligne vide -> suivante
        IFS=$' \t' read -r kw rest <<<"$trimmed"      # kw = 1er mot, rest = le reste
        [ "${kw,,}" = "host" ] || continue            # garde que les lignes "Host" (insensible casse)
        local -a toks=()
        IFS=$' \t' read -ra toks <<<"$rest"           # découpe les noms de host
        for tok in "${toks[@]}"; do
            [ "$tok" = "*" ] && continue              # ignore le joker
            printf '%s\n' "$tok"                       # sort chaque host
        done
    done < "$cfg" | awk 'NF' | sort -u                # awk NF = non vide ; sort -u = dédup
    return 0
}

# extrait le bloc complet d'un host donné
ssh_extract_block() {
    local target="$1" cfg="$2" line trimmed kw rest tok in_block=0
    local -a toks
    while IFS= read -r line || [ -n "$line" ]; do
        trimmed="${line#"${line%%[![:space:]]*}"}"    # left-trim
        IFS=$' \t' read -r kw rest <<<"${trimmed%%#*}" # kw = mot-clé de la ligne
        if [ "${kw,,}" = "host" ]; then               # début d'un nouveau bloc Host
            in_block=0                                 # on sort du bloc précédent
            IFS=$' \t' read -ra toks <<<"$rest"
            for tok in "${toks[@]}"; do
                [ "$tok" = "$target" ] && in_block=1   # notre cible ? (gère "Host p1 p2")
            done
        fi
        [ "$in_block" -eq 1 ] && printf '%s\n' "$line" # dans le bon bloc -> on recopie la ligne
    done < "$cfg"
    return 0   # dernier test peut être faux -> éviter que set -e casse $(...)
}

#-------------------------------------------------------------------------------
# 4. ÉTAPES INTERNES DE 'install' : gen GPG + import SSH
#-------------------------------------------------------------------------------
# génère la paire GPG (batch, sans e-mail) + export auto de la pub dans le coffre.
# idempotent (clé déjà là = pas régénérée). À la fin GPG_ID = fingerprint.
_install_gen_gpg() {
    [ -n "$GPG_BIN" ] || { warn "gpg introuvable : génération GPG ignorée."; return 0; }

    if run_as_user "$GPG_BIN" --list-keys "$GPG_NAME" >/dev/null 2>&1; then
        info "Clé GPG « $GPG_NAME » déjà présente — génération ignorée."   # idempotence
    else
        # passphrase jamais en dur : saisie interactive (-s = masquée)
        local pass1 pass2
        printf 'Passphrase de la NOUVELLE clé GPG (vide = %%no-protection, DÉCONSEILLÉ) : ' >&2
        IFS= read -rs pass1; echo >&2
        printf 'Confirmez la passphrase : ' >&2
        IFS= read -rs pass2; echo >&2
        [ "$pass1" = "$pass2" ] || die "Les passphrases GPG ne correspondent pas."  # doivent matcher

        # params batch : mktemp (600), détruit au shred. Pas de Name-Email -> UID = nom
        local param; param="$(run_as_user mktemp)"
        {
            echo "%echo Génération de la paire GPG ($GPG_KEYSIZE bits, sans e-mail)..."
            echo "Key-Type: RSA";    echo "Key-Length: $GPG_KEYSIZE"   # clé primaire
            echo "Subkey-Type: RSA"; echo "Subkey-Length: $GPG_KEYSIZE" # sous-clé
            echo "Name-Real: $GPG_NAME"                                 # UID = nom seul
            echo "Expire-Date: $GPG_EXPIRE"                             # expiration
            if [ -n "$pass1" ]; then echo "Passphrase: $pass1"; else echo "%no-protection"; fi
            echo "%commit"; echo "%echo Termine."                       # valide la génération
        } | run_as_user tee "$param" >/dev/null                         # écrit le fichier de params

        local -a gpgargs=(--batch)
        [ -n "$pass1" ] && gpgargs+=(--pinentry-mode loopback)   # requis pour passphrase en batch
        gpgargs+=(--full-generate-key "$param")
        run_as_user "$GPG_BIN" "${gpgargs[@]}"                   # génère la clé

        run_as_user shred -u "$param" 2>/dev/null || run_as_user rm -f "$param"  # efface la passphrase
    fi

    # fingerprint (champ fpr, 1er = clé primaire) -> ciblage sans ambiguïté
    local fpr
    fpr="$(run_as_user "$GPG_BIN" --with-colons --fingerprint "$GPG_NAME" 2>/dev/null \
            | awk -F: '/^fpr:/{print $10; exit}')"
    if [ -n "$fpr" ]; then
        GPG_ID="$fpr"
        info "Fingerprint de la clé : $GPG_ID"
    else
        warn "Fingerprint introuvable : ciblage par nom « $GPG_NAME »."
        GPG_ID="$GPG_NAME"
    fi

    # export auto de la pub (Partie II)
    local pub="$V_GPG_PUB/${GPG_NAME}.pub.asc"
    run_as_user "$GPG_BIN" --armor --export "$GPG_ID" > "$pub"
    chown_real "$pub"; chmod 644 "$pub"
    ok "Clé publique GPG exportée -> $pub"
}

# importe UN host : copie ses clés dans le coffre, réécrit IdentityFile.
# amélioration 7 : régénère la .pub manquante via ssh-keygen -y (paire complète).
_import_one_host() {
    local target="$1" src="$2"
    local block; block="$(ssh_extract_block "$target" "$src")"
    [ -n "$block" ] || { warn "Bloc introuvable pour '$target' : ignoré."; return 0; }

    local out="" line trimmed kw rest keypath base
    while IFS= read -r line || [ -n "$line" ]; do
        trimmed="${line#"${line%%[![:space:]]*}"}"             # left-trim
        IFS=$' \t' read -r kw rest <<<"${trimmed%%#*}"         # kw = mot-clé
        if [ "${kw,,}" = "identityfile" ]; then                # ligne de clé -> à réécrire
            keypath="$rest"
            keypath="${keypath%\"}"; keypath="${keypath#\"}"       # vire guillemets
            keypath="${keypath/#\~/$REAL_HOME}"                    # expansion ~
            case "$keypath" in "\$HOME"*) keypath="${keypath/#\$HOME/$REAL_HOME}";; esac  # expansion $HOME
            if [ -f "$keypath" ]; then                             # la clé existe ?
                base="$(basename "$keypath")"                      # nom de fichier seul
                cp "$keypath" "$V_SSH_KEYS/$base"                  # copie la privée dans le coffre
                chmod 600 "$V_SSH_KEYS/$base"; chown_real "$V_SSH_KEYS/$base"   # perms privée
                # .pub : copie si présente, sinon régénère depuis la privée
                if [ -f "$keypath.pub" ]; then
                    cp "$keypath.pub" "$V_SSH_KEYS/$base.pub"      # .pub existe -> copie
                elif ssh-keygen -y -f "$V_SSH_KEYS/$base" > "$V_SSH_KEYS/$base.pub" 2>/dev/null; then
                    info "Clé publique absente : régénérée depuis la privée ($base.pub)."  # amélioration 7
                else
                    warn "Clé publique absente et non régénérable pour $base (clé chiffrée ?)."
                    rm -f "$V_SSH_KEYS/$base.pub"                  # nettoie le fichier vide
                fi
                if [ -f "$V_SSH_KEYS/$base.pub" ]; then
                    chmod 644 "$V_SSH_KEYS/$base.pub"; chown_real "$V_SSH_KEYS/$base.pub"  # perms pub
                fi
                out+="    IdentityFile $V_SSH_KEYS/$base"$'\n'   # réécrit -> pointe vers la copie
                info "Clé copiée : $keypath -> $V_SSH_KEYS/$base"
            else
                warn "IdentityFile introuvable : $keypath (ligne conservée telle quelle)."
                out+="$line"$'\n'                               # clé absente : on garde la ligne
            fi
        else
            out+="$line"$'\n'                                   # autre ligne : recopiée telle quelle
        fi
    done <<<"$block"

    printf '\n%s' "$out" >> "$V_SSH_CONF"                       # ajoute le bloc à la config du coffre
    chmod 600 "$V_SSH_CONF"; chown_real "$V_SSH_CONF"
    ok "Host '$target' importé dans $V_SSH_CONF"
    journal "SSH-IMPORT host=$target"                          # trace
}

# liste les hosts et propose : un / tous / aucun. Utilisé par install et le verbe ssh.
_ssh_import_interactive() {
    local src="$REAL_HOME/.ssh/config"
    if [ ! -f "$src" ]; then
        info "Aucun $src : import SSH ignoré (vous pourrez remplir $V_SSH_CONF plus tard)."
        return 0
    fi

    local hosts; hosts="$(ssh_list_hosts "$src")"
    if [ -z "$hosts" ]; then
        info "Aucun host exploitable dans $src : import SSH ignoré."
        return 0
    fi

    info "Hosts détectés dans $src :"
    printf '%s\n' "$hosts" | sed 's/^/  - /' >&2      # affiche la liste
    printf 'Importer : un nom de host précis, "all" pour TOUS, ou vide/"none" pour AUCUN : ' >&2
    local choice; IFS= read -r choice

    case "$choice" in
        ""|none|NONE)
            info "Aucun host choisi : import SSH ignoré." ;;   # rien
        all|ALL|tous|TOUS)
            local h
            while IFS= read -r h; do                            # boucle sur tous les hosts
                [ -n "$h" ] && _import_one_host "$h" "$src"
            done <<<"$hosts"
            ok "Tous les hosts ont été importés." ;;
        *)
            if printf '%s\n' "$hosts" | grep -qxF "$choice"; then   # le choix existe ?
                _import_one_host "$choice" "$src"                   # un seul host
            else
                warn "Host '$choice' absent de la liste : ignoré."  # saisie invalide
            fi ;;
    esac
}

#-------------------------------------------------------------------------------
# 5. SOUS-COMMANDE : install
#-------------------------------------------------------------------------------
cmd_install() {
    need_root
    bootstrap_deps                                              # deps auto
    need_deps dd losetup cryptsetup mkfs.ext4 chattr mount      # binaires requis
    [ -n "$GPG_BIN" ] || warn "gpg introuvable : 'export'/'import' ne fonctionneront pas."

    # refuser si déjà monté (éviter double attachement)
    if is_mounted; then die "Un coffre est monté sur $VAULT_MOUNT. Fermez-le d'abord : $0 close"; fi

    mkdir -p "$(dirname "$VAULT_CONTAINER")"                    # crée /opt/coffre si besoin

    # coffre LUKS déjà existant -> demander confirmation avant d'écraser
    if [ -f "$VAULT_CONTAINER" ]; then
        chattr -i "$VAULT_CONTAINER" 2>/dev/null || true       # lever +i pour pouvoir tester/écraser
        local tl; tl="$(losetup --find --show "$VAULT_CONTAINER")"   # attache temporairement
        if cryptsetup isLuks "$tl" 2>/dev/null; then           # est-ce déjà un coffre LUKS ?
            losetup -d "$tl"                                   # détache
            warn "Un coffre LUKS existe déjà : $VAULT_CONTAINER"
            confirm "Tout EFFACER et réinitialiser ?" \
                || { chattr +i "$VAULT_CONTAINER" 2>/dev/null || true; die "Réinstallation annulée."; }  # refus -> on repose +i
        else
            losetup -d "$tl"                                   # pas LUKS : simple détache
        fi
    fi

    # chaîne imposée : dd -> losetup -> luksFormat -> luksOpen -> mkfs.ext4
    info "Création du conteneur ${VAULT_SIZE_GB} Go (dd depuis $DD_SOURCE)..."
    dd if="$DD_SOURCE" of="$VAULT_CONTAINER" bs=1M count=$((VAULT_SIZE_GB*1024)) status=progress  # crée le fichier
    chmod 600 "$VAULT_CONTAINER"          # conteneur : propriétaire seul

    local loop; loop="$(losetup --find --show "$VAULT_CONTAINER")"   # -f + attach : fichier -> /dev/loopN
    info "Loop device attaché : $loop"

    # rollback : si la chaîne échoue, pas de mapping/loop orphelin (comme open)
    local st_map=0 st_mnt=0
    _install_cleanup() {
        warn "Échec pendant l'installation — nettoyage en cours..."
        [ "$st_mnt" -eq 1 ] && { umount "$VAULT_MOUNT" 2>/dev/null || true; }             # démonter si monté
        [ "$st_map" -eq 1 ] && { cryptsetup luksClose "$VAULT_MAPPER" 2>/dev/null || true; }  # fermer LUKS si ouvert
        losetup -d "$loop" 2>/dev/null || true                                            # détacher le loop
        exit 1
    }
    trap _install_cleanup ERR    # armer le rollback

    info "luksFormat (LUKS2) — définissez la passphrase du coffre :"
    cryptsetup luksFormat -q --type luks2 "$loop"   # -q : pas de « YES » de cryptsetup ; installe la serrure
    info "luksOpen — saisissez la passphrase pour déverrouiller :"
    cryptsetup luksOpen "$loop" "$VAULT_MAPPER"     # ouvre -> /dev/mapper/sec_env
    st_map=1

    mkfs.ext4 -q -L "$VAULT_LABEL" "/dev/mapper/$VAULT_MAPPER"   # formate le volume déchiffré
    mkdir -p "$VAULT_MOUNT"
    mount "/dev/mapper/$VAULT_MAPPER" "$VAULT_MOUNT"             # monte le coffre
    st_mnt=1
    trap - ERR     # chaîne OK : désarmer le rollback

    # arborescence + templates
    mkdir -p "$V_GPG_PUB" "$V_GPG_PRIV" "$V_SSH_KEYS"   # dossiers internes
    _write_ssh_template                                 # config SSH durcie
    _write_alias_file                                   # alias evsh

    # journal en append-only (+a)
    : > "$V_JOURNAL"                                     # crée le fichier vide
    chown_real "$V_JOURNAL"; chmod 640 "$V_JOURNAL"
    chattr +a "$V_JOURNAL" 2>/dev/null || warn "chattr +a non appliqué au journal (fs non compatible ?)."
    journal "INSTALL conteneur=$VAULT_CONTAINER taille=${VAULT_SIZE_GB}Go"

    # Partie II : gen GPG + export auto pub
    info "== Génération de la clé GPG =="
    _install_gen_gpg
    journal "GPG-GEN id=$GPG_ID"

    # Partie III : import SSH (un / tous / aucun)
    info "== Import SSH (un host, tous, ou aucun) =="
    _ssh_import_interactive

    # permissions : 700 dossiers privés, 600 config
    chmod 700 "$VAULT_MOUNT" "$V_GPG_DIR" "$V_GPG_PUB" "$V_GPG_PRIV" "$V_SSH_DIR" "$V_SSH_KEYS"
    chmod 600 "$V_SSH_CONF" 2>/dev/null || true
    chmod 644 "$V_SSH_ALIAS"
    # rendre le contenu à l'utilisateur (journal déjà chown-é, il est +a)
    chown -R "$REAL_USER":"$(id -gn "$REAL_USER")" "$VAULT_MOUNT" 2>/dev/null || true

    # raccourcis + alias dans .bashrc
    _write_shortcuts_file
    _install_alias_symlink

    ok "Coffre installé et monté sur $VAULT_MOUNT (GPG générée, SSH importé)."
    info "Raccourcis dans un NOUVEAU terminal (ou après 'source ~/.bashrc') :"
    info "  O = ouvrir(+entrer)   C = fermer   S = importer un host SSH"
    info "  I / IP = import GPG (pub / +priv)   E / EP = export GPG (pub / +priv)"
    info "Connexion SSH : evsh <host>"
    info "Vous travaillez dans : $VAULT_MOUNT"
}

#-------------------------------------------------------------------------------
# 6. SOUS-COMMANDE : open  (rollback via trap)
#-------------------------------------------------------------------------------
cmd_open() {
    need_root
    need_deps cryptsetup losetup mount
    [ -f "$VAULT_CONTAINER" ] || die "Conteneur introuvable : $VAULT_CONTAINER (lancez 'install')."
    if is_mounted; then ok "Déjà ouvert et monté sur $VAULT_MOUNT."; return 0; fi   # déjà ouvert

    # drapeaux d'état, lus par le nettoyage
    local st_loop="" st_map=0 st_mount=0

    # nettoyage : défait dans l'ordre inverse ce qui a été fait
    _open_cleanup() {
        warn "Échec pendant l'ouverture — nettoyage en cours..."
        [ "$st_mount" -eq 1 ] && { umount "$VAULT_MOUNT" 2>/dev/null || true; }              # démonter
        [ "$st_map"   -eq 1 ] && { cryptsetup luksClose "$VAULT_MAPPER" 2>/dev/null || true; } # fermer LUKS
        [ -n "$st_loop" ]      && { losetup -d "$st_loop" 2>/dev/null || true; }              # détacher loop
        chattr +i "$VAULT_CONTAINER" 2>/dev/null || true    # ré-immuabiliser au repos
        exit 1
    }
    trap _open_cleanup ERR    # armer le rollback

    # 1) lever +i (losetup a besoin d'écrire)
    chattr -i "$VAULT_CONTAINER" 2>/dev/null || true

    # 2) loop : réutiliser si déjà attaché, sinon en trouver un
    local loop; loop="$(loop_of || true)"
    if [ -z "$loop" ]; then loop="$(losetup --find --show "$VAULT_CONTAINER")"; fi
    st_loop="$loop"

    # 3) LUKS (passphrase interactive) ; échec -> rollback
    if ! mapper_exists; then cryptsetup luksOpen "$loop" "$VAULT_MAPPER"; fi   # ouvre si pas déjà ouvert
    st_map=1

    # 4) montage
    mkdir -p "$VAULT_MOUNT"
    mount "/dev/mapper/$VAULT_MAPPER" "$VAULT_MOUNT"
    st_mount=1

    trap - ERR      # succès : désarmer
    journal "OPEN"  # trace
    ok "Coffre ouvert et monté sur $VAULT_MOUNT"
}

#-------------------------------------------------------------------------------
# 7. SOUS-COMMANDE : close
#-------------------------------------------------------------------------------
cmd_close() {
    need_root
    local loop; loop="$(loop_of || true)"   # loop courant (avant démontage)

    journal "CLOSE"   # AVANT umount (le journal vit dans le coffre)

    # ordre inverse de open : umount -> luksClose -> losetup -d (chaque étape conditionnelle)
    if is_mounted; then umount "$VAULT_MOUNT"; ok "Démonté."; else info "Rien à démonter."; fi
    if mapper_exists; then cryptsetup luksClose "$VAULT_MAPPER"; ok "Mapping LUKS fermé."; else info "Mapping LUKS déjà fermé."; fi
    if [ -n "$loop" ]; then losetup -d "$loop"; ok "Loop détaché ($loop)."; else info "Aucun loop attaché."; fi

    # +i au repos : ni suppression ni modif, même par root
    if [ -f "$VAULT_CONTAINER" ]; then
        if chattr +i "$VAULT_CONTAINER" 2>/dev/null; then
            ok "Conteneur rendu immuable (chattr +i)."
        else
            warn "chattr +i non appliqué (système de fichiers non compatible ?)."
        fi
    fi
}

#-------------------------------------------------------------------------------
# 8. SOUS-COMMANDE : export  (trousseau -> coffre)
#-------------------------------------------------------------------------------
cmd_export() {
    [ -n "$GPG_BIN" ] || die "gpg introuvable."
    is_mounted || die "Coffre fermé — ouvrez-le d'abord (open)."

    local do_priv=0 id="$GPG_ID"
    while [ $# -gt 0 ]; do                 # parse les options
        case "$1" in
            --private) do_priv=1 ;;        # aussi la privée
            --id) shift; id="${1:?--id requiert une valeur}" ;;  # cible une clé précise
            *) die "Option inconnue pour export : $1" ;;
        esac
        shift
    done

    # pub : toujours exportable, sans risque
    local pub="$V_GPG_PUB/${id}.pub.asc"
    run_as_user "$GPG_BIN" --armor --export "$id" > "$pub"   # --armor = format ASCII
    chown_real "$pub"; chmod 644 "$pub"
    ok "Clé publique exportée -> $pub"
    journal "EXPORT-PUBLIC id=$id"

    # priv : risqué -> avertissement + confirmation
    if [ "$do_priv" -eq 1 ]; then
        warn "EXPORT DE CLÉ PRIVÉE : une clé privée qui fuit = identité GPG compromise."
        warn "À ne faire que pour un changement de poste maîtrisé."
        confirm "Confirmer l'export de la clé PRIVÉE ?" || die "Export privé annulé."
        local sec="$V_GPG_PRIV/${id}.sec.asc"
        ( umask 077; run_as_user "$GPG_BIN" --armor --export-secret-keys "$id" > "$sec" )  # naît en 600
        chown_real "$sec"; chmod 600 "$sec"
        ok "Clé privée exportée (permissions 600) -> $sec"
        journal "EXPORT-PRIVATE id=$id"
    fi
}

#-------------------------------------------------------------------------------
# 9. SOUS-COMMANDE : import  (coffre -> trousseau)
#-------------------------------------------------------------------------------
cmd_import() {
    [ -n "$GPG_BIN" ] || die "gpg introuvable."
    is_mounted || die "Coffre fermé — ouvrez-le d'abord (open)."

    local do_priv=0
    while [ $# -gt 0 ]; do                 # parse les options
        case "$1" in
            --private) do_priv=1 ;;        # aussi la privée
            *) die "Option inconnue pour import : $1" ;;
        esac
        shift
    done

    local f found=0
    for f in "$V_GPG_PUB"/*.asc; do        # toutes les pub du coffre
        [ -e "$f" ] || continue            # aucune -> ignore
        run_as_user "$GPG_BIN" --import "$f"; found=1
    done
    [ "$found" -eq 1 ] && { ok "Clés publiques importées."; journal "IMPORT-PUBLIC"; } || info "Aucune clé publique dans le coffre."

    # priv : risqué -> avertissement + confirmation (le pub ci-dessus est sans risque)
    if [ "$do_priv" -eq 1 ]; then
        warn "IMPORT DE CLÉ PRIVÉE dans le trousseau local (matériel cryptographique sensible)."
        confirm "Confirmer l'import de la/les clé(s) PRIVÉE(s) ?" || die "Import privé annulé."
        found=0
        for f in "$V_GPG_PRIV"/*.asc; do   # toutes les priv du coffre
            [ -e "$f" ] || continue
            run_as_user "$GPG_BIN" --import "$f"; found=1
        done
        [ "$found" -eq 1 ] && { ok "Clés privées importées."; journal "IMPORT-PRIVATE"; } || info "Aucune clé privée dans le coffre."
    fi
}

#-------------------------------------------------------------------------------
# 10. SOUS-COMMANDE : ssh  (import différé, coffre déjà ouvert)
#-------------------------------------------------------------------------------
cmd_ssh() {
    need_deps ssh-keygen                                   # requis pour régénérer les .pub
    is_mounted || die "Coffre fermé — ouvrez-le d'abord (open)."
    info "== Import SSH (un host, tous, ou aucun) =="
    _ssh_import_interactive                                # même logique que dans install
}

#-------------------------------------------------------------------------------
# 11. DISPATCHER
#-------------------------------------------------------------------------------
SUBCMD="${1:-}"    # 1er argument = le verbe
shift || true      # le reste = options passées à la fonction
case "$SUBCMD" in
    install)  cmd_install "$@" ;;
    open)     cmd_open    "$@" ;;
    close)    cmd_close   "$@" ;;
    export)   cmd_export  "$@" ;;
    import)   cmd_import  "$@" ;;
    ssh)      cmd_ssh     "$@" ;;
    *) die "Sous-commande inconnue : '$SUBCMD'. Verbes valides : install | open | close | export | import | ssh" ;;
esac

