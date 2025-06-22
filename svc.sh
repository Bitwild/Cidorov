#!/bin/bash
set -uo pipefail

# === CONSTANTS ===
readonly SCRIPT_NAME="$(basename "$0")"
readonly LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
readonly LOGS_DIR="$HOME/Library/Logs"
readonly TART_BINARY="/opt/homebrew/bin/tart"
readonly LABEL_BASE="co.bitwild.tartly.tart"
readonly LOG_PREFIX="tartly"

# === UTILITY FUNCTIONS ===
log_info() { echo "[INFO] $*" >&2; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }
die() { local exit_code="${1:-1}"; shift; log_error "$*"; exit "$exit_code"; }
prompt_yes_no() {
    local prompt="$1" response
    while true; do
        read -p "$prompt [y/N]: " response
        response="${response:-n}"
        case "$response" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

# === NAME CONVERSION FUNCTIONS ===
vm_name_to_sanitized() { echo "$1" | sed 's/[:\/]/-/g' | tr '[:upper:]' '[:lower:]'; }
vm_name_to_label() { echo "${LABEL_BASE}.$(vm_name_to_sanitized "$1")"; }
vm_name_to_plist_path() { echo "${LAUNCH_AGENTS_DIR}/$(vm_name_to_label "$1").plist"; }
vm_name_to_log_paths() {
    local sanitized=$(vm_name_to_sanitized "$1")
    echo "${LOGS_DIR}/${LOG_PREFIX}-${sanitized}.log"
    echo "${LOGS_DIR}/${LOG_PREFIX}-${sanitized}.err.log"
}
label_to_vm_name() { echo "$1" | sed "s/^${LABEL_BASE}\.//"; }

# === VALIDATION FUNCTIONS ===
vm_exists() { "$TART_BINARY" list 2>/dev/null | awk 'NR>1 {print $2}' | grep -q "^${1}$"; }
is_agent_installed() { [[ -f "$(vm_name_to_plist_path "$1")" ]]; }
is_agent_running() {
    local label="$1"
    # Check if the launch agent is actually running (has a PID).
    if launchctl list | grep -q "$label"; then
        local pid=$(launchctl list | grep "$label" | awk '{print $1}')
        # Check if the first field is a PID (numeric) and not "-".
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            return 0  # Running
        fi
    fi
    return 1  # Not running
}
is_vm_running() {
    local vm_name="$1"
    # Check the actual VM status in tart, not just the launch agent.
    if "$TART_BINARY" list 2>/dev/null | awk -v vm="$vm_name" 'NR>1 && $2 == vm {print $NF}' | grep -q "^running$"; then
        return 0
    else
        return 1
    fi
}
validate_prerequisites() {
    [[ "$(uname)" == "Darwin" ]] || die 6 "This script can only run on macOS."
    command -v tart >/dev/null 2>&1 || die 6 "tart is not installed. Please install tart with: brew install cirruslabs/cli/tart."
    command -v launchctl >/dev/null 2>&1 || die 6 "launchctl is not available. This should never happen on macOS."
    [[ -d "$LAUNCH_AGENTS_DIR" ]] || mkdir -p "$LAUNCH_AGENTS_DIR" 2>/dev/null || die 6 "Cannot create or write to LaunchAgents directory: $LAUNCH_AGENTS_DIR."
    [[ -d "$LOGS_DIR" ]] || mkdir -p "$LOGS_DIR" 2>/dev/null || die 6 "Cannot create or write to Logs directory: $LOGS_DIR."
    }

# === DIRECTORY MANAGEMENT ===
ensure_cache_directory() {
    local cache_dir="$HOME/.tartly/cache"
    if [[ ! -d "$cache_dir" ]]; then
        log_info "Creating cache directory: $cache_dir"
        mkdir -p "$cache_dir" || die 6 "Failed to create cache directory: $cache_dir"
    fi
    }

# === CORE FUNCTIONS ===
generate_plist() {
    local vm_name="$1" plist_path="$2" label=$(vm_name_to_label "$vm_name")
    local stdout_log=$(vm_name_to_log_paths "$vm_name" | head -n 1)
    local stderr_log=$(vm_name_to_log_paths "$vm_name" | tail -n 1)
    cat > "$plist_path" << EOF || die 6 "Failed to write plist file."
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
    <dict>
        <key>Label</key>
        <string>$label</string>
        <key>ProgramArguments</key>
        <array>
            <string>$TART_BINARY</string>
            <string>run</string>
            <string>--no-graphics</string>
            <string>--dir=cache:~/.tartly/cache</string>
            <string>$vm_name</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <dict>
            <key>SuccessfulExit</key>
            <false/>
        </dict>
        <key>StandardOutPath</key>
        <string>$stdout_log</string>
        <key>StandardErrorPath</key>
        <string>$stderr_log</string>
        <key>TartlyVMName</key>
        <string>$vm_name</string>
    </dict>
</plist>
EOF
}
vm_install() {
    local vm_name="$1" force="${2:-false}" plist_path=$(vm_name_to_plist_path "$vm_name") label=$(vm_name_to_label "$vm_name")
    log_info "Installing VM: $vm_name"
    [[ -n "$vm_name" ]] || die 7 "VM name cannot be empty"
    if is_agent_installed "$vm_name"; then
        if [[ "$force" != "true" ]] && ! prompt_yes_no "Agent for VM '$vm_name' already exists. Overwrite?"; then
            log_info "Installation cancelled."
            return
        fi
        log_info "Removing existing installation..."
        uninstall_vm "$vm_name" || return 1
    fi
    ensure_cache_directory || die 6 "Failed to ensure cache directory exists."
    mkdir -p "$LAUNCH_AGENTS_DIR" "$LOGS_DIR" || die 6 "Failed to create directories."
    generate_plist "$vm_name" "$plist_path" || die 6 "Failed to generate plist file."
    launchctl bootstrap "gui/$(id -u)" "$plist_path" || die 6 "Failed to register launch agent."
    log_info "VM '$vm_name' installed successfully."
    log_info "Plist file: $plist_path."
}
vm_start() {
    local vm_name="$1" label=$(vm_name_to_label "$vm_name")
    log_info "Starting VM: $vm_name"
    [[ -n "$vm_name" ]] || die 7 "VM name cannot be empty"
    is_agent_installed "$vm_name" || die 3 "VM '$vm_name' is not installed."
    ! is_vm_running "$vm_name" || die 5 "VM '$vm_name' is already running"
    ensure_cache_directory || die 6 "Failed to ensure cache directory exists."
    launchctl start "$label" || die 6 "Failed to start VM."
    # Wait a moment for the VM to start in tart.
    sleep 2
    log_info "VM '$vm_name' started successfully."
}
vm_stop() {
    local vm_name="$1" label=$(vm_name_to_label "$vm_name")
    log_info "Stopping VM: $vm_name"
    [[ -n "$vm_name" ]] || die 7 "VM name cannot be empty"
    is_agent_installed "$vm_name" || die 3 "VM '$vm_name' is not installed."
    is_vm_running "$vm_name" || die 5 "VM '$vm_name' is not running."
    # First stop the launch agent.
    launchctl stop "$label" || log_warn "Failed to stop launch agent (may already be stopped)."
    # Wait a moment for the VM to stop via launch agent.
    sleep 2
    # Check if VM is still running, and if so, stop it with tart.
    if is_vm_running "$vm_name"; then
        "$TART_BINARY" stop "$vm_name" || die 6 "Failed to stop VM in tart."
    else
        log_info "VM already stopped via launch agent."
    fi
    # Final wait to ensure VM is fully stopped.
    sleep 1
    log_info "VM '$vm_name' stopped successfully."
}
vm_list() {
    local verbose="${1:-false}" pattern="${LABEL_BASE}.*" plist_files=()
    while IFS= read -r -d '' file; do
        plist_files+=("$file")
    done < <(find "$LAUNCH_AGENTS_DIR" -name "${pattern}.plist" -print0 2>/dev/null)
    if [[ ${#plist_files[@]} -eq 0 ]]; then
        log_info "No managed VMs found."
        return
    fi
    if [[ "$verbose" == "true" ]]; then
        printf "%-30s %-15s %-15s %-40s\n" "VM Name" "Launch Agent" "VM Status" "Label"
        printf "%-30s %-15s %-15s %-40s\n" "------------------------------" "---------------" "---------------" "----------------------------------------"
    else
        printf "%-30s %-15s %-15s\n" "VM Name" "Launch Agent" "VM Status"
        printf "%-30s %-15s %-15s\n" "------------------------------" "---------------" "---------------"
    fi
    for plist_file in "${plist_files[@]}"; do
        local basename_val label
        basename_val=$(basename "$plist_file" .plist)
        label="$basename_val"
        local vm_name=$(/usr/libexec/PlistBuddy -c "Print :TartlyVMName" "$plist_file" 2>/dev/null || label_to_vm_name "$label")
        local launch_agent_status vm_status
        # Check launch agent status using the new function.
        if is_agent_running "$label"; then
            launch_agent_status="Running"
        else
            launch_agent_status="Stopped"
        fi
        # Check VM status using the existing function.
        if vm_exists "$vm_name"; then
            if is_vm_running "$vm_name"; then
                vm_status="Running"
            else
                vm_status="Stopped"
            fi
        else
            vm_status="Not found"
        fi
        if [[ "$verbose" == "true" ]]; then
            printf "%-30s %-15s %-15s %-40s\n" "$vm_name" "$launch_agent_status" "$vm_status" "$label"
        else
            printf "%-30s %-15s %-15s\n" "$vm_name" "$launch_agent_status" "$vm_status"
        fi
    done
}
uninstall_vm() {
    local vm_name="$1" cleanup_logs="${2:-false}" label=$(vm_name_to_label "$vm_name") plist_path=$(vm_name_to_plist_path "$vm_name")
    local stdout_log=$(vm_name_to_log_paths "$vm_name" | head -n 1)
    local stderr_log=$(vm_name_to_log_paths "$vm_name" | tail -n 1)
    log_info "Uninstalling VM: $vm_name"
    [[ -n "$vm_name" ]] || die 7 "VM name cannot be empty"
    is_agent_installed "$vm_name" || die 3 "VM '$vm_name' is not installed."
    if is_vm_running "$vm_name"; then
        log_info "Stopping VM before uninstall..."
        vm_stop "$vm_name" || { log_error "Failed to stop VM '$vm_name'."; return 1; }
    fi
    if [[ -f "$plist_path" ]]; then
        log_info "Removing launch agent..."
        launchctl bootout "gui/$(id -u)" "$plist_path" || log_warn "Failed to unregister launch agent (may already be unregistered)."
        rm -f "$plist_path"
        log_info "Removed plist file: $plist_path."
    else
        log_warn "Plist file not found: $plist_path."
    fi
    if [[ -f "$stdout_log" ]] || [[ -f "$stderr_log" ]]; then
        if [[ "$cleanup_logs" == "true" ]] || prompt_yes_no "Remove log files for VM '$vm_name'?"; then
            log_info "Removing log files..."
            [[ -f "$stdout_log" ]] && rm -f "$stdout_log" && log_info "Removed log file: $stdout_log."
            [[ -f "$stderr_log" ]] && rm -f "$stderr_log" && log_info "Removed log file: $stderr_log."
        else
            log_info "Log files preserved."
            [[ -f "$stdout_log" ]] && log_info "Log file: $stdout_log."
            [[ -f "$stderr_log" ]] && log_info "Log file: $stderr_log."
        fi
    else
        log_info "No log files found for VM '$vm_name'."
    fi
    log_info "VM '$vm_name' uninstalled successfully."
}

# === COMMAND-LINE INTERFACE ===
show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME <command> [options] [arguments]

Commands:
    list [--verbose|-v]           List all managed VMs with launch agent and VM status
    install <vm-name> [--force]   Install a VM as a launch agent (checks if agent already exists)
    start <vm-name>               Start an installed VM
    stop <vm-name>                Stop a running VM
    uninstall <vm-name> [--clean-logs]  Uninstall a VM and remove launch agent
    help                          Show this help message

Options:
    --force, -f                   Force installation (overwrite existing)
    --verbose, -v                 Show detailed information including labels
    --clean-logs, -c              Automatically clean up log files without prompting

Examples:
    $SCRIPT_NAME list
    $SCRIPT_NAME list --verbose
    $SCRIPT_NAME install macos-sonoma-xcode:16.1
    $SCRIPT_NAME start macos-sonoma-xcode:16.1
    $SCRIPT_NAME stop macos-sonoma-xcode:16.1
    $SCRIPT_NAME uninstall macos-sonoma-xcode:16.1
    $SCRIPT_NAME uninstall macos-sonoma-xcode:16.1 --clean-logs
    $SCRIPT_NAME install macos-ventura-xcode:15.0 --force

Notes:
    - The install command checks if an agent already exists before creating a new launch agent
    - The list command shows both launch agent status and actual VM status from Tart
    - VM status can be: Running, Stopped, Not found, or Error (if check fails)

For more information, see the documentation
EOF
}

# === MAIN ENTRY POINT ===
main() {
    validate_prerequisites || return
    local command="${1:-}"
    shift || true
    case "$command" in
        list)
            local verbose=false
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --verbose|-v) verbose=true ;;
                    *) die 2 "Unknown option: $1" ;;
                esac
                shift
            done
            vm_list "$verbose" || return
            ;;
        install)
            local force=false vm_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --force|-f) force=true ;;
                    -*) die 2 "Unknown option: $1" ;;
                    *)
                        if [[ -z "$vm_name" ]]; then
                            vm_name="$1"
                        else
                            die 2 "Too many arguments"
                        fi
                        ;;
                esac
                shift
            done
            [[ -n "$vm_name" ]] || die 2 "install command requires VM name"
            vm_install "$vm_name" "$force" || return
            ;;
        start)
            local vm_name="${1:-}"
            [[ -n "$vm_name" ]] || die 2 "start command requires VM name"
            vm_start "$vm_name" || return
            ;;
        stop)
            local vm_name="${1:-}"
            [[ -n "$vm_name" ]] || die 2 "stop command requires VM name"
            vm_stop "$vm_name" || return
            ;;
        uninstall)
            local vm_name="" cleanup_logs=false
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --clean-logs|-c) cleanup_logs=true ;;
                    -*) die 2 "Unknown option: $1" ;;
                    *)
                        if [[ -z "$vm_name" ]]; then
                            vm_name="$1"
                        else
                            die 2 "Too many arguments"
                        fi
                        ;;
                esac
                shift
            done
            [[ -n "$vm_name" ]] || die 2 "uninstall command requires VM name"
            uninstall_vm "$vm_name" "$cleanup_logs" || return
            ;;
        help|--help|-h)
            show_usage
            return
            ;;
        "")
            show_usage
            die 2 "No command specified."
            ;;
        *)
            die 2 "Unknown command: $command."
            ;;
    esac
}

main "$@"
