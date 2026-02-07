#!/usr/bin/env bash
# config.sh — Resolve LORE_DATA_DIR and LORE_SCRIPT_DIR
# Source this from other scripts: source "$(dirname "$0")/config.sh"

# LORE_SCRIPT_DIR: directory containing lore scripts (always this directory)
LORE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LORE_SCRIPT_DIR

# LORE_DATA_DIR: where per-project knowledge data lives
# Priority: explicit env var > ~/.lore (new default) > ~/.project-knowledge (legacy)
if [ -z "${LORE_DATA_DIR:-}" ]; then
  if [ -d "$HOME/.lore/repos" ]; then
    LORE_DATA_DIR="$HOME/.lore"
  elif [ -d "$HOME/.project-knowledge/repos" ]; then
    LORE_DATA_DIR="$HOME/.project-knowledge"
  else
    LORE_DATA_DIR="$HOME/.lore"
  fi
fi
export LORE_DATA_DIR
