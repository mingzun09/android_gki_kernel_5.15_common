#!/bin/bash
# ==============================================================================
# Common Configuration and Utility Functions
# ==============================================================================

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging functions
log() { echo -e "${GREEN}[INFO] $1${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

# Workspace configuration
LIB_DIR_ABS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$LIB_DIR_ABS")"

# Robust Workspace directory selection
# If we are in GitHub Actions, use a directory in the runner's workspace but outside the repo
if [ -n "$GITHUB_WORKSPACE" ]; then
    WORKSPACE_DIR="$GITHUB_WORKSPACE/../gki_build_workspace"
else
    WORKSPACE_DIR="$REPO_ROOT/../gki_build_workspace"
fi
WORKSPACE_DIR="$(realpath -m "$WORKSPACE_DIR")"

KERNEL_SRC="$REPO_ROOT"
CLANG_DIR="$WORKSPACE_DIR/prebuilts/clang/host/linux-x86"
CLANG_VER="clang-r547379"
STAMP_BZL="$WORKSPACE_DIR/build/kernel/kleaf/impl/stamp.bzl"

get_script_dir() {
    echo "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
}

cleanup() {
    true
}

trap cleanup EXIT
