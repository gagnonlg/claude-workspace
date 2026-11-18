#!/bin/bash
# Container entrypoint: install the image's Claude config into /root/.claude,
# activate the conda base env, then exec the command.
#
# /root/.claude persists across containers (bind-mounted from the host), so a
# plain copy would leave behind skills that were removed from the image.
# Skills found in /root/.claude/skills that the image doesn't ship are offered
# for deletion. Skills you choose to keep are remembered in KEEP_FILE and not
# asked about again.

set -euo pipefail

SRC=/opt/config/claude
DEST=/root/.claude
KEEP_FILE=$DEST/.skills-keep
# Directories under skills/ managed by Claude Code itself, never touched.
PROTECTED=(synced)

mkdir -p "$DEST/skills"
touch "$KEEP_FILE"

stale=()
for dir in "$DEST"/skills/*/; do
    [ -d "$dir" ] || continue
    name=$(basename "$dir")
    [ -d "$SRC/skills/$name" ] && continue
    [[ " ${PROTECTED[*]} " == *" $name "* ]] && continue
    grep -qxF "$name" "$KEEP_FILE" && continue
    stale+=("$name")
done

if [ ${#stale[@]} -gt 0 ]; then
    echo "These skills are in $DEST/skills but not in the image:" >&2
    printf '  %s\n' "${stale[@]}" >&2
    if [ -t 0 ]; then
        echo "  a = delete all listed, o = choose one by one," >&2
        echo "  k = keep all and stop asking, N = keep for now (default)" >&2
        read -r -p "Choice [a/o/k/N]: " answer
        case "$answer" in
            [aA]*)
                for name in "${stale[@]}"; do rm -rf "${DEST:?}/skills/$name"; done
                echo "Deleted ${#stale[@]} skill(s)." >&2 ;;
            [oO]*)
                for name in "${stale[@]}"; do
                    read -r -p "  $name: delete? [y/N/k(eep, stop asking)] " one
                    case "$one" in
                        [yY]*) rm -rf "${DEST:?}/skills/$name"; echo "    deleted" >&2 ;;
                        [kK]*) echo "$name" >> "$KEEP_FILE"; echo "    kept, won't ask again" >&2 ;;
                        *)     echo "    kept for now" >&2 ;;
                    esac
                done ;;
            [kK]*)
                printf '%s\n' "${stale[@]}" >> "$KEEP_FILE"
                echo "Keeping them; recorded in $KEEP_FILE." >&2 ;;
            *)
                echo "Keeping them for now." >&2 ;;
        esac
    else
        echo "No terminal attached; keeping them. Start the container with -it to be asked." >&2
    fi
fi

cp -a "$SRC/." "$DEST/"

set +eu  # conda's activation scripts aren't safe under -e/-u
. /opt/conda/etc/profile.d/conda.sh
conda activate base
exec "$@"
