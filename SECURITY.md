# Sécurité de coffre.sh

Ce document décrit ce que le script ne protège pas, les faiblesses relevées en lisant le code et les corrections possibles. Les numéros de ligne renvoient à `coffre.sh` dans ce dépôt.

Échelle de gravité :

- **critique** : peut exposer un secret ou détruire des données dans un usage normal ;
- **modéré** : exploitable sous condition, ou casse une garantie annoncée ;
- **mineur** : robustesse ou hygiène.

## 1. Limites connues

Ces limites tiennent au modèle de menace, pas à un défaut d'implémentation.

**Attaquant root.** Root peut lever `chattr +i` et `+a`, lire le coffre pendant qu'il est ouvert, remplacer le script ou capturer les passphrases au clavier. Le script n'a aucune défense contre un compte root compromis, et ne peut pas en avoir.

**Coffre monté.** Une fois ouvert, le contenu est en clair pour tout processus ayant les droits du propriétaire ou de root. Le chiffrement ne protège que le conteneur fermé. Rien ne referme le coffre automatiquement : ni délai d'inactivité, ni fermeture de session, ni mise en veille.

**Mémoire.** La clé maîtresse LUKS reste dans le noyau tant que le mapping est ouvert. Les passphrases GPG passent par des variables bash (`pass1`, `pass2`, l. 308-313) qui ne sont pas effacées. Une image mémoire, une hibernation ou une attaque de type cold boot peut les révéler.

**Swap.** Le script ne vérifie ni ne chiffre le swap. Les pages du shell, de `gpg` ou du cache de fichiers peuvent y être écrites en clair.

**Historique du shell.** Le script ne demande aucun secret en argument : les passphrases LUKS sont lues par `cryptsetup`, les passphrases GPG avec `read -s`. Rien de sensible n'arrive donc dans `.bash_history` par son fait. En revanche, `evsh` et les commandes tapées dans le coffre sont historisées normalement, et la ligne `HostName` des hôtes importés révèle les cibles.

**Métadonnées du conteneur.** Le fichier, sa taille (5 Go), ses dates et l'en-tête LUKS sont visibles. L'en-tête est attaché au conteneur : quiconque copie le fichier peut tenter une attaque hors ligne sur la passphrase. Le nom du mapping (`sec_env`), le point de montage et les raccourcis du `.bashrc` signalent aussi la présence d'un coffre. Avec `DD_SOURCE=/dev/zero` (l. 31), les blocs jamais écrits restent à zéro sous le chiffrement : la zone réellement utilisée se distingue du reste.

**Restauration d'un snapshot antérieur.** Une sauvegarde ou un snapshot de VM pris avant un changement de passphrase contient l'ancien en-tête LUKS : l'ancienne passphrase rouvre cet état. De même, un journal restauré à un état antérieur n'est pas détecté, car le journal n'a ni chaînage ni signature.

## 2. Faiblesses identifiées dans le code

### Critique

**C1. La passphrase GPG est écrite en clair sur disque, et le fichier reste en place si la génération échoue** (l. 316-332). Le fichier de paramètres batch contient `Passphrase: …` (l. 323). Il est créé avec `mktemp`, donc en mode 600 avec un nom imprévisible, et c'est bien. Mais si `gpg --full-generate-key` échoue (l. 330), `set -e` arrête le script avant le `shred` de la l. 332. Le `trap ERR` d'installation a été désarmé à la l. 497, donc aucun nettoyage ne rattrape ce cas : la passphrase reste dans `/tmp`. Même quand tout se passe bien, `shred` n'offre aucune garantie sur un tmpfs, un système de fichiers journalisé ou un SSD.

**C2. Clés SSH écrasées en silence à l'import** (l. 371-372, 386). La copie dans le coffre ne garde que le nom de fichier (`basename`). Deux hôtes dont les clés portent le même nom dans des répertoires différents (par exemple `~/.ssh/pro/id_ed25519` et `~/.ssh/perso/id_ed25519`) finissent dans un seul fichier `keys/id_ed25519`. La seconde copie écrase la première, et le premier hôte pointe ensuite vers la mauvaise clé. La clé d'origine n'est pas perdue, puisqu'elle reste dans `~/.ssh`, mais la copie du coffre l'est, sans avertissement. Le même problème touche l'export GPG (l. 625, 636) : un export répété écrase le précédent, ce qui est sans conséquence pour une même clé, mais pas si `--id` désigne une autre clé portant le même nom.

