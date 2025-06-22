#!/bin/bash
set -uo pipefail

# === CONSTANTS ===
readonly SCRIPT_NAME="$(basename "$0")"
readonly PACKER_TEMPLATE="macos-xcode.pkr.hcl"
readonly TART_REGISTRY="ghcr.io/cirruslabs/macos"
readonly CACHE_DIR_PATH="$HOME/.tartly/cache" # TODO: Make customizable?

# Positional arguments
MACOS_VERSION=""
XCODE_VERSION=""
GITHUB_ORGANIZATION=""

# Options

# === UTILITY FUNCTIONS ===
die() {
    local exit_code="${1:-1}"
    shift
    echo "[ERROR] $*" >&2
    exit "$exit_code"
}

# === VALIDATION FUNCTIONS ===
validate_parameters() {
    local macos_version="$1"
    local xcode_version="$2"
    local github_org="$3"
    [[ -n "$macos_version" ]] || die 2 "macOS version cannot be empty."
    [[ -n "$xcode_version" ]] || die 2 "Xcode version cannot be empty."
    [[ -n "$github_org" ]] || die 2 "GitHub github_org cannot be empty."
    [[ "$macos_version" =~ ^[a-z]+$ ]] || die 7 "Invalid macOS version format: $macos_version."
    [[ "$xcode_version" =~ ^[0-9]+\.[0-9]+$ ]] || die 7 "Invalid Xcode version format: $xcode_version."
}

validate_prerequisites() {
    [[ "$(uname)" == "Darwin" ]] || die 3 "This script can only run on macOS."
    command -v gh >/dev/null 2>&1 || die 3 "gh CLI is not installed."
    command -v tart >/dev/null 2>&1 || die 3 "tart is not installed."
    command -v packer >/dev/null 2>&1 || die 3 "packer is not installed."
    [[ -f "$PACKER_TEMPLATE" ]] || die 3 "Packer template not found: $PACKER_TEMPLATE."
    gh auth status >/dev/null 2>&1 || die 4 "GitHub authentication failed. Please run: gh auth login."
}

confirm_setup() {
    local macos_version="$1"
    local xcode_version="$2"
    local github_org="$3"
    local vm_name="macos-${macos_version}-xcode:${xcode_version}"
    echo "[INFO] Setup summary:"
    echo "[INFO]   macOS version: $macos_version"
    echo "[INFO]   Xcode version: $xcode_version"
    echo "[INFO]   GitHub github_org: $github_org"
    echo "[INFO]   VM name: $vm_name"
    while true; do
        read -p "Proceed with VM setup? [y/N]: " response
        case "$response" in
            [Yy]|[Yy][Ee][Ss]) break ;;
            [Nn]|[Nn][Oo]|"") echo "[INFO] Setup cancelled by user."; exit 0 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

# === CORE FUNCTIONS ===
pull_base_image() {
    local macos_version="$1"
    local xcode_version="$2"
    echo "[INFO] Pulling base image: ${TART_REGISTRY}-${macos_version}-xcode:${xcode_version}"
    tart pull --concurrency 8 "${TART_REGISTRY}-${macos_version}-xcode:${xcode_version}" || die 5 "Failed to pull base image: ${TART_REGISTRY}-${macos_version}-xcode:${xcode_version}"
    echo "[INFO] Base image pulled successfully."
}

get_github_token() {
    local github_org="$1"
    local token=$(gh api --method POST "orgs/$github_org/actions/runners/registration-token" --jq .token 2>/dev/null) || die 4 "Failed to get GitHub runner token for github_org: $github_org."
    [[ -n "$token" ]] || die 4 "Received empty GitHub runner token."
    echo "$token"
}

initialize_packer() {
    echo "[INFO] Initializing Packer template..."
    packer init -upgrade "$PACKER_TEMPLATE" || die 6 "Failed to initialize Packer template: $PACKER_TEMPLATE."
    echo "[INFO] Packer template initialized successfully."
}

