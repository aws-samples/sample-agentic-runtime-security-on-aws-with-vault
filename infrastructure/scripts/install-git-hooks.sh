#!/usr/bin/env bash
#===============================================================================
# infrastructure/scripts/install-git-hooks.sh — one-time symlink installer.
#
# Symlinks every executable in infrastructure/git-hooks/ into .git/hooks/ so
# the tracked hooks fire on the maintainer's machine. Re-runnable; replaces
# stale symlinks; leaves non-symlink hook files alone (the maintainer may
# have a local hook they don't want clobbered — fail loud instead).
#
# Why symlink (not copy):
#   A symlink stays live as the repo edits the hook source. A copy goes stale
#   the moment someone updates the tracked hook, and the local stale copy
#   keeps firing without anyone noticing.
#===============================================================================
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
src_dir="${repo_root}/infrastructure/git-hooks"
dst_dir="${repo_root}/.git/hooks"

[ -d "${src_dir}" ] || { echo "FATAL: ${src_dir} missing"; exit 1; }
[ -d "${dst_dir}" ] || { echo "FATAL: ${dst_dir} missing (is this a git repo?)"; exit 1; }

shopt -s nullglob
installed=0
for src in "${src_dir}"/*; do
    [ -f "${src}" ] || continue
    name=$(basename "${src}")
    dst="${dst_dir}/${name}"

    if [ -L "${dst}" ]; then
        # Existing symlink — replace (idempotent).
        rm "${dst}"
    elif [ -e "${dst}" ]; then
        echo "ERROR: ${dst} exists and is not a symlink — refusing to overwrite a local hook." >&2
        echo "  Move/remove the existing file, then re-run this script." >&2
        exit 1
    fi

    # Relative symlink so the link survives if the repo is moved.
    ln -s "../../infrastructure/git-hooks/${name}" "${dst}"
    chmod +x "${src}"
    echo "installed: .git/hooks/${name} -> ../../infrastructure/git-hooks/${name}"
    installed=$((installed + 1))
done

echo "done: ${installed} hook(s) installed"
