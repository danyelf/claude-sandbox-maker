#!/bin/bash
# Install csb to /usr/local/bin and support files to /usr/local/share/csb
#
# Usage:
#   ./install.sh           Install csb
#   ./install.sh --uninstall   Remove csb

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="/usr/local/bin"
SHARE_DIR="/usr/local/share/csb"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
NC='\033[0m'

info() { echo -e "${GREEN}==>${NC} $*"; }
dim() { echo -e "${DIM}$*${NC}"; }
error() { echo -e "${RED}Error:${NC} $*" >&2; }

uninstall() {
    info "Uninstalling csb..."

    if [[ -f "${BIN_DIR}/csb" ]]; then
        sudo rm -f "${BIN_DIR}/csb"
        dim "Removed ${BIN_DIR}/csb"
    fi

    if [[ -d "${SHARE_DIR}" ]]; then
        sudo rm -rf "${SHARE_DIR}"
        dim "Removed ${SHARE_DIR}"
    fi

    info "csb uninstalled"
    echo ""
    echo "Note: ~/.csb (user data, VM configs) was not removed."
    echo "To fully clean up: rm -rf ~/.csb"
}

install() {
    info "Installing csb..."

    # Check source files exist
    if [[ ! -f "${SCRIPT_DIR}/csb/csb" ]]; then
        error "csb/csb not found. Run from repository root."
        exit 1
    fi

    # Build template.yaml if needed
    if [[ ! -f "${SCRIPT_DIR}/csb/template.yaml" ]]; then
        if [[ -f "${SCRIPT_DIR}/csb/build-template.sh" ]]; then
            info "Building template.yaml..."
            "${SCRIPT_DIR}/csb/build-template.sh"
        else
            error "template.yaml not found and build-template.sh missing"
            exit 1
        fi
    fi

    # Create directories
    info "Creating ${SHARE_DIR}..."
    sudo mkdir -p "${SHARE_DIR}"

    # Copy support files
    info "Installing support files..."
    sudo cp "${SCRIPT_DIR}/csb/template.yaml" "${SHARE_DIR}/"
    dim "  ${SHARE_DIR}/template.yaml"

    # Copy config directory if it exists
    if [[ -d "${SCRIPT_DIR}/csb/config" ]]; then
        sudo cp -r "${SCRIPT_DIR}/csb/config" "${SHARE_DIR}/"
        dim "  ${SHARE_DIR}/config/"
    fi

    # Install binary
    info "Installing csb to ${BIN_DIR}..."
    sudo cp "${SCRIPT_DIR}/csb/csb" "${BIN_DIR}/csb"
    sudo chmod +x "${BIN_DIR}/csb"
    dim "  ${BIN_DIR}/csb"

    info "Installation complete!"
    echo ""
    echo "Usage:"
    echo "  export ANTHROPIC_API_KEY=\"sk-ant-...\""
    echo "  cd /path/to/project"
    echo "  csb start"
}

# Parse arguments
case "${1:-}" in
    --uninstall|-u)
        uninstall
        ;;
    --help|-h)
        echo "Usage: $0 [--uninstall]"
        echo ""
        echo "Options:"
        echo "  --uninstall, -u   Remove csb from system"
        echo "  --help, -h        Show this help"
        ;;
    "")
        install
        ;;
    *)
        error "Unknown option: $1"
        echo "Run '$0 --help' for usage"
        exit 1
        ;;
esac
