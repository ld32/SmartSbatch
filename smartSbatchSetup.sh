#!/bin/bash
# smartSbatchSetup.sh -- one-time setup for the `smartsbatch` shell command.
#
# This script does all the work: it adds a small "initialize" block to your
# shell rc file (~/.bashrc) so future shells know the `smartsbatch` command
# (activate / deactivate / uninstall). You do NOT edit any file or add any
# `export` yourself -- avoiding that manual PATH export is the whole point.
# Nothing is compiled or copied into system directories.
#
# Install flow:
#     git clone https://github.com/ld32/SmartSbatch.git
#     cd SmartSbatch
#     bash smartSbatchSetup.sh
#
# Then open a new shell (or `source ~/.bashrc`) and run `smartsbatch activate`.
# Activation stays explicit, exactly like `conda activate`.
#
# Optional: pass a different rc file as the first argument:
#     bash smartSbatchSetup.sh ~/.bash_profile
#
# This is the bash version. (zsh support is planned.)
set -u

# Resolve the SmartSbatch checkout from this script's own location (repo root).
home="$(cd "$(dirname "$0")" && pwd)"
hook="$home/bin/smartsbatch.sh"

rc="${1:-$HOME/.bashrc}"

if [ ! -f "$hook" ]; then
    echo "smartSbatchSetup: hook not found: $hook" >&2
    echo "  (is this script still inside a SmartSbatch checkout?)" >&2
    exit 1
fi

begin='# >>> smartSbatch initialize >>>'
end='# <<< smartSbatch initialize <<<'

# The block is intentionally tiny: it only points at SMARTSBATCH_HOME and sources
# the hook. All logic lives in bin/smartsbatch.sh, so a `git pull` upgrades
# behavior without ever rewriting the rc file.
block="$begin
# Managed by smartSbatchSetup -- remove with 'smartsbatch uninstall'.
# Enables: smartsbatch activate | deactivate | uninstall | status
export SMARTSBATCH_HOME=\"$home\"
[ -f \"\$SMARTSBATCH_HOME/bin/smartsbatch.sh\" ] && . \"\$SMARTSBATCH_HOME/bin/smartsbatch.sh\"
$end"

touch "$rc"

if grep -qF "$begin" "$rc"; then
    # Idempotent: replace the existing block in place (updates SMARTSBATCH_HOME
    # if the checkout moved). Any stray duplicate blocks are collapsed into one.
    bak="$rc.smartsbatch.bak.$(date +%s)"
    cp "$rc" "$bak"
    tmp="$(mktemp)"
    awk -v blk="$block" -v b="$begin" -v e="$end" '
        $0==b && !done { print blk; done=1; skip=1; next }  # replace first block
        $0==b          { skip=1; next }                      # swallow duplicates
        $0==e          { skip=0; next }
        skip!=1        { print }
    ' "$rc" > "$tmp"
    cat "$tmp" > "$rc"        # truncate-in-place: keep rc perms/inode
    rm -f "$tmp"
    echo "smartSbatchSetup: updated the smartSbatch block in $rc"
    echo "  backup: $bak"
else
    printf '\n%s\n' "$block" >> "$rc"
    echo "smartSbatchSetup: added the smartSbatch block to $rc"
fi

echo
echo "Next steps:"
echo "  1) start a new shell   (or run:  source \"$rc\")"
echo "  2) smartsbatch activate"
