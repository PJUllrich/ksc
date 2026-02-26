#!/bin/bash
# Protects sensitive files and sets up Claude project settings.
#
# 1. Bind-mounts empty files over paths listed in protected-paths.txt
#    so the container sees empty files while the host is unaffected.
# 2. Creates Claude project-level settings with deny rules as a
#    secondary safeguard.
#
# Must run as root (for mount --bind).

set -euo pipefail

# --- Protect sensitive files ---
shadow_path() {
    [ -e "$1" ] || return 0
    local target="/tmp/protected-$(echo "$1" | tr '/' '-')"
    if [ -f "$1" ]; then
        touch "$target"
    elif [ -d "$1" ]; then
        mkdir -p "$target"
    fi
    mount --bind "$target" "$1"
    echo "  Protected: $1"
}

# Prefer the workspace copy (bind-mounted, always up to date) over the baked-in image copy
if [ -f "/workspace/.devcontainer/protected-paths.txt" ]; then
    PROTECTED_PATHS="/workspace/.devcontainer/protected-paths.txt"
else
    PROTECTED_PATHS="/etc/devcontainer/protected-paths.txt"
fi
if [ -f "$PROTECTED_PATHS" ]; then
    while IFS= read -r pattern; do
        [[ "$pattern" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${pattern// }" ]] && continue

        if [[ "$pattern" == *"**"* ]]; then
            find /workspace -name "${pattern##*\*\*/}" 2>/dev/null | while IFS= read -r match; do
                shadow_path "$match"
            done
        else
            for match in /workspace/$pattern; do
                shadow_path "$match"
            done
        fi
    done < "$PROTECTED_PATHS"
else
    echo "No protected-paths.txt found, skipping"
fi

# --- Set up Claude project settings ---
DEV_HOME="/home/dev"
PROJECT_DIR="${DEV_HOME}/.claude/projects/-workspace"
SETTINGS_FILE="${PROJECT_DIR}/settings.json"

mkdir -p "$PROJECT_DIR"
chown -R dev:dev "$PROJECT_DIR"

DENY_RULES="[]"
if [ -f "$PROTECTED_PATHS" ]; then
    while IFS= read -r pattern || [ -n "$pattern" ]; do
        [[ "$pattern" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${pattern// }" ]] && continue
        # Ensure patterns match at any depth
        if [[ "$pattern" != *'**'* ]]; then
            pattern="**/$pattern"
        fi
        DENY_RULES=$(echo "$DENY_RULES" | jq --arg rule "Read(path:${pattern})" '. + [$rule]')
    done < "$PROTECTED_PATHS"
fi

# Merge deny rules into existing settings (preserves user-added config)
if [ -f "$SETTINGS_FILE" ]; then
    UPDATED=$(jq --argjson rules "$DENY_RULES" '.permissions.deny = $rules' "$SETTINGS_FILE")
    echo "$UPDATED" > "$SETTINGS_FILE"
    echo "Updated Claude settings: $SETTINGS_FILE"
else
    jq -n --argjson rules "$DENY_RULES" '{"permissions": {"deny": $rules}}' > "$SETTINGS_FILE"
    echo "Created Claude settings: $SETTINGS_FILE"
fi
chown dev:dev "$SETTINGS_FILE"