### Modéré

**M1. Le rollback ne couvre qu'une partie de `install`** (l. 485, 497). Le rollback est désarmé dès le montage. Si la génération GPG, l'import SSH, les `chmod`, le `chown -R` ou l'écriture du `.bashrc` échouent ensuite (l. 500-528), le coffre reste monté dans un état partiel, sans message de nettoyage. Le caractère « transactionnel » ne vaut que pour la création du volume.

**M2. Aucun nettoyage sur interruption** (l. 485, 559). Seul `ERR` est piégé. Un Ctrl-C ou un `SIGTERM` pendant le `dd`, le `luksFormat` ou le `mount` laisse un loop device attaché, voire un mapping ouvert. Après un `install` interrompu, il laisse aussi un conteneur partiel sans `+i`.

**M3. Le chemin du script est figé dans des raccourcis appelés avec `sudo`** (l. 194, 219, 224). `O` et `C` exécutent `sudo "$_COFFRE_SCRIPT"`. Si le script se trouve dans le home de l'utilisateur, ce qui était le cas pendant les tests, tout processus tournant sous ce compte peut le modifier, et la modification s'exécutera en root au prochain `O`. Discutable : l'utilisateur est déjà sudoer, donc le gain se limite à faire déclencher la commande par l'utilisateur lui-même. C'est pourtant le chemin classique pour transformer un compte compromis en accès root sans connaître le mot de passe.

**M4. Root lit des chemins choisis par l'utilisateur** (l. 366-377). Pendant `install`, qui tourne en root, les `IdentityFile` de `~/.ssh/config` sont copiés par root, puis rendus à l'utilisateur avec `chown_real`. Une ligne `IdentityFile /etc/shadow` ferait copier ce fichier dans le coffre et le rendrait lisible par l'utilisateur. Un lien symbolique dans `~/.ssh` a le même effet. Discutable pour la même raison que M3, puisque l'utilisateur est sudoer. Mais la copie contredit le principe de séparation de privilèges que le script annonce.

**M5. Conditions de concurrence entre test et usage** (l. 545 puis 570-575, l. 455-466 puis 470). `open` teste `is_mounted` et `mapper_exists`, puis agit. Deux exécutions simultanées peuvent passer les tests ensemble. Aucun verrou n'empêche deux `install` ou un `install` et un `open` de s'exécuter en même temps.

**M6. Un fichier existant non-LUKS est écrasé sans confirmation** (l. 463-465 puis 470). La confirmation n'est demandée que si le fichier est déjà un volume LUKS. Si `VAULT_CONTAINER` désigne un autre fichier, par erreur ou par variable d'environnement, `dd` l'écrase en root.

**M7. Évaluation arithmétique d'une variable d'environnement** (l. 470). `$((VAULT_SIZE_GB*1024))` évalue le contenu de la variable. Une valeur comme `a[$(commande)]` exécute la commande, en root. Testé : l'injection fonctionne dans bash. Discutable : `sudo` réinitialise l'environnement par défaut (`env_reset`), donc l'exploitation suppose `sudo -E` ou une politique `env_keep`. Les autres variables `VAULT_*` posent le même problème de confiance, sans exécution de code.

**M8. Le journal d'audit n'est pas protégé contre le script lui-même** (l. 74-83). `journal()` lève `+a`, écrit, puis repose `+a`. Tout ce qui peut exécuter le script en root peut donc réécrire le journal. Toutes les erreurs d'écriture sont ignorées (`|| true`) : une ligne peut manquer sans que personne le sache. Le journal n'existe que coffre ouvert, si bien qu'un échec de passphrase à l'ouverture n'est jamais tracé.

### Mineur

**m1. Chemins non quotés dans les fichiers générés** (l. 164, 181, 386). `UserKnownHostsFile`, l'alias `evsh` et `IdentityFile` reprennent `$VAULT_MOUNT` sans guillemets. Un chemin contenant une espace ou un guillemet casse la config SSH ou l'alias. Ailleurs, les variables sont systématiquement quotées.

**m2. `set -e` ne s'applique pas dans les substitutions de commande** (par exemple l. 358). Sans `shopt -s inherit_errexit`, une erreur à l'intérieur d'une fonction appelée par `$(…)` ne stoppe pas cette fonction. Testé. Les fonctions concernées terminent explicitement par `return 0`, donc l'impact est faible, mais le comportement est implicite.

