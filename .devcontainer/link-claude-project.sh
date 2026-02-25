#!/bin/bash
# Links the container's Claude project directory to the host's project directory
# so that Claude Code state (conversations, plans, memory) persists across
# host and container sessions.
#
# Uses LOCAL_WORKSPACE_FOLDER env var set by devcontainer.json to derive
# the host project directory name dynamically.

set -euo pipefail

if [ -z "${LOCAL_WORKSPACE_FOLDER:-}" ]; then
  echo "WARNING: LOCAL_WORKSPACE_FOLDER not set, skipping Claude project link"
  exit 0
fi

PROJECTS_DIR="${HOME}/.claude/projects"
HOST_PROJECT_DIR="${PROJECTS_DIR}/$(echo "$LOCAL_WORKSPACE_FOLDER" | tr '/' '-')"
CONTAINER_PROJECT_DIR="${PROJECTS_DIR}/-workspace"

mkdir -p "$PROJECTS_DIR"

# Only create the symlink if the host project dir exists and the container
# project dir is not already pointing to it
if [ -d "$HOST_PROJECT_DIR" ] && [ ! -L "$CONTAINER_PROJECT_DIR" ]; then
  ln -sfn "$HOST_PROJECT_DIR" "$CONTAINER_PROJECT_DIR"
  echo "Linked Claude project: $CONTAINER_PROJECT_DIR -> $HOST_PROJECT_DIR"
elif [ -L "$CONTAINER_PROJECT_DIR" ]; then
  echo "Claude project link already exists"
else
  # Host project dir doesn't exist yet — create it and symlink
  mkdir -p "$HOST_PROJECT_DIR"
  ln -sfn "$HOST_PROJECT_DIR" "$CONTAINER_PROJECT_DIR"
  echo "Created and linked Claude project: $CONTAINER_PROJECT_DIR -> $HOST_PROJECT_DIR"
fi
