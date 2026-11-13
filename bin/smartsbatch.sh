#!/bin/bash
# smartsbatch.sh -- shell hook that defines the `smartsbatch` command.
#
# This file is meant to be SOURCED (not executed), normally from the block that
# `smartSbatchSetup` writes into your ~/.bashrc:
#
#     # >>> smartSbatch initialize >>>
#     export SMARTSBATCH_HOME="/path/to/SmartSbatch"
#     [ -f "$SMARTSBATCH_HOME/bin/smartsbatch.sh" ] && . "$SMARTSBATCH_HOME/bin/smartsbatch.sh"
#     # <<< smartSbatch initialize <<<
#
# It provides, analogous to `conda`:
#     smartsbatch activate     - put SmartSbatch on PATH; alias sbatch -> ssbatch
#     smartsbatch deactivate   - remove ONLY SmartSbatch's own PATH/prompt additions
#     smartsbatch uninstall    - delete the initialize block from the rc file
#     smartsbatch status       - show whether SmartSbatch is active
#     smartsbatch help
#
# Defining `smartsbatch` as a shell function (rather than a script on PATH) is
# what lets activate/deactivate change the *current* shell's PATH and prompt.

# --- locate SMARTSBATCH_HOME -------------------------------------------------
# The rc block exports SMARTSBATCH_HOME. If the hook is sourced directly without
# it (e.g. in tests), derive it from this file's own location (bin/..).
if [ -z "${SMARTSBATCH_HOME:-}" ]; then
    if [ -n "${BASH_SOURCE:-}" ]; then
        SMARTSBATCH_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
        export SMARTSBATCH_HOME
    fi
fi

# Prompt token -- curly braces, deliberately distinct from conda's "(env) ".
# (Assigned plainly rather than via ${:=...}: a '}' in the default value would
# prematurely close that parameter expansion.)
if [ -z "${SMARTSBATCH_PROMPT_TOKEN:-}" ]; then
    SMARTSBATCH_PROMPT_TOKEN='{smartSbatch} '
fi

# --- helpers ----------------------------------------------------------------

# Rebuild PATH keeping every entry EXCEPT the exact dirs we added at activate.
# Surgical by design: anything added to PATH after activation (conda, module
# load, the user's own exports) is preserved untouched.
_ss_path_strip() {
    # args: colon-list of dirs to remove
    local remove="$1" oldifs="$IFS" out="" d e drop
    IFS=:
    for d in $PATH; do
        drop=""
        for e in $remove; do
            [ "$d" = "$e" ] && { drop=1; break; }
        done
        [ -n "$drop" ] && continue
        if [ -z "$out" ]; then out="$d"; else out="$out:$d"; fi
    done
    IFS="$oldifs"
    printf '%s' "$out"
}

_ss_sbatch_path() { command -v sbatch 2>/dev/null; }

# --- subcommands ------------------------------------------------------------

_ss_activate() {
    if [ -n "${_SMARTSBATCH_ACTIVE:-}" ]; then
        echo "smartSbatch: already active" >&2
        return 0
    fi
    if [ -z "${SMARTSBATCH_HOME:-}" ] || [ ! -d "$SMARTSBATCH_HOME/bin" ]; then
        echo "smartSbatch: SMARTSBATCH_HOME is not set to a valid SmartSbatch checkout" >&2
        return 1
    fi

    local bin="$SMARTSBATCH_HOME/bin" sb="$SMARTSBATCH_HOME/sbatchBin"
    local entries="$bin"
    [ -d "$sb" ] && entries="$bin:$sb"

    export PATH="$entries:$PATH"
    export _SMARTSBATCH_PATH_ENTRIES="$entries"

    # Prompt: prepend our token once (idempotent).
    export _SMARTSBATCH_PROMPT="$SMARTSBATCH_PROMPT_TOKEN"
    case "$PS1" in
        *"$_SMARTSBATCH_PROMPT"*) ;;                       # already present
        *) PS1="$_SMARTSBATCH_PROMPT$PS1" ;;
    esac

    export _SMARTSBATCH_ACTIVE=1

    # Announce -- especially the sbatch aliasing, which was previously silent.
    echo "smartSbatch activated."
    local sbp; sbp="$(_ss_sbatch_path)"
    case "$sbp" in
        "$sb/"*)
            echo "  sbatch -> $sbp"
            echo "  (plain 'sbatch' now runs smart ssbatch; 'smartsbatch deactivate' restores the system sbatch)"
            ;;
        *)
            echo "  ssbatch and tools are on PATH."
            [ -d "$sb" ] || echo "  (no sbatchBin/ in this checkout; plain 'sbatch' is unchanged)"
            ;;
    esac
}