**m3. Codes de retour ignorés sur des opérations de sécurité** (l. 456, 556, 562). Les `chattr` sont suivis de `|| true`. Sur un système de fichiers qui ne gère pas les attributs, l'immuabilité est perdue en silence lors de l'échec d'`open`, alors que `close` l'annonce correctement (l. 599-603).

**m4. Motif `A && B || C`** (l. 665, 676). Le `info` s'exécuterait aussi si `B` échouait. Ici `B` ne peut pas échouer, puisque `journal` renvoie toujours 0. C'est sans effet aujourd'hui, mais fragile si quelqu'un modifie `journal`.

**m5. Fichier de config SSH brièvement en 644** (l. 155 puis 521). Il est créé avec l'umask de root (022), puis passé en 600 en fin d'installation. Il ne contient pas de secret, seulement des noms et des adresses d'hôtes, et le répertoire parent n'est pas encore restreint (l. 520).

**m6. Import SSH en double** (l. 397). Relancer `ssh` sur un hôte déjà importé ajoute un second bloc identique. `ssh` ne retient que le premier : c'est sans danger, mais la config grossit.

**m7. Modifications persistantes du système** (l. 109-124, 244-251). `install` lance `apt-get install` sans demander et ajoute des lignes au `.bashrc`. Aucune commande ne les retire.

**m8. Cible GPG implicite hors installation** (l. 37). En dehors d'`install`, `GPG_ID` vaut le nom, pas l'empreinte. Si plusieurs clés du trousseau portent ce nom, `export` les exporte toutes dans un seul fichier.

### Ce qui est déjà fait correctement

- **Garde-fous du shell :** `set -euo pipefail` et `IFS=$'\n\t'` (l. 19-20). `IFS` est redéfini localement à chaque découpage (l. 265, 268, 283).
- **Pas d'`eval`,** pas de construction de commande par chaîne. Les arguments passent par tableaux (l. 327-330).
- **Aucun secret en argument :** aucun n'apparaît dans `ps`. `cryptsetup` lit sa passphrase sur le terminal, GPG via `read -s`.
- **Fichiers temporaires** créés avec `mktemp` (l. 316), jamais à un nom fixe.
- **Clé privée exportée** créée sous `umask 077` (l. 637), donc jamais lisible par d'autres, même brièvement.
- **Variables quotées** de façon systématique dans le code exécuté (les exceptions sont en m1).
- **Confirmations** par défaut à « non » (l. 86-94) avant l'écrasement d'un coffre et l'export ou l'import de clés privées.
- **Séparation de privilèges** réelle pour GPG : le trousseau de root n'est jamais utilisé.
- **Rollback** en ordre inverse, piloté par des drapeaux d'état plutôt que par des suppositions, pour `open` et la création du volume.

## 3. Améliorations possibles

### Corrections des faiblesses

