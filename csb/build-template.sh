#!/bin/bash
# Build template.yaml from template.yaml.in and provision scripts
#
# This script assembles the final Lima template by injecting provision
# scripts into placeholder locations in template.yaml.in.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_IN="$SCRIPT_DIR/template.yaml.in"
TEMPLATE_OUT="$SCRIPT_DIR/template.yaml"
PROVISION_DIR="$SCRIPT_DIR/provision"

# Placeholder to script file mapping (space-separated pairs)
MAPPINGS="
SCRIPT_PACKAGES:01-packages.sh
SCRIPT_USER_SETUP:02-user-setup.sh
SCRIPT_NETWORK:03-network.sh
"

# Indent each line of a file with 6 spaces (for YAML script block)
indent_script() {
    local file="$1"
    sed 's/^/      /' "$file"
}

# Optional: run shellcheck on scripts
check_scripts() {
    local has_errors=0
    if command -v shellcheck &>/dev/null; then
        echo "Running shellcheck on provision scripts..."
        for mapping in $MAPPINGS; do
            [[ -z "$mapping" ]] && continue
            local script="${mapping#*:}"
            local path="$PROVISION_DIR/$script"
            if [[ -f "$path" ]]; then
                if ! shellcheck "$path" 2>/dev/null; then
                    echo "  Warning: shellcheck found issues in $script"
                    has_errors=1
                fi
            fi
        done
        if [[ $has_errors -eq 0 ]]; then
            echo "  All scripts pass shellcheck"
        fi
    else
        echo "Note: shellcheck not installed, skipping validation"
    fi
}

main() {
    echo "Building template.yaml..."

    # Verify input files exist
    if [[ ! -f "$TEMPLATE_IN" ]]; then
        echo "Error: $TEMPLATE_IN not found" >&2
        exit 1
    fi

    for mapping in $MAPPINGS; do
        [[ -z "$mapping" ]] && continue
        local script="${mapping#*:}"
        local path="$PROVISION_DIR/$script"
        if [[ ! -f "$path" ]]; then
            echo "Error: $path not found" >&2
            exit 1
        fi
    done

    # Optional shellcheck
    check_scripts

    # Start with template
    cp "$TEMPLATE_IN" "$TEMPLATE_OUT"

    # Replace each placeholder with indented script content
    for mapping in $MAPPINGS; do
        [[ -z "$mapping" ]] && continue
        local placeholder="${mapping%%:*}"
        local script="${mapping#*:}"
        local path="$PROVISION_DIR/$script"
        local marker="{{${placeholder}}}"

        echo "  Injecting $script -> $marker"

        # Create temp file with indented script
        local tmp_script
        tmp_script=$(mktemp)
        indent_script "$path" > "$tmp_script"

        # Use awk to replace the placeholder line with file contents
        awk -v marker="$marker" -v file="$tmp_script" '
            $0 == marker {
                while ((getline line < file) > 0) print line
                close(file)
                next
            }
            { print }
        ' "$TEMPLATE_OUT" > "$TEMPLATE_OUT.tmp"
        mv "$TEMPLATE_OUT.tmp" "$TEMPLATE_OUT"

        rm -f "$tmp_script"
    done

    echo "Built: $TEMPLATE_OUT"
}

main "$@"
