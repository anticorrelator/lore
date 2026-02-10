#!/usr/bin/env bash
# bootstrap-scope.sh — Analyze codebase structure and detect domains for bootstrap
# Usage: lore bootstrap-scope [dir1 dir2 ...]
# If no directories given, scans the repo root.
# Outputs a JSON array of domain objects:
#   [{"path": "src/auth", "description": "Authentication module", "language": "typescript"}, ...]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

# --- Resolve repo root ---
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "Not in a git repository"

# --- Parse arguments ---
SCOPE_DIRS=()
for arg in "$@"; do
  case "$arg" in
    --help|-h)
      echo "Usage: lore bootstrap-scope [dir1 dir2 ...]" >&2
      echo "  Analyze codebase structure and detect language/domains." >&2
      echo "  If no directories given, scans the repo root." >&2
      exit 0
      ;;
    *)
      # Resolve relative paths against repo root
      if [[ "$arg" = /* ]]; then
        SCOPE_DIRS+=("$arg")
      else
        SCOPE_DIRS+=("$REPO_ROOT/$arg")
      fi
      ;;
  esac
done

# Default to repo root if no dirs specified
if [[ ${#SCOPE_DIRS[@]} -eq 0 ]]; then
  SCOPE_DIRS=("$REPO_ROOT")
fi

# Validate directories exist
for dir in "${SCOPE_DIRS[@]}"; do
  [[ -d "$dir" ]] || die "Directory not found: $dir"
done

# --- Tree output (for structure context) ---
TREE_IGNORE='node_modules|.git|vendor|__pycache__|dist|build|.next|target|coverage'

get_tree_output() {
  local dir="$1"
  if command -v tree &>/dev/null; then
    tree -L 2 --dirsfirst -I "$TREE_IGNORE" "$dir" 2>/dev/null || true
  else
    # Fallback: use find to produce a simple listing
    (cd "$dir" && find . -maxdepth 2 -not -path '*/node_modules/*' \
      -not -path '*/.git/*' -not -path '*/vendor/*' \
      -not -path '*/__pycache__/*' -not -path '*/dist/*' \
      -not -path '*/build/*' -not -path '*/.next/*' \
      -not -path '*/target/*' -not -path '*/coverage/*' \
      | sort) 2>/dev/null || true
  fi
}

# --- Language detection ---
# Detect languages present in a directory by checking for marker files.
# Returns a comma-separated list of languages found.
detect_languages() {
  local dir="$1"
  local langs=()

  [[ -f "$dir/package.json" ]] && langs+=("Node.js")
  [[ -f "$dir/pyproject.toml" || -f "$dir/setup.py" ]] && langs+=("Python")
  [[ -f "$dir/Cargo.toml" ]] && langs+=("Rust")
  [[ -f "$dir/go.mod" ]] && langs+=("Go")
  [[ -f "$dir/pom.xml" || -f "$dir/build.gradle" ]] && langs+=("Java")
  [[ -f "$dir/Gemfile" ]] && langs+=("Ruby")

  # Check for C#/.NET (glob patterns)
  local has_csharp=0
  for f in "$dir"/*.csproj "$dir"/*.sln; do
    if [[ -f "$f" ]]; then
      has_csharp=1
      break
    fi
  done
  [[ "$has_csharp" -eq 1 ]] && langs+=("C#/.NET")

  if [[ ${#langs[@]} -eq 0 ]]; then
    echo ""
  else
    local IFS=','
    echo "${langs[*]}"
  fi
}

# --- Description heuristic ---
# Generate a short description for a directory based on its name and contents.
generate_description() {
  local dir="$1"
  local name
  name="$(basename "$dir")"

  # Count files to check if empty
  local file_count
  file_count=$(find "$dir" -maxdepth 1 -not -name '.*' -not -path "$dir" 2>/dev/null | wc -l | tr -d '[:space:]')

  if [[ "$file_count" -eq 0 ]]; then
    echo "Empty directory"
    return
  fi

  # Map common directory names to descriptions
  case "$name" in
    src)        echo "Main source code" ;;
    lib)        echo "Library modules" ;;
    test|tests) echo "Test suite" ;;
    docs)       echo "Documentation" ;;
    scripts)    echo "Build and utility scripts" ;;
    config)     echo "Configuration files" ;;
    api)        echo "API layer" ;;
    cmd)        echo "CLI entry points" ;;
    pkg)        echo "Shared packages" ;;
    internal)   echo "Internal packages" ;;
    app)        echo "Application entry point" ;;
    components) echo "UI components" ;;
    pages)      echo "Page routes" ;;
    public)     echo "Static assets" ;;
    assets)     echo "Static assets" ;;
    styles)     echo "Stylesheets" ;;
    utils)      echo "Utility functions" ;;
    helpers)    echo "Helper functions" ;;
    models)     echo "Data models" ;;
    services)   echo "Service layer" ;;
    middleware) echo "Middleware" ;;
    routes)     echo "Route definitions" ;;
    controllers) echo "Controllers" ;;
    views)      echo "View templates" ;;
    db|database) echo "Database layer" ;;
    migrations) echo "Database migrations" ;;
    deploy|deployment) echo "Deployment configuration" ;;
    infra|infrastructure) echo "Infrastructure definitions" ;;
    skills)     echo "Skill definitions" ;;
    cli)        echo "CLI interface" ;;
    *)
      # Generic: count subdirs and files to give a rough sense of scope
      local subdir_count
      subdir_count=$(find "$dir" -maxdepth 1 -type d -not -path "$dir" -not -name '.*' 2>/dev/null | wc -l | tr -d '[:space:]')
      if [[ "$subdir_count" -gt 0 ]]; then
        echo "${name} module (${subdir_count} subdirectories)"
      else
        echo "${name} module"
      fi
      ;;
  esac
}

# --- Collect domains ---
# For each scoped directory, find top-level subdirectories as candidate domains.
# Also include the scoped directory itself if it contains language markers.

domains_json="["
first=1

for scope_dir in "${SCOPE_DIRS[@]}"; do
  # Collect top-level directories (skip hidden and common non-domain dirs)
  for subdir in "$scope_dir"/*/; do
    [[ -d "$subdir" ]] || continue
    dirname="$(basename "$subdir")"

    # Skip hidden dirs and common non-domain dirs
    case "$dirname" in
      .*|node_modules|vendor|__pycache__|dist|build|.next|target|coverage) continue ;;
    esac

    # Get relative path from repo root
    rel_path="${subdir#$REPO_ROOT/}"
    rel_path="${rel_path%/}"

    description="$(generate_description "$subdir")"
    lang="$(detect_languages "$subdir")"

    # Also check parent for language (inherited)
    if [[ -z "$lang" ]]; then
      lang="$(detect_languages "$scope_dir")"
    fi

    # Build JSON object — use python3 for safe escaping
    json_obj="$(python3 -c "
import json, sys
obj = {'path': sys.argv[1], 'description': sys.argv[2]}
lang = sys.argv[3]
if lang:
    obj['languages'] = lang.split(',')
else:
    obj['languages'] = []
print(json.dumps(obj))
" "$rel_path" "$description" "$lang")"

    if [[ "$first" -eq 1 ]]; then
      first=0
    else
      domains_json+=","
    fi
    domains_json+="$json_obj"
  done
done

domains_json+="]"

# --- Output ---
# Print tree for context (to stderr so JSON stays clean on stdout)
for scope_dir in "${SCOPE_DIRS[@]}"; do
  rel="$(python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$scope_dir" "$REPO_ROOT")"
  echo "=== Structure: $rel ===" >&2
  get_tree_output "$scope_dir" >&2
  echo "" >&2
done

# Pretty-print the JSON array
python3 -c "import json,sys; print(json.dumps(json.loads(sys.argv[1]), indent=2))" "$domains_json"