| Réf. | Correction |
|---|---|
| C1 | Ne plus écrire la passphrase : générer la clé avec `%ask-passphrase`, ou la transmettre via `--passphrase-fd 3` avec un descripteur ouvert sur un here-string. Sinon, poser un `trap 'shred -u "$param"' EXIT` dès la création du fichier et placer `param` dans `/dev/shm`. |
| C2 | Copier sous un nom unique par hôte (`keys/<hôte>/<nom>` ou `<hôte>_<nom>`). Refuser d'écraser un fichier existant dont le contenu diffère (`cmp`), ou demander confirmation. Même règle pour les exports GPG, avec un nom basé sur l'empreinte. |
| M1 | Garder le rollback armé jusqu'à la fin d'`install`, avec une étape de nettoyage par phase. À défaut, avertir que le coffre est resté monté dans un état partiel. |
| M2 | `trap cleanup ERR INT TERM` et un `trap … EXIT` qui teste un drapeau de succès. Ajouter `set -E` (`errtrace`) pour que le piège s'applique dans les fonctions appelées. |
| M3 | Installer le script dans `/usr/local/sbin`, propriété de root en 755 (voir le README). Refuser de s'exécuter si le fichier ou son répertoire est modifiable par un autre utilisateur que root. |
| M4 | Lire les clés sous l'utilisateur (`run_as_user cat "$keypath" > …`). Refuser les chemins hors de `$REAL_HOME/.ssh` et les liens symboliques (`[ -L ]`, `realpath`). |
| M5 | Verrou exclusif en début de chaque commande : `exec 9>/run/coffre.lock; flock -n 9 \|\| die "déjà en cours"`. |
| M6 | Demander confirmation avant d'écraser tout fichier existant, LUKS ou non. Refuser un chemin hors d'un répertoire attendu. |
| M7 | Valider les entrées : `[[ $VAULT_SIZE_GB =~ ^[0-9]+$ ]] \|\| die`. Vérifier aussi les chemins `VAULT_*` (absolus, sans `..`). |
| M8 | Écrire le journal hors du chemin de modification (voir plus bas). Ne plus ignorer les erreurs d'écriture. Tracer les échecs d'ouverture dans `journald` (`logger -t coffre`), qui reste disponible coffre fermé. |
| m1 | Quoter les chemins dans les fichiers générés (`UserKnownHostsFile "…"`, `alias evsh='ssh -F "…"'`), ou refuser les chemins contenant des espaces. |
| m2 | `shopt -s inherit_errexit` après `set -euo pipefail`. |
| m3 | Remonter les échecs de `chattr` en avertissement partout, comme `close` le fait déjà. |
| m4 | Remplacer par `if …; then …; else …; fi`. |
| m5 | Créer la config sous `umask 077`, ou restreindre le répertoire avant d'y écrire. |
| m6 | Vérifier que l'hôte n'est pas déjà présent avant d'ajouter son bloc. |
| m7 | Demander avant `apt-get`. Ajouter une commande `uninstall` qui retire les lignes du `.bashrc` et les fichiers de `~/.config`. |
| m8 | Mémoriser l'empreinte dans le coffre à l'installation et la relire ensuite. |

### Évolutions de fond

- **Commande `destroy`.** Le cycle de vie n'a pas de fin : aujourd'hui, détruire le coffre veut dire lever `+i` et supprimer le fichier à la main. Or la suppression du fichier ne détruit pas les données : n'importe quelle copie antérieure du conteneur reste déchiffrable avec la passphrase. `cryptsetup luksErase` efface tous les emplacements de clé, ce qui rend le contenu irrécupérable, copies comprises, si la clé maîtresse n'a pas été extraite. Le `shred` du fichier vient ensuite, en sachant qu'il est peu fiable sur un SSD ou un système de fichiers copy-on-write.
- **En-tête LUKS détaché** (`--header`). L'en-tête est conservé ailleurs que le conteneur, par exemple sur une clé USB. Le fichier seul ne permet plus d'attaque hors ligne et n'est plus identifiable comme volume LUKS.
- **Dérivation de clé explicite :** `--pbkdf argon2id --pbkdf-memory 1048576 --iter-time 4000`, et `--cipher aes-xts-plain64 --key-size 512`. Ce sont souvent les valeurs par défaut de LUKS2, mais elles dépendent de la version de `cryptsetup` et de la machine au moment du `luksFormat`. Les fixer rend la configuration vérifiable.
- **Remplissage aléatoire.** Utiliser `DD_SOURCE=/dev/urandom` par défaut, ou `cryptsetup open --type plain` sur `/dev/urandom` avant le formatage, pour que les zones non utilisées ne se distinguent pas des zones écrites.
- **Verrouillage** contre deux exécutions simultanées (voir M5).
- **Journal en écriture seule** hors de portée du script : envoi vers `journald` ou un syslog distant, ou chaînage des lignes par empreinte (chaque ligne contient l'empreinte de la précédente) pour détecter une troncature ou une restauration.
- **Fermeture automatique :** timer systemd d'inactivité, et fermeture à la mise en veille et à la déconnexion.
- **Tests automatisés.** Un jeu `bats` qui exécute les commandes dans une VM ou un conteneur privilégié jetable, avec `shellcheck` en intégration continue. Cas à couvrir : échec de passphrase, interruption à chaque étape, double exécution, noms de clés en collision, chemins avec espaces. TODO : le script a été validé à la main sur une VM Debian, sans tests automatisés à ce jour.
- **Clés GPG modernes :** ed25519/cv25519 plutôt que RSA 4096, plus rapides et compactes, avec un niveau de sécurité équivalent ou supérieur.