_ss_deactivate() {
    if [ -z "${_SMARTSBATCH_ACTIVE:-}" ]; then
        echo "smartSbatch: not active" >&2
        return 0
    fi

    # Surgical PATH removal: drop only our recorded dirs.
    export PATH="$(_ss_path_strip "${_SMARTSBATCH_PATH_ENTRIES:-}")"

    # Prompt: remove only our exact token; leave any other prefix (e.g. conda's
    # "(env) ") in place.
    if [ -n "${_SMARTSBATCH_PROMPT:-}" ]; then
        PS1="${PS1/$_SMARTSBATCH_PROMPT/}"
    fi

    unset _SMARTSBATCH_ACTIVE _SMARTSBATCH_PATH_ENTRIES _SMARTSBATCH_PROMPT
    echo "smartSbatch deactivated. System sbatch restored."
}

_ss_uninstall() {
    # Clean the current shell first.
    [ -n "${_SMARTSBATCH_ACTIVE:-}" ] && _ss_deactivate

    local rc="${1:-$HOME/.bashrc}"
    local begin='# >>> smartSbatch initialize >>>'
    local end='# <<< smartSbatch initialize <<<'

    if [ ! -f "$rc" ]; then
        echo "smartSbatch: no rc file at $rc" >&2
        return 1
    fi
    if ! grep -qF "$begin" "$rc"; then
        echo "smartSbatch: no initialize block found in $rc (nothing to remove)" >&2
        return 0
    fi

    local bak="$rc.smartsbatch.bak.$(date +%s)"
    cp "$rc" "$bak"

    local tmp; tmp="$(mktemp)"
    awk -v b="$begin" -v e="$end" '
        $0==b { skip=1; next }
        $0==e { skip=0; next }
        skip!=1 { print }
    ' "$rc" > "$tmp"
    cat "$tmp" > "$rc"        # truncate-in-place: keep rc perms/inode
    rm -f "$tmp"

    echo "smartSbatch: removed initialize block from $rc (backup: $bak)"
    echo "  New shells will no longer load smartSbatch."
}

_ss_status() {
    if [ -n "${_SMARTSBATCH_ACTIVE:-}" ]; then
        echo "smartSbatch: ACTIVE"
        echo "  home:    ${SMARTSBATCH_HOME:-<unset>}"
        echo "  on PATH: ${_SMARTSBATCH_PATH_ENTRIES:-<none>}"
        local sbp; sbp="$(_ss_sbatch_path)"
        echo "  sbatch:  ${sbp:-<none>}"
        case "$sbp" in
            "$SMARTSBATCH_HOME/sbatchBin/"*) echo "           (aliased to smart ssbatch)" ;;
            *)                              echo "           (system sbatch)" ;;
        esac
    else
        echo "smartSbatch: inactive"
        echo "  home:    ${SMARTSBATCH_HOME:-<unset>}"
    fi
}

_ss_help() {
    cat <<'EOF'
smartsbatch -- manage SmartSbatch activation in your shell

Usage:
  smartsbatch activate      Add SmartSbatch to PATH and alias sbatch -> ssbatch.
                           Prefixes the prompt with "{smartSbatch} ".
  smartsbatch deactivate    Remove only SmartSbatch's own PATH and prompt
                           additions (anything you added afterward is kept).
  smartsbatch uninstall     Remove the smartSbatch block from your shell rc file.
  smartsbatch status        Show whether SmartSbatch is currently active.
  smartsbatch help          Show this message.
EOF
}

# --- dispatcher -------------------------------------------------------------
smartsbatch() {
    local cmd="${1:-help}"
    [ "$#" -gt 0 ] && shift
    case "$cmd" in
        activate)   _ss_activate "$@" ;;
        deactivate) _ss_deactivate "$@" ;;
        uninstall)  _ss_uninstall "$@" ;;
        status)     _ss_status "$@" ;;
        help|-h|--help) _ss_help ;;
        *) echo "smartsbatch: unknown command '$cmd'" >&2; _ss_help; return 2 ;;
    esac
}