build_vm_image() {
    local macos_version="$1"
    local xcode_version="$2"
    local github_org="$3"
    local github_token="$4"
    echo "[INFO] Building VM image..."
    packer build \
        -var "macos_version=$macos_version" \
        -var "xcode_version=$xcode_version" \
        -var "github_runner_org=$github_org" \
        -var "github_runner_token=$github_token" \
        "$PACKER_TEMPLATE" || die 6 "Failed to build VM image."
    echo "[INFO] VM image built successfully."
}

show_next_steps() {
    local macos_version="$1"
    local xcode_version="$2"
    local vm_name="macos-${macos_version}-xcode:${xcode_version}"
    echo "[INFO]"
    echo "[INFO] === Setup Complete ==="
    echo "[INFO]"
    echo "[INFO] Your VM image is ready! Next steps:"
    echo "[INFO]"
    echo "[INFO] 1. Install the VM as a launch agent:"
    echo "[INFO]    ./svc.sh install $vm_name"
    echo "[INFO]"
    echo "[INFO] 2. Start the VM:"
    echo "[INFO]    ./svc.sh start $vm_name"
    echo "[INFO]"
    echo "[INFO] 3. Check status:"
    echo "[INFO]    ./svc.sh list --verbose"
    echo "[INFO]"
    echo "[INFO] 4. Stop the VM when needed:"
    echo "[INFO]    ./svc.sh stop $vm_name"
    echo "[INFO]"
    echo "[INFO] For more information, see the documentation."
}

# === COMMAND-LINE INTERFACE ===
show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [options]

Named Parameters:
    --macos, -m <version>   macOS version (e.g., sonoma, ventura)
    --xcode, -x <version>   Xcode version (e.g., 16.1, 15.0)
    --org, -o <name>        GitHub github_org name

Options:
    --help, -h              Show this help message

Examples:
    $SCRIPT_NAME --macos sonoma --xcode 16.1 --org Bitwild
    $SCRIPT_NAME -m ventura -x 15.0 -o MyOrg

This script automates the setup of macOS VMs for GitHub Actions runners.
EOF
}

parse_arguments() {
    [[ $# -gt 0 ]] || { show_usage; exit 0; }

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h) show_usage; exit 0 ;;
            --macos|-m)
                [[ $# -ge 2 ]] || die 2 "Missing value for --macos parameter."
                shift
                MACOS_VERSION="$1"
                ;;
            --xcode|-x)
                [[ $# -ge 2 ]] || die 2 "Missing value for --xcode parameter."
                shift
                XCODE_VERSION="$1"
                ;;
            --org|-o)
                [[ $# -ge 2 ]] || die 2 "Missing value for --org parameter."
                shift
                GITHUB_ORGANIZATION="$1"
                ;;
            -*)
                die 2 "Unknown parameter: $1. Use --help for usage information."
                ;;
            *)
                die 2 "Positional arguments are not supported. Use named parameters instead."
                ;;
        esac
        shift
    done

    # Validate that all required parameters are provided
    [[ -n "$MACOS_VERSION" ]] || die 2 "Missing macOS version. Use --macos <version>."
    [[ -n "$XCODE_VERSION" ]] || die 2 "Missing Xcode version. Use --xcode <version>."
    [[ -n "$GITHUB_ORGANIZATION" ]] || die 2 "Missing GitHub organization name. Use --org <name>."
}

# === MAIN ENTRY POINT ===
main() {
    parse_arguments "$@"
    validate_parameters "$MACOS_VERSION" "$XCODE_VERSION" "$GITHUB_ORGANIZATION"
    validate_prerequisites
    confirm_setup "$MACOS_VERSION" "$XCODE_VERSION" "$GITHUB_ORGANIZATION"
    pull_base_image "$MACOS_VERSION" "$XCODE_VERSION"
    local github_token=$(get_github_token "$GITHUB_ORGANIZATION")
    initialize_packer
    [[ -d "$CACHE_DIR_PATH" ]] || mkdir -p "$CACHE_DIR_PATH"
    build_vm_image "$MACOS_VERSION" "$XCODE_VERSION" "$GITHUB_ORGANIZATION" "$github_token"
    show_next_steps "$MACOS_VERSION" "$XCODE_VERSION"
    echo "[INFO] VM setup completed successfully."
}

main "$@"
