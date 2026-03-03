#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  GNOME Configuration Exporter                                              ║
# ║  Full GNOME desktop configuration backup & restore tool                    ║
# ║                                                                            ║
# ║  Backs up EVERYTHING:                                                      ║
# ║    - dconf database (full + selective section dumps)                        ║
# ║    - GNOME Shell extensions (files + enabled state + per-ext settings)      ║
# ║    - Keybindings (WM, Shell, custom shortcuts)                             ║
# ║    - Themes, icons, fonts, wallpapers                                      ║
# ║    - GTK 3/4 settings, Autostart entries, Monitor config                   ║
# ║    - Terminal profiles, Nautilus prefs, GNOME Online Accounts              ║
# ║    - Keyrings, mimeapps, desktop files, XDG user dirs                      ║
# ║                                                                            ║
# ║  Usage:                                                                    ║
# ║    ./gnome-cfg-exporter.sh              # Interactive TUI (dialog)         ║
# ║    ./gnome-cfg-exporter.sh --backup     # Full backup from CLI             ║
# ║    ./gnome-cfg-exporter.sh --restore <path>  # Restore from backup         ║
# ║    ./gnome-cfg-exporter.sh --list       # List previous backups            ║
# ║    ./gnome-cfg-exporter.sh --help       # Show help                        ║
# ║                                                                            ║
# ║  Supports: Arch, Fedora, Ubuntu/Debian, openSUSE, and more                ║
# ║  Dependencies: dconf, rsync (required) · dialog (optional, for TUI)        ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

set -uo pipefail

# ==============================================================================
# Constants
# ==============================================================================

readonly VERSION="1.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly BACKUP_BASE_DIR="${GNOME_CFG_EXPORTER_DIR:-$HOME/.local/share/gnome-cfg-exporter}"
readonly LOG_FILE="${BACKUP_BASE_DIR}/exporter.log"
readonly DIALOG_TITLE="GNOME Config Exporter v${VERSION}"
readonly BACKTITLE="GNOME Configuration Exporter — Full desktop config backup & restore"

# Colors (CLI mode)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly DIM='\033[2m'
readonly RESET='\033[0m'

# dconf paths for selective backup/restore
declare -A DCONF_SECTIONS=(
    ["gnome_desktop"]="/org/gnome/desktop/"
    ["gnome_shell"]="/org/gnome/shell/"
    ["gnome_terminal"]="/org/gnome/terminal/"
    ["gnome_settings_daemon"]="/org/gnome/settings-daemon/"
    ["gnome_mutter"]="/org/gnome/mutter/"
    ["gnome_nautilus"]="/org/gnome/nautilus/"
    ["gtk_settings"]="/org/gtk/"
    ["gnome_text_editor"]="/org/gnome/TextEditor/"
    ["gnome_calculator"]="/org/gnome/calculator/"
    ["gnome_control_center"]="/org/gnome/control-center/"
    ["gnome_clocks"]="/org/gnome/clocks/"
    ["gnome_weather"]="/org/gnome/Weather/"
)

# File-based configuration sources
declare -A FILE_SOURCES=(
    ["extensions"]="$HOME/.local/share/gnome-shell/extensions"
    ["autostart"]="$HOME/.config/autostart"
    ["gtk-3.0"]="$HOME/.config/gtk-3.0"
    ["gtk-4.0"]="$HOME/.config/gtk-4.0"
    ["themes_local"]="$HOME/.local/share/themes"
    ["themes_legacy"]="$HOME/.themes"
    ["icons_local"]="$HOME/.local/share/icons"
    ["icons_legacy"]="$HOME/.icons"
    ["fonts_local"]="$HOME/.local/share/fonts"
    ["fonts_legacy"]="$HOME/.fonts"
    ["backgrounds"]="$HOME/.local/share/backgrounds"
    ["desktop-files"]="$HOME/.local/share/applications"
    ["nautilus-scripts"]="$HOME/.local/share/nautilus/scripts"
    ["keyrings"]="$HOME/.local/share/keyrings"
    ["goa-1.0"]="$HOME/.config/goa-1.0"
)

# Single files to back up
declare -a SINGLE_FILES=(
    "$HOME/.config/monitors.xml"
    "$HOME/.config/mimeapps.list"
    "$HOME/.config/user-dirs.dirs"
    "$HOME/.config/user-dirs.locale"
    "$HOME/.config/gnome-initial-setup-done"
)

# TUI mode flag
TUI_MODE=false

# ==============================================================================
# Utility functions
# ==============================================================================

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    mkdir -p "$(dirname "$LOG_FILE")"
    echo "[$timestamp] [$level] $msg" >> "$LOG_FILE"
}

msg_ok()   { echo -e "${GREEN}[OK]${RESET}   $*"; log "INFO" "$*"; }
msg_warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; log "WARN" "$*"; }
msg_fail() { echo -e "${RED}[FAIL]${RESET} $*"; log "ERROR" "$*"; }
msg_info() { echo -e "${BLUE}[INFO]${RESET} $*"; log "INFO" "$*"; }
msg_step() { echo -e "${CYAN}[>>>]${RESET}  ${BOLD}$*${RESET}"; log "STEP" "$*"; }

# Human-readable directory size
dir_size() {
    if [[ -d "$1" ]]; then
        du -sh "$1" 2>/dev/null | cut -f1
    else
        echo "0B"
    fi
}

# Safe rsync directory copy
safe_copy_dir() {
    local src="$1"
    local dst="$2"
    if [[ -d "$src" ]]; then
        mkdir -p "$dst"
        rsync -a --quiet "$src/" "$dst/" 2>/dev/null
        return 0
    fi
    return 1
}

# Safe file copy
safe_copy_file() {
    local src="$1"
    local dst_dir="$2"
    if [[ -f "$src" ]]; then
        mkdir -p "$dst_dir"
        cp -a "$src" "$dst_dir/" 2>/dev/null
        return 0
    fi
    return 1
}

# List available backups (newest first)
list_backups() {
    local -a backups=()
    if [[ ! -d "$BACKUP_BASE_DIR" ]]; then
        return 1
    fi
    while IFS= read -r dir; do
        [[ -d "$dir" && -f "$dir/metadata/timestamp.txt" ]] && backups+=("$dir")
    done < <(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)
    if [[ ${#backups[@]} -eq 0 ]]; then
        return 1
    fi
    printf '%s\n' "${backups[@]}"
}

# Get backup summary info
backup_info() {
    local bdir="$1"
    local ts gnome_ver host size
    ts="$(cat "$bdir/metadata/timestamp.txt" 2>/dev/null || echo '?')"
    gnome_ver="$(cat "$bdir/metadata/gnome_version.txt" 2>/dev/null || echo '?')"
    host="$(cat "$bdir/metadata/hostname.txt" 2>/dev/null || echo '?')"
    size="$(dir_size "$bdir")"
    echo "$ts | GNOME: $gnome_ver | Host: $host | Size: $size"
}

# ==============================================================================
# Package manager detection & installation
# ==============================================================================

# Detect the system package manager
detect_pkg_manager() {
    if command -v pacman &>/dev/null; then
        echo "pacman"
    elif command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v zypper &>/dev/null; then
        echo "zypper"
    elif command -v apk &>/dev/null; then
        echo "apk"
    elif command -v xbps-install &>/dev/null; then
        echo "xbps"
    elif command -v emerge &>/dev/null; then
        echo "portage"
    elif command -v nix-env &>/dev/null; then
        echo "nix"
    else
        echo "unknown"
    fi
}

# Map a generic package name to the distro-specific package name
map_pkg_name() {
    local generic="$1"
    local pm
    pm="$(detect_pkg_manager)"

    case "$pm" in
        pacman)
            case "$generic" in
                dialog)   echo "dialog" ;;
                dconf)    echo "dconf" ;;
                rsync)    echo "rsync" ;;
                glib)     echo "glib2" ;;
            esac
            ;;
        apt)
            case "$generic" in
                dialog)   echo "dialog" ;;
                dconf)    echo "dconf-cli" ;;
                rsync)    echo "rsync" ;;
                glib)     echo "libglib2.0-bin" ;;
            esac
            ;;
        dnf)
            case "$generic" in
                dialog)   echo "dialog" ;;
                dconf)    echo "dconf" ;;
                rsync)    echo "rsync" ;;
                glib)     echo "glib2" ;;
            esac
            ;;
        zypper)
            case "$generic" in
                dialog)   echo "dialog" ;;
                dconf)    echo "dconf" ;;
                rsync)    echo "rsync" ;;
                glib)     echo "glib2-tools" ;;
            esac
            ;;
        apk)
            case "$generic" in
                dialog)   echo "dialog" ;;
                dconf)    echo "dconf" ;;
                rsync)    echo "rsync" ;;
                glib)     echo "glib" ;;
            esac
            ;;
        xbps)
            case "$generic" in
                dialog)   echo "dialog" ;;
                dconf)    echo "dconf" ;;
                rsync)    echo "rsync" ;;
                glib)     echo "glib" ;;
            esac
            ;;
        *)
            echo "$generic"
            ;;
    esac
}

# Build the install command for the detected package manager
install_cmd() {
    local pkg="$1"
    local pm
    pm="$(detect_pkg_manager)"

    case "$pm" in
        pacman)  echo "sudo pacman -S --noconfirm $pkg" ;;
        apt)     echo "sudo apt-get install -y $pkg" ;;
        dnf)     echo "sudo dnf install -y $pkg" ;;
        zypper)  echo "sudo zypper install -y $pkg" ;;
        apk)     echo "sudo apk add $pkg" ;;
        xbps)    echo "sudo xbps-install -y $pkg" ;;
        portage) echo "sudo emerge $pkg" ;;
        nix)     echo "nix-env -iA nixpkgs.$pkg" ;;
        *)       echo "echo 'Unknown package manager — please install $pkg manually'" ;;
    esac
}

# Prompt user to install a missing package
# Returns 0 if installed (or already present), 1 if user declined
prompt_install() {
    local cmd_name="$1"
    local generic_pkg="$2"
    local description="$3"

    if command -v "$cmd_name" &>/dev/null; then
        return 0
    fi

    local distro_pkg
    distro_pkg="$(map_pkg_name "$generic_pkg")"
    local cmd
    cmd="$(install_cmd "$distro_pkg")"
    local pm
    pm="$(detect_pkg_manager)"

    echo ""
    msg_warn "'$cmd_name' is not installed ($description)"
    msg_info "Package: $distro_pkg (detected package manager: $pm)"
    echo ""
    read -rp "  Install it now? [$cmd] (Y/n): " answer
    answer="${answer:-y}"

    if [[ "$answer" =~ ^[yY]$ ]]; then
        msg_info "Running: $cmd"
        if eval "$cmd"; then
            msg_ok "'$cmd_name' installed successfully"
            return 0
        else
            msg_fail "Installation failed. Please install '$distro_pkg' manually."
            return 1
        fi
    else
        msg_info "Skipping installation of '$cmd_name'"
        return 1
    fi
}

# ==============================================================================
# Dependency checks
# ==============================================================================

check_dependencies() {
    local has_critical_failure=false

    # Critical: dconf
    if ! command -v dconf &>/dev/null; then
        if ! prompt_install "dconf" "dconf" "required for reading/writing GNOME settings"; then
            has_critical_failure=true
        fi
    fi

    # Critical: gsettings
    if ! command -v gsettings &>/dev/null; then
        if ! prompt_install "gsettings" "glib" "required for GNOME settings queries"; then
            has_critical_failure=true
        fi
    fi

    # Critical: rsync
    if ! command -v rsync &>/dev/null; then
        if ! prompt_install "rsync" "rsync" "required for efficient file copying"; then
            has_critical_failure=true
        fi
    fi

    if [[ "$has_critical_failure" == true ]]; then
        msg_fail "Missing critical dependencies. Cannot continue."
        return 1
    fi

    # Optional: dialog (for TUI mode)
    if ! command -v dialog &>/dev/null; then
        msg_warn "'dialog' is not installed — TUI mode unavailable"
        prompt_install "dialog" "dialog" "optional, needed for interactive TUI mode" || true
        if ! command -v dialog &>/dev/null; then
            msg_info "CLI mode is still available (--backup, --restore, --list)"
        fi
    fi

    # D-Bus session bus check
    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        msg_warn "D-Bus session bus not available. dconf dump/load may not work."
        msg_info "Make sure you're running this script from within a graphical session."
        return 1
    fi

    # Optional: gnome-extensions
    if ! command -v gnome-extensions &>/dev/null; then
        msg_warn "'gnome-extensions' not found — extension listing will be skipped"
    fi

    return 0
}

# ==============================================================================
# BACKUP FUNCTIONS
# ==============================================================================

# --- Metadata ---
backup_metadata() {
    local bdir="$1"
    local meta_dir="$bdir/metadata"
    mkdir -p "$meta_dir"

    date --iso-8601=seconds > "$meta_dir/timestamp.txt"
    hostname > "$meta_dir/hostname.txt"
    whoami > "$meta_dir/username.txt"
    echo "$VERSION" > "$meta_dir/exporter_version.txt"
    uname -a > "$meta_dir/system_info.txt" 2>/dev/null || true

    if command -v gnome-shell &>/dev/null; then
        gnome-shell --version > "$meta_dir/gnome_version.txt" 2>/dev/null || echo "unknown" > "$meta_dir/gnome_version.txt"
    else
        echo "unknown" > "$meta_dir/gnome_version.txt"
    fi

    echo "${XDG_SESSION_TYPE:-unknown}" > "$meta_dir/session_type.txt"

    if command -v gnome-extensions &>/dev/null; then
        gnome-extensions list --user --details > "$meta_dir/extensions_list_user.txt" 2>/dev/null || true
        gnome-extensions list --enabled > "$meta_dir/extensions_enabled.txt" 2>/dev/null || true
        gnome-extensions list > "$meta_dir/extensions_list_all.txt" 2>/dev/null || true
    fi

    # Record installed GNOME-related packages (distro-specific)
    local pm
    pm="$(detect_pkg_manager)"
    case "$pm" in
        pacman)  pacman -Qqe 2>/dev/null | grep -iE 'gnome|gtk|mutter|gdm|nautilus|adwaita|glib' > "$meta_dir/installed_packages.txt" || true ;;
        apt)     dpkg -l 2>/dev/null | grep -iE 'gnome|gtk|mutter|gdm|nautilus|adwaita|glib' > "$meta_dir/installed_packages.txt" || true ;;
        dnf)     rpm -qa 2>/dev/null | grep -iE 'gnome|gtk|mutter|gdm|nautilus|adwaita|glib' > "$meta_dir/installed_packages.txt" || true ;;
        zypper)  rpm -qa 2>/dev/null | grep -iE 'gnome|gtk|mutter|gdm|nautilus|adwaita|glib' > "$meta_dir/installed_packages.txt" || true ;;
        *)       echo "# Package list unavailable for: $pm" > "$meta_dir/installed_packages.txt" ;;
    esac

    msg_ok "Metadata saved"
}

# --- dconf dumps ---
backup_dconf() {
    local bdir="$1"
    local dconf_dir="$bdir/dconf"
    mkdir -p "$dconf_dir"

    # Full dump
    if dconf dump / > "$dconf_dir/full_dump.ini" 2>/dev/null; then
        msg_ok "dconf full dump complete ($(wc -l < "$dconf_dir/full_dump.ini") lines)"
    else
        msg_fail "dconf full dump failed"
        return 1
    fi

    # Selective dumps for granular restore
    local key path
    for key in "${!DCONF_SECTIONS[@]}"; do
        path="${DCONF_SECTIONS[$key]}"
        if dconf dump "$path" > "$dconf_dir/${key}.ini" 2>/dev/null; then
            local lines
            lines=$(wc -l < "$dconf_dir/${key}.ini")
            if [[ "$lines" -gt 0 ]]; then
                msg_ok "  dconf section: $key ($lines lines)"
            else
                rm -f "$dconf_dir/${key}.ini"
            fi
        fi
    done

    # Binary dconf database backup (atomic safety net)
    if [[ -f "$HOME/.config/dconf/user" ]]; then
        cp -a "$HOME/.config/dconf/user" "$dconf_dir/dconf_user.bak"
        msg_ok "  dconf binary DB saved ($(du -sh "$dconf_dir/dconf_user.bak" | cut -f1))"
    fi

    return 0
}

# --- Extension files ---
backup_extensions() {
    local bdir="$1"
    local ext_src="$HOME/.local/share/gnome-shell/extensions"

    if [[ ! -d "$ext_src" ]]; then
        msg_warn "Extension directory not found: $ext_src"
        return 0
    fi

    local ext_count
    ext_count=$(find "$ext_src" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

    if [[ "$ext_count" -eq 0 ]]; then
        msg_info "No user extensions found"
        return 0
    fi

    safe_copy_dir "$ext_src" "$bdir/extensions"
    msg_ok "Extensions saved ($ext_count extensions, $(dir_size "$bdir/extensions"))"
}

# --- File-based configs ---
backup_file_configs() {
    local bdir="$1"
    local files_dir="$bdir/files"
    mkdir -p "$files_dir"

    # Directory sources
    local key src
    for key in "${!FILE_SOURCES[@]}"; do
        src="${FILE_SOURCES[$key]}"
        if safe_copy_dir "$src" "$files_dir/$key"; then
            msg_ok "  $key saved ($(dir_size "$files_dir/$key"))"
        fi
    done

    # Single files
    mkdir -p "$files_dir/single"
    local f
    for f in "${SINGLE_FILES[@]}"; do
        if safe_copy_file "$f" "$files_dir/single"; then
            msg_ok "  $(basename "$f") saved"
        fi
    done
}

# --- FULL BACKUP (CLI mode) ---
do_backup_cli() {
    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local bdir="$BACKUP_BASE_DIR/$timestamp"

    mkdir -p "$bdir"
    log "INFO" "=== BACKUP STARTED: $bdir ==="

    echo ""
    msg_step "Starting GNOME configuration backup..."
    msg_info "Target: $bdir"
    echo ""

    msg_step "1/4 — Saving metadata..."
    backup_metadata "$bdir"
    echo ""

    msg_step "2/4 — Dumping dconf database..."
    backup_dconf "$bdir"
    echo ""

    msg_step "3/4 — Saving extension files..."
    backup_extensions "$bdir"
    echo ""

    msg_step "4/4 — Saving file-based configurations..."
    backup_file_configs "$bdir"
    echo ""

    # Summary
    local total_size
    total_size="$(dir_size "$bdir")"
    local total_files
    total_files="$(find "$bdir" -type f | wc -l)"

    echo ""
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}${BOLD}  BACKUP COMPLETE!${RESET}"
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
    echo -e "  ${BOLD}Path:${RESET}   $bdir"
    echo -e "  ${BOLD}Size:${RESET}   $total_size"
    echo -e "  ${BOLD}Files:${RESET}  $total_files"
    echo -e "  ${BOLD}Time:${RESET}   $(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
    echo ""

    log "INFO" "=== BACKUP COMPLETED: $bdir ($total_size, $total_files files) ==="
}

# --- FULL BACKUP (TUI mode with dialog --gauge) ---
do_backup_tui() {
    local categories=()
    local select_mode="${1:-full}"

    if [[ "$select_mode" == "selective" ]]; then
        local result
        result=$(dialog --backtitle "$BACKTITLE" --title "Selective Backup" \
            --checklist "Choose items to back up:" 22 70 15 \
            "dconf"       "dconf database (full + selective section dumps)" ON \
            "extensions"  "GNOME Shell extensions (files)" ON \
            "keybindings" "Keybindings (included in dconf)" ON \
            "themes"      "Themes and icons" ON \
            "fonts"       "Fonts" ON \
            "backgrounds" "Wallpapers" ON \
            "gtk"         "GTK 3/4 settings (settings.ini, gtk.css)" ON \
            "autostart"   "Autostart applications" ON \
            "terminal"    "Terminal profiles (included in dconf)" ON \
            "monitors"    "Monitor configuration (monitors.xml)" ON \
            "nautilus"    "File manager settings & scripts" ON \
            "mimeapps"    "Default applications (mimeapps.list)" ON \
            "goa"         "GNOME Online Accounts" ON \
            "keyrings"    "Keyrings (passwords, tokens)" ON \
            "desktop"     "Desktop files (.desktop)" ON \
            3>&1 1>&2 2>&3)

        local exit_code=$?
        if [[ $exit_code -ne 0 || -z "$result" ]]; then
            return 1
        fi
        # shellcheck disable=SC2206
        categories=($result)
    else
        categories=("dconf" "extensions" "keybindings" "themes" "fonts" "backgrounds" "gtk" "autostart" "terminal" "monitors" "nautilus" "mimeapps" "goa" "keyrings" "desktop")
    fi

    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local bdir="$BACKUP_BASE_DIR/$timestamp"
    mkdir -p "$bdir"
    log "INFO" "=== BACKUP STARTED (TUI): $bdir ==="

    # Progress bar
    local total_steps=$(( ${#categories[@]} + 1 ))  # +1 for metadata
    local current_step=0
    local pct

    {
        # Metadata (always)
        current_step=$((current_step + 1))
        pct=$(( current_step * 100 / total_steps ))
        echo "XXX"
        echo "$pct"
        echo "Saving metadata..."
        echo "XXX"
        backup_metadata "$bdir" >/dev/null 2>&1

        local cat
        for cat in "${categories[@]}"; do
            cat="${cat//\"/}"
            current_step=$((current_step + 1))
            pct=$(( current_step * 100 / total_steps ))

            case "$cat" in
                dconf|keybindings|terminal)
                    echo "XXX"
                    echo "$pct"
                    echo "Dumping dconf database..."
                    echo "XXX"
                    if [[ ! -f "$bdir/dconf/full_dump.ini" ]]; then
                        backup_dconf "$bdir" >/dev/null 2>&1
                    fi
                    ;;
                extensions)
                    echo "XXX"
                    echo "$pct"
                    echo "Saving extensions..."
                    echo "XXX"
                    backup_extensions "$bdir" >/dev/null 2>&1
                    ;;
                themes)
                    echo "XXX"
                    echo "$pct"
                    echo "Saving themes and icons..."
                    echo "XXX"
                    local files_dir="$bdir/files"
                    mkdir -p "$files_dir"
                    safe_copy_dir "${FILE_SOURCES[themes_local]}" "$files_dir/themes_local" 2>/dev/null
                    safe_copy_dir "${FILE_SOURCES[themes_legacy]}" "$files_dir/themes_legacy" 2>/dev/null
                    safe_copy_dir "${FILE_SOURCES[icons_local]}" "$files_dir/icons_local" 2>/dev/null
                    safe_copy_dir "${FILE_SOURCES[icons_legacy]}" "$files_dir/icons_legacy" 2>/dev/null
                    ;;
                fonts)
                    echo "XXX"
                    echo "$pct"
                    echo "Saving fonts..."
                    echo "XXX"
                    local files_dir="$bdir/files"
                    mkdir -p "$files_dir"
                    safe_copy_dir "${FILE_SOURCES[fonts_local]}" "$files_dir/fonts_local" 2>/dev/null
                    safe_copy_dir "${FILE_SOURCES[fonts_legacy]}" "$files_dir/fonts_legacy" 2>/dev/null
                    ;;
                backgrounds)
                    echo "XXX"
                    echo "$pct"
                    echo "Saving wallpapers..."
                    echo "XXX"
                    local files_dir="$bdir/files"
                    mkdir -p "$files_dir"
                    safe_copy_dir "${FILE_SOURCES[backgrounds]}" "$files_dir/backgrounds" 2>/dev/null
                    ;;
                gtk)
                    echo "XXX"
                    echo "$pct"
                    echo "Saving GTK settings..."
                    echo "XXX"
                    local files_dir="$bdir/files"
                    mkdir -p "$files_dir"
                    safe_copy_dir "${FILE_SOURCES[gtk-3.0]}" "$files_dir/gtk-3.0" 2>/dev/null
                    safe_copy_dir "${FILE_SOURCES[gtk-4.0]}" "$files_dir/gtk-4.0" 2>/dev/null
                    ;;
                autostart)
                    echo "XXX"
                    echo "$pct"
                    echo "Saving autostart entries..."
                    echo "XXX"
                    local files_dir="$bdir/files"
                    mkdir -p "$files_dir"
                    safe_copy_dir "${FILE_SOURCES[autostart]}" "$files_dir/autostart" 2>/dev/null
                    ;;
                monitors)
                    echo "XXX"
                    echo "$pct"
                    echo "Saving monitor configuration..."
                    echo "XXX"
                    mkdir -p "$bdir/files/single"
                    safe_copy_file "$HOME/.config/monitors.xml" "$bdir/files/single" 2>/dev/null
                    ;;
                nautilus)
                    echo "XXX"
                    echo "$pct"
                    echo "Saving Nautilus settings..."
                    echo "XXX"
                    local files_dir="$bdir/files"
                    mkdir -p "$files_dir"
                    safe_copy_dir "${FILE_SOURCES[nautilus-scripts]}" "$files_dir/nautilus-scripts" 2>/dev/null
                    ;;
                mimeapps)
                    echo "XXX"
                    echo "$pct"
                    echo "Saving default applications..."
                    echo "XXX"
                    mkdir -p "$bdir/files/single"
                    safe_copy_file "$HOME/.config/mimeapps.list" "$bdir/files/single" 2>/dev/null
                    ;;
                goa)
                    echo "XXX"
                    echo "$pct"
                    echo "Saving GNOME Online Accounts..."
                    echo "XXX"
                    local files_dir="$bdir/files"
                    mkdir -p "$files_dir"
                    safe_copy_dir "${FILE_SOURCES[goa-1.0]}" "$files_dir/goa-1.0" 2>/dev/null
                    ;;
                keyrings)
                    echo "XXX"
                    echo "$pct"
                    echo "Saving keyrings..."
                    echo "XXX"
                    local files_dir="$bdir/files"
                    mkdir -p "$files_dir"
                    safe_copy_dir "${FILE_SOURCES[keyrings]}" "$files_dir/keyrings" 2>/dev/null
                    ;;
                desktop)
                    echo "XXX"
                    echo "$pct"
                    echo "Saving desktop files..."
                    echo "XXX"
                    local files_dir="$bdir/files"
                    mkdir -p "$files_dir"
                    safe_copy_dir "${FILE_SOURCES[desktop-files]}" "$files_dir/desktop-files" 2>/dev/null
                    ;;
            esac
        done

        echo "XXX"
        echo "100"
        echo "Backup complete!"
        echo "XXX"
        sleep 0.5

    } | dialog --backtitle "$BACKTITLE" --title "Backup in progress..." \
              --gauge "Preparing..." 10 60 0

    # Also save single files on full backup
    if [[ "$select_mode" == "full" ]]; then
        mkdir -p "$bdir/files/single"
        local f
        for f in "${SINGLE_FILES[@]}"; do
            safe_copy_file "$f" "$bdir/files/single" 2>/dev/null
        done
    fi

    # Summary
    local total_size
    total_size="$(dir_size "$bdir")"
    local total_files
    total_files="$(find "$bdir" -type f | wc -l)"

    dialog --backtitle "$BACKTITLE" --title "Backup Complete!" \
        --msgbox "$(cat <<EOF
GNOME configuration backed up successfully!

  Path:    $bdir
  Size:    $total_size
  Files:   $total_files
  Time:    $(date '+%Y-%m-%d %H:%M:%S')

The backup contains all selected items.
To restore, choose "Restore" from the main menu.
EOF
)" 16 65

    log "INFO" "=== BACKUP COMPLETED (TUI): $bdir ($total_size, $total_files files) ==="
}

# ==============================================================================
# RESTORE FUNCTIONS
# ==============================================================================

# --- Pre-restore safety backup ---
pre_restore_backup() {
    local timestamp
    timestamp="$(date '+%Y%m%d_%H%M%S')"
    local safety_dir="$BACKUP_BASE_DIR/pre-restore-$timestamp"
    mkdir -p "$safety_dir"

    log "INFO" "Pre-restore safety backup: $safety_dir"

    backup_metadata "$safety_dir" >/dev/null 2>&1
    backup_dconf "$safety_dir" >/dev/null 2>&1
    backup_extensions "$safety_dir" >/dev/null 2>&1
    backup_file_configs "$safety_dir" >/dev/null 2>&1

    echo "$safety_dir"
}

# --- dconf restore ---
restore_dconf() {
    local bdir="$1"
    local mode="${2:-full}"  # full | selective_section_name

    if [[ "$mode" == "full" ]]; then
        local dump_file="$bdir/dconf/full_dump.ini"
        if [[ ! -f "$dump_file" ]]; then
            msg_fail "dconf dump not found: $dump_file"
            return 1
        fi

        msg_info "Restoring full dconf database..."
        dconf reset -f / 2>/dev/null
        if dconf load / < "$dump_file" 2>/dev/null; then
            msg_ok "dconf full restore complete"
        else
            msg_fail "dconf load failed"
            return 1
        fi
    else
        local ini_file="$bdir/dconf/${mode}.ini"
        local dconf_path="${DCONF_SECTIONS[$mode]:-}"

        if [[ -z "$dconf_path" ]]; then
            msg_fail "Unknown dconf section: $mode"
            return 1
        fi

        if [[ ! -f "$ini_file" ]]; then
            msg_warn "Selective dump not found: $ini_file — Skipping"
            return 0
        fi

        dconf reset -f "$dconf_path" 2>/dev/null
        if dconf load "$dconf_path" < "$ini_file" 2>/dev/null; then
            msg_ok "dconf section restored: $mode"
        else
            msg_fail "dconf load failed for section: $mode"
            return 1
        fi
    fi
}

# --- Extension files restore ---
restore_extensions() {
    local bdir="$1"
    local ext_src="$bdir/extensions"
    local ext_dst="$HOME/.local/share/gnome-shell/extensions"

    if [[ ! -d "$ext_src" ]]; then
        msg_warn "No extension backup found"
        return 0
    fi

    mkdir -p "$ext_dst"

    local ext_count
    ext_count=$(find "$ext_src" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

    rsync -a --quiet "$ext_src/" "$ext_dst/" 2>/dev/null
    msg_ok "Extensions restored ($ext_count extensions)"

    # Extension state comes from dconf (gnome_shell section)
    if [[ -f "$bdir/dconf/gnome_shell.ini" ]]; then
        dconf load /org/gnome/shell/ < "$bdir/dconf/gnome_shell.ini" 2>/dev/null
        msg_ok "Extension states (enabled/disabled) restored"
    fi
}

# --- File-based config restore ---
restore_file_config() {
    local bdir="$1"
    local key="$2"
    local files_dir="$bdir/files"

    case "$key" in
        extensions)
            restore_extensions "$bdir"
            ;;
        autostart)
            if [[ -d "$files_dir/autostart" ]]; then
                safe_copy_dir "$files_dir/autostart" "$HOME/.config/autostart"
                msg_ok "Autostart entries restored"
            fi
            ;;
        gtk)
            if [[ -d "$files_dir/gtk-3.0" ]]; then
                safe_copy_dir "$files_dir/gtk-3.0" "$HOME/.config/gtk-3.0"
                msg_ok "GTK 3.0 settings restored"
            fi
            if [[ -d "$files_dir/gtk-4.0" ]]; then
                safe_copy_dir "$files_dir/gtk-4.0" "$HOME/.config/gtk-4.0"
                msg_ok "GTK 4.0 settings restored"
            fi
            ;;
        themes)
            if [[ -d "$files_dir/themes_local" ]]; then
                safe_copy_dir "$files_dir/themes_local" "$HOME/.local/share/themes"
                msg_ok "Themes restored (local)"
            fi
            if [[ -d "$files_dir/themes_legacy" ]]; then
                safe_copy_dir "$files_dir/themes_legacy" "$HOME/.themes"
                msg_ok "Themes restored (legacy)"
            fi
            if [[ -d "$files_dir/icons_local" ]]; then
                safe_copy_dir "$files_dir/icons_local" "$HOME/.local/share/icons"
                msg_ok "Icons restored (local)"
            fi
            if [[ -d "$files_dir/icons_legacy" ]]; then
                safe_copy_dir "$files_dir/icons_legacy" "$HOME/.icons"
                msg_ok "Icons restored (legacy)"
            fi
            ;;
        fonts)
            if [[ -d "$files_dir/fonts_local" ]]; then
                safe_copy_dir "$files_dir/fonts_local" "$HOME/.local/share/fonts"
                msg_ok "Fonts restored (local)"
            fi
            if [[ -d "$files_dir/fonts_legacy" ]]; then
                safe_copy_dir "$files_dir/fonts_legacy" "$HOME/.fonts"
                msg_ok "Fonts restored (legacy)"
            fi
            if command -v fc-cache &>/dev/null; then
                fc-cache -f 2>/dev/null
                msg_ok "Font cache refreshed"
            fi
            ;;
        backgrounds)
            if [[ -d "$files_dir/backgrounds" ]]; then
                safe_copy_dir "$files_dir/backgrounds" "$HOME/.local/share/backgrounds"
                msg_ok "Wallpapers restored"
            fi
            ;;
        monitors)
            if [[ -f "$files_dir/single/monitors.xml" ]]; then
                cp -a "$files_dir/single/monitors.xml" "$HOME/.config/monitors.xml"
                msg_ok "Monitor configuration restored"
            fi
            ;;
        mimeapps)
            if [[ -f "$files_dir/single/mimeapps.list" ]]; then
                cp -a "$files_dir/single/mimeapps.list" "$HOME/.config/mimeapps.list"
                msg_ok "Default applications restored"
            fi
            ;;
        nautilus)
            if [[ -d "$files_dir/nautilus-scripts" ]]; then
                safe_copy_dir "$files_dir/nautilus-scripts" "$HOME/.local/share/nautilus/scripts"
                msg_ok "Nautilus scripts restored"
            fi
            ;;
        goa)
            if [[ -d "$files_dir/goa-1.0" ]]; then
                safe_copy_dir "$files_dir/goa-1.0" "$HOME/.config/goa-1.0"
                msg_ok "GNOME Online Accounts restored"
                msg_warn "Account tokens may require re-authentication"
            fi
            ;;
        keyrings)
            if [[ -d "$files_dir/keyrings" ]]; then
                safe_copy_dir "$files_dir/keyrings" "$HOME/.local/share/keyrings"
                msg_ok "Keyrings restored"
            fi
            ;;
        desktop)
            if [[ -d "$files_dir/desktop-files" ]]; then
                safe_copy_dir "$files_dir/desktop-files" "$HOME/.local/share/applications"
                msg_ok "Desktop files restored"
            fi
            ;;
        user-dirs)
            if [[ -f "$files_dir/single/user-dirs.dirs" ]]; then
                cp -a "$files_dir/single/user-dirs.dirs" "$HOME/.config/user-dirs.dirs"
                msg_ok "XDG user directories restored"
            fi
            if [[ -f "$files_dir/single/user-dirs.locale" ]]; then
                cp -a "$files_dir/single/user-dirs.locale" "$HOME/.config/user-dirs.locale"
            fi
            ;;
    esac
}

# --- FULL RESTORE (CLI mode) ---
do_restore_cli() {
    local bdir="$1"

    if [[ ! -d "$bdir" || ! -f "$bdir/metadata/timestamp.txt" ]]; then
        msg_fail "Invalid backup directory: $bdir"
        return 1
    fi

    echo ""
    msg_step "GNOME configuration restore"
    msg_info "Source: $bdir"
    msg_info "Backup info: $(backup_info "$bdir")"
    echo ""

    # Version check
    local backup_gnome_ver current_gnome_ver
    backup_gnome_ver="$(cat "$bdir/metadata/gnome_version.txt" 2>/dev/null || echo 'unknown')"
    current_gnome_ver="$(gnome-shell --version 2>/dev/null || echo 'unknown')"

    if [[ "$backup_gnome_ver" != "$current_gnome_ver" ]]; then
        msg_warn "GNOME version mismatch!"
        msg_warn "  Backup:  $backup_gnome_ver"
        msg_warn "  Current: $current_gnome_ver"
        echo ""
        read -rp "Continue anyway? (y/N): " confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            msg_info "Restore cancelled"
            return 0
        fi
    fi

    # Username check
    local backup_user current_user
    backup_user="$(cat "$bdir/metadata/username.txt" 2>/dev/null || echo '')"
    current_user="$(whoami)"
    if [[ -n "$backup_user" && "$backup_user" != "$current_user" ]]; then
        msg_warn "Username mismatch: backup='$backup_user', current='$current_user'"
        msg_warn "File paths containing /home/$backup_user/ may not match!"
    fi

    # Pre-restore safety backup
    msg_step "Creating safety backup of current state..."
    local safety_dir
    safety_dir="$(pre_restore_backup)"
    msg_ok "Safety backup: $safety_dir"
    echo ""

    # Restore execution
    msg_step "1/5 — Restoring dconf database..."
    restore_dconf "$bdir" "full"
    echo ""

    msg_step "2/5 — Restoring extensions..."
    restore_extensions "$bdir"
    echo ""

    msg_step "3/5 — Restoring themes, icons, fonts, wallpapers..."
    restore_file_config "$bdir" "themes"
    restore_file_config "$bdir" "fonts"
    restore_file_config "$bdir" "backgrounds"
    echo ""

    msg_step "4/5 — Restoring GTK, autostart, monitors, nautilus, desktop files..."
    restore_file_config "$bdir" "gtk"
    restore_file_config "$bdir" "autostart"
    restore_file_config "$bdir" "monitors"
    restore_file_config "$bdir" "nautilus"
    restore_file_config "$bdir" "mimeapps"
    restore_file_config "$bdir" "desktop"
    restore_file_config "$bdir" "user-dirs"
    echo ""

    msg_step "5/5 — Restoring GNOME Online Accounts, Keyrings..."
    restore_file_config "$bdir" "goa"
    restore_file_config "$bdir" "keyrings"
    echo ""

    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}${BOLD}  RESTORE COMPLETE!${RESET}"
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
    echo -e "  ${BOLD}Source:${RESET}  $bdir"
    echo -e "  ${BOLD}Safety:${RESET} $safety_dir"
    echo -e ""
    echo -e "  ${YELLOW}${BOLD}IMPORTANT:${RESET} To fully apply all changes,"
    echo -e "  ${YELLOW}log out and back in, or restart your computer.${RESET}"
    echo -e "${GREEN}${BOLD}══════════════════════════════════════════════════════${RESET}"
    echo ""

    log "INFO" "=== RESTORE COMPLETED from $bdir ==="
}

# --- Backup selector (TUI) ---
select_backup_tui() {
    local -a backup_list=()
    local -a menu_items=()
    local idx=1

    while IFS= read -r bdir; do
        backup_list+=("$bdir")
        local info
        info="$(backup_info "$bdir")"
        menu_items+=("$idx" "$info")
        idx=$((idx + 1))
    done < <(list_backups)

    if [[ ${#backup_list[@]} -eq 0 ]]; then
        dialog --backtitle "$BACKTITLE" --title "No Backups" \
            --msgbox "No previous backups found.\n\nCreate a backup first!" 8 50
        return 1
    fi

    local choice
    choice=$(dialog --backtitle "$BACKTITLE" --title "Select Backup" \
        --menu "Choose the backup to restore from:" 20 80 10 \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3)

    local exit_code=$?
    if [[ $exit_code -ne 0 || -z "$choice" ]]; then
        return 1
    fi

    local selected_idx=$((choice - 1))
    echo "${backup_list[$selected_idx]}"
}

# --- FULL RESTORE (TUI mode) ---
do_restore_tui() {
    local select_mode="${1:-full}"

    # Select backup
    local bdir
    bdir="$(select_backup_tui)" || return 1

    local info
    info="$(backup_info "$bdir")"

    # Version check
    local backup_gnome_ver current_gnome_ver version_warning=""
    backup_gnome_ver="$(cat "$bdir/metadata/gnome_version.txt" 2>/dev/null || echo 'unknown')"
    current_gnome_ver="$(gnome-shell --version 2>/dev/null || echo 'unknown')"

    if [[ "$backup_gnome_ver" != "$current_gnome_ver" ]]; then
        version_warning="\n\nWARNING: GNOME VERSION MISMATCH!\n  Backup:  $backup_gnome_ver\n  Current: $current_gnome_ver\n  This may cause issues with extensions!"
    fi

    # Confirmation
    dialog --backtitle "$BACKTITLE" --title "Confirm Restore" \
        --yesno "Are you sure you want to restore your GNOME configuration?\n\nBackup: $info$version_warning\n\nA safety backup of your current configuration will be\ncreated automatically before restoring." 18 75

    if [[ $? -ne 0 ]]; then
        return 0
    fi

    # Selective mode
    local -a categories=()
    if [[ "$select_mode" == "selective" ]]; then
        local result
        result=$(dialog --backtitle "$BACKTITLE" --title "Selective Restore" \
            --checklist "Choose items to restore:" 22 70 14 \
            "dconf"       "dconf database (FULL — themes, keybindings, etc.)" ON \
            "extensions"  "GNOME Shell extensions (files + state)" ON \
            "themes"      "Themes and icons" ON \
            "fonts"       "Fonts" ON \
            "backgrounds" "Wallpapers" ON \
            "gtk"         "GTK 3/4 settings" ON \
            "autostart"   "Autostart applications" ON \
            "monitors"    "Monitor configuration" ON \
            "nautilus"    "File manager & scripts" ON \
            "mimeapps"    "Default applications" ON \
            "goa"         "GNOME Online Accounts" OFF \
            "keyrings"    "Keyrings (passwords)" OFF \
            "desktop"     "Desktop files (.desktop)" ON \
            "user-dirs"   "XDG user directories" ON \
            3>&1 1>&2 2>&3)

        local exit_code=$?
        if [[ $exit_code -ne 0 || -z "$result" ]]; then
            return 1
        fi
        # shellcheck disable=SC2206
        categories=($result)
    else
        categories=("dconf" "extensions" "themes" "fonts" "backgrounds" "gtk" "autostart" "monitors" "nautilus" "mimeapps" "goa" "keyrings" "desktop" "user-dirs")
    fi

    # Progress
    local total_steps=$(( ${#categories[@]} + 1 ))
    local current_step=0
    local pct

    {
        # Pre-restore safety backup
        current_step=$((current_step + 1))
        pct=$(( current_step * 100 / total_steps ))
        echo "XXX"
        echo "$pct"
        echo "Creating safety backup of current state..."
        echo "XXX"
        pre_restore_backup >/dev/null 2>&1

        local cat
        for cat in "${categories[@]}"; do
            cat="${cat//\"/}"
            current_step=$((current_step + 1))
            pct=$(( current_step * 100 / total_steps ))

            case "$cat" in
                dconf)
                    echo "XXX"
                    echo "$pct"
                    echo "Restoring dconf database..."
                    echo "XXX"
                    restore_dconf "$bdir" "full" >/dev/null 2>&1
                    ;;
                extensions)
                    echo "XXX"
                    echo "$pct"
                    echo "Restoring extensions..."
                    echo "XXX"
                    restore_extensions "$bdir" >/dev/null 2>&1
                    ;;
                *)
                    echo "XXX"
                    echo "$pct"
                    echo "Restoring $cat..."
                    echo "XXX"
                    restore_file_config "$bdir" "$cat" >/dev/null 2>&1
                    ;;
            esac
        done

        echo "XXX"
        echo "100"
        echo "Restore complete!"
        echo "XXX"
        sleep 0.5

    } | dialog --backtitle "$BACKTITLE" --title "Restoring..." \
              --gauge "Preparing..." 10 60 0

    # Summary
    dialog --backtitle "$BACKTITLE" --title "Restore Complete!" \
        --msgbox "$(cat <<EOF
GNOME configuration restored successfully!

  Source: $(basename "$bdir")
  Items:  ${#categories[@]} categories

  ╔═══════════════════════════════════════════════╗
  ║  IMPORTANT: To fully apply all changes,       ║
  ║  log out and back in, or restart your          ║
  ║  computer!                                     ║
  ╚═══════════════════════════════════════════════╝

A safety backup of your previous state was created.
If anything goes wrong, you can restore from that.
EOF
)" 18 60

    log "INFO" "=== RESTORE (TUI) COMPLETED from $bdir ==="
}

# ==============================================================================
# BACKUP MANAGEMENT
# ==============================================================================

manage_backups_tui() {
    while true; do
        local choice
        choice=$(dialog --backtitle "$BACKTITLE" --title "Manage Backups" \
            --menu "Choose an action:" 14 60 5 \
            "1" "List backups (detailed info)" \
            "2" "Delete backups" \
            "3" "Compare two backups (dconf diff)" \
            "4" "Show backup path (for manual access)" \
            "5" "Back to main menu" \
            3>&1 1>&2 2>&3)

        local exit_code=$?
        if [[ $exit_code -ne 0 || -z "$choice" ]]; then
            return
        fi

        case "$choice" in
            1) manage_list_backups ;;
            2) manage_delete_backup ;;
            3) manage_compare_backups ;;
            4) manage_show_path ;;
            5) return ;;
        esac
    done
}

manage_list_backups() {
    local text=""
    local count=0

    while IFS= read -r bdir; do
        count=$((count + 1))
        local ts gnome_ver host user size files
        ts="$(cat "$bdir/metadata/timestamp.txt" 2>/dev/null || echo '?')"
        gnome_ver="$(cat "$bdir/metadata/gnome_version.txt" 2>/dev/null || echo '?')"
        host="$(cat "$bdir/metadata/hostname.txt" 2>/dev/null || echo '?')"
        user="$(cat "$bdir/metadata/username.txt" 2>/dev/null || echo '?')"
        size="$(dir_size "$bdir")"
        files="$(find "$bdir" -type f 2>/dev/null | wc -l)"

        local dirname
        dirname="$(basename "$bdir")"
        local tag=""
        if [[ "$dirname" == pre-restore-* ]]; then
            tag=" [AUTO — pre-restore safety backup]"
        fi

        text+="────────────────────────────────────────\n"
        text+="  #$count$tag\n"
        text+="  Folder:    $dirname\n"
        text+="  Date:      $ts\n"
        text+="  GNOME:     $gnome_ver\n"
        text+="  Host:      $host ($user)\n"
        text+="  Size:      $size ($files files)\n"

        if [[ -f "$bdir/metadata/extensions_enabled.txt" ]]; then
            local ext_count
            ext_count="$(wc -l < "$bdir/metadata/extensions_enabled.txt")"
            text+="  Ext (ON):  $ext_count\n"
        fi
        text+="\n"
    done < <(list_backups)

    if [[ $count -eq 0 ]]; then
        dialog --backtitle "$BACKTITLE" --title "Backups" \
            --msgbox "No backups found.\n\nBackup location: $BACKUP_BASE_DIR" 8 55
        return
    fi

    text+="────────────────────────────────────────\n"
    text+="Total: $count backups\n"
    text+="Disk usage: $(dir_size "$BACKUP_BASE_DIR")\n"

    echo -e "$text" | dialog --backtitle "$BACKTITLE" --title "Backup List ($count)" \
        --programbox 24 60
}

manage_delete_backup() {
    local -a backup_list=()
    local -a checklist_items=()
    local idx=1

    while IFS= read -r bdir; do
        backup_list+=("$bdir")
        local dirname
        dirname="$(basename "$bdir")"
        local size
        size="$(dir_size "$bdir")"
        checklist_items+=("$idx" "$dirname | $size" "off")
        idx=$((idx + 1))
    done < <(list_backups)

    if [[ ${#backup_list[@]} -eq 0 ]]; then
        dialog --backtitle "$BACKTITLE" --title "Delete" \
            --msgbox "No backups found." 6 40
        return
    fi

    local selected
    selected=$(dialog --backtitle "$BACKTITLE" --title "Delete Backups" \
        --checklist "Select backups to delete:" 20 70 12 \
        "${checklist_items[@]}" \
        3>&1 1>&2 2>&3)

    local exit_code=$?
    if [[ $exit_code -ne 0 || -z "$selected" ]]; then
        return
    fi

    dialog --backtitle "$BACKTITLE" --title "Confirm Deletion" \
        --yesno "Are you sure you want to delete the selected backups?\n\nThis action CANNOT be undone!" 9 55

    if [[ $? -ne 0 ]]; then
        return
    fi

    local idx_str
    for idx_str in $selected; do
        idx_str="${idx_str//\"/}"
        local del_idx=$((idx_str - 1))
        local del_dir="${backup_list[$del_idx]}"
        rm -rf "$del_dir"
        log "INFO" "Backup deleted: $del_dir"
    done

    dialog --backtitle "$BACKTITLE" --title "Deleted" \
        --msgbox "Selected backups have been deleted." 6 45
}

manage_compare_backups() {
    local -a backup_list=()
    local -a menu_items=()
    local idx=1

    while IFS= read -r bdir; do
        backup_list+=("$bdir")
        local info
        info="$(backup_info "$bdir")"
        menu_items+=("$idx" "$info")
        idx=$((idx + 1))
    done < <(list_backups)

    if [[ ${#backup_list[@]} -lt 2 ]]; then
        dialog --backtitle "$BACKTITLE" --title "Compare" \
            --msgbox "At least 2 backups are needed for comparison." 7 55
        return
    fi

    local choice1 choice2
    choice1=$(dialog --backtitle "$BACKTITLE" --title "Compare — First Backup" \
        --menu "Select the FIRST backup:" 18 80 10 \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3)
    [[ $? -ne 0 || -z "$choice1" ]] && return

    choice2=$(dialog --backtitle "$BACKTITLE" --title "Compare — Second Backup" \
        --menu "Select the SECOND backup:" 18 80 10 \
        "${menu_items[@]}" \
        3>&1 1>&2 2>&3)
    [[ $? -ne 0 || -z "$choice2" ]] && return

    local dir1="${backup_list[$((choice1 - 1))]}"
    local dir2="${backup_list[$((choice2 - 1))]}"

    local dump1="$dir1/dconf/full_dump.ini"
    local dump2="$dir2/dconf/full_dump.ini"

    if [[ ! -f "$dump1" || ! -f "$dump2" ]]; then
        dialog --backtitle "$BACKTITLE" --title "Error" \
            --msgbox "One of the selected backups is missing its dconf dump." 7 55
        return
    fi

    local diff_output
    diff_output=$(diff --unified=3 "$dump1" "$dump2" 2>&1 || true)

    if [[ -z "$diff_output" ]]; then
        dialog --backtitle "$BACKTITLE" --title "Result" \
            --msgbox "The two backups have IDENTICAL dconf dumps!" 7 50
    else
        echo "$diff_output" | dialog --backtitle "$BACKTITLE" \
            --title "dconf diff: $(basename "$dir1") vs $(basename "$dir2")" \
            --programbox 24 80
    fi
}

manage_show_path() {
    local bdir
    bdir="$(select_backup_tui)" || return

    dialog --backtitle "$BACKTITLE" --title "Backup Path" \
        --msgbox "Backup directory:\n\n$bdir\n\nSelect the path with your mouse to copy it." 10 70
}

# ==============================================================================
# CLI — LIST BACKUPS
# ==============================================================================

do_list_cli() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║  GNOME Config Exporter — Previous Backups           ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""

    local count=0
    while IFS= read -r bdir; do
        count=$((count + 1))
        local dirname
        dirname="$(basename "$bdir")"
        local tag=""
        if [[ "$dirname" == pre-restore-* ]]; then
            tag="${YELLOW} [AUTO]${RESET}"
        fi

        echo -e "  ${BOLD}#$count${RESET}$tag"
        echo -e "    Path:  ${CYAN}$bdir${RESET}"
        echo -e "    Info:  $(backup_info "$bdir")"

        if [[ -f "$bdir/metadata/extensions_enabled.txt" ]]; then
            local ext_count
            ext_count="$(wc -l < "$bdir/metadata/extensions_enabled.txt")"
            echo -e "    Ext:   $ext_count enabled"
        fi
        echo ""
    done < <(list_backups)

    if [[ $count -eq 0 ]]; then
        msg_info "No backups found."
        msg_info "Backup location: $BACKUP_BASE_DIR"
    else
        echo -e "  ${DIM}Total: $count backups | Disk usage: $(dir_size "$BACKUP_BASE_DIR")${RESET}"
        echo ""
    fi
}

# ==============================================================================
# TUI MAIN MENU
# ==============================================================================

tui_main_menu() {
    if ! command -v dialog &>/dev/null; then
        msg_fail "'dialog' is not installed. Install with your package manager."
        msg_info "CLI mode is available: $SCRIPT_NAME --backup / --restore / --list"
        exit 1
    fi

    TUI_MODE=true

    local backup_count=0
    if [[ -d "$BACKUP_BASE_DIR" ]]; then
        backup_count=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    fi

    while true; do
        local choice
        choice=$(dialog --backtitle "$BACKTITLE" --title "$DIALOG_TITLE" \
            --cancel-label "Exit" \
            --menu "Welcome! Choose an action:\n\nBackups: $backup_count | Location: $BACKUP_BASE_DIR" 20 70 8 \
            "1" "Full Backup — Save all GNOME settings" \
            "2" "Selective Backup — Choose what to save" \
            "3" "Full Restore — Restore from a backup" \
            "4" "Selective Restore — Restore specific items" \
            "5" "Manage Backups — List, delete, compare" \
            "6" "System Info — GNOME version, extensions, etc." \
            "7" "Exit" \
            3>&1 1>&2 2>&3)

        local exit_code=$?
        if [[ $exit_code -ne 0 || "$choice" == "7" ]]; then
            clear
            echo "Goodbye!"
            exit 0
        fi

        case "$choice" in
            1) do_backup_tui "full" ;;
            2) do_backup_tui "selective" ;;
            3) do_restore_tui "full" ;;
            4) do_restore_tui "selective" ;;
            5) manage_backups_tui ;;
            6) show_system_info_tui ;;
        esac

        # Refresh backup count
        if [[ -d "$BACKUP_BASE_DIR" ]]; then
            backup_count=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        fi
    done
}

# ==============================================================================
# SYSTEM INFO (TUI)
# ==============================================================================

show_system_info_tui() {
    local info=""

    info+="GNOME Shell version:\n"
    info+="  $(gnome-shell --version 2>/dev/null || echo 'Not available')\n\n"

    info+="Session type:\n"
    info+="  ${XDG_SESSION_TYPE:-Unknown}\n\n"

    info+="Desktop environment:\n"
    info+="  ${XDG_CURRENT_DESKTOP:-Unknown}\n\n"

    info+="Display server:\n"
    info+="  ${WAYLAND_DISPLAY:+Wayland ($WAYLAND_DISPLAY)}${WAYLAND_DISPLAY:-${DISPLAY:+X11 ($DISPLAY)}}${WAYLAND_DISPLAY:-${DISPLAY:-Unknown}}\n\n"

    info+="Package manager:\n"
    info+="  $(detect_pkg_manager)\n\n"

    info+="GTK theme:\n"
    info+="  $(gsettings get org.gnome.desktop.interface gtk-theme 2>/dev/null || echo '?')\n\n"

    info+="Icon theme:\n"
    info+="  $(gsettings get org.gnome.desktop.interface icon-theme 2>/dev/null || echo '?')\n\n"

    info+="Font:\n"
    info+="  $(gsettings get org.gnome.desktop.interface font-name 2>/dev/null || echo '?')\n\n"

    info+="Color scheme:\n"
    info+="  $(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null || echo '?')\n\n"

    if command -v gnome-extensions &>/dev/null; then
        local enabled_count total_count
        enabled_count=$(gnome-extensions list --enabled 2>/dev/null | wc -l)
        total_count=$(gnome-extensions list 2>/dev/null | wc -l)
        info+="Extensions:\n"
        info+="  $enabled_count enabled / $total_count installed\n\n"

        info+="Enabled extensions:\n"
        while IFS= read -r ext; do
            info+="  + $ext\n"
        done < <(gnome-extensions list --enabled 2>/dev/null)
        info+="\n"
    fi

    info+="Favorites (Dash/Dock):\n"
    info+="  $(gsettings get org.gnome.shell favorite-apps 2>/dev/null || echo '?')\n\n"

    info+="Keyboard layout:\n"
    info+="  $(gsettings get org.gnome.desktop.input-sources sources 2>/dev/null || echo '?')\n\n"

    info+="dconf database size:\n"
    if [[ -f "$HOME/.config/dconf/user" ]]; then
        info+="  $(du -sh "$HOME/.config/dconf/user" | cut -f1)\n"
    else
        info+="  Not found\n"
    fi
    info+="\n"

    info+="Backup location:\n"
    info+="  $BACKUP_BASE_DIR\n"
    if [[ -d "$BACKUP_BASE_DIR" ]]; then
        local bc
        bc=$(find "$BACKUP_BASE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        info+="  $bc backups, total: $(dir_size "$BACKUP_BASE_DIR")\n"
    fi

    echo -e "$info" | dialog --backtitle "$BACKTITLE" --title "System Information" \
        --programbox 30 70
}

# ==============================================================================
# HELP
# ==============================================================================

show_help() {
    cat <<EOF
${BOLD}GNOME Configuration Exporter v${VERSION}${RESET}
Full GNOME desktop configuration backup & restore tool.

${BOLD}Usage:${RESET}
  $SCRIPT_NAME                   Interactive TUI mode (dialog)
  $SCRIPT_NAME --backup          Full backup (CLI)
  $SCRIPT_NAME --restore <dir>   Restore from backup (CLI)
  $SCRIPT_NAME --list            List previous backups
  $SCRIPT_NAME --help            Show this help
  $SCRIPT_NAME --version         Show version

${BOLD}TUI Mode:${RESET}
  Interactive terminal UI powered by 'dialog' (ncurses).
  Full/selective backup & restore, progress bars,
  backup management (list, delete, compare).

${BOLD}What gets backed up:${RESET}
  * dconf database (full + selective section dumps)
  * GNOME Shell extensions (files + enabled state + settings)
  * Keybindings (WM, Shell, custom shortcuts)
  * Themes, icons, fonts, wallpapers
  * GTK 3/4 settings (settings.ini, gtk.css, bookmarks)
  * Autostart applications
  * Terminal profiles
  * Monitor configuration (monitors.xml)
  * Nautilus settings & scripts
  * Default applications (mimeapps.list)
  * GNOME Online Accounts
  * Keyrings (passwords, tokens)
  * Desktop files (.desktop)
  * XDG user directories

${BOLD}Backup location:${RESET}
  $BACKUP_BASE_DIR
  (override with GNOME_CFG_EXPORTER_DIR environment variable)

${BOLD}Safety features:${RESET}
  * Automatic safety backup before every restore
  * Selective backup/restore (choose specific categories)
  * GNOME version mismatch warning on restore
  * Username mismatch detection
  * Log file: $LOG_FILE

${BOLD}Supported distributions:${RESET}
  Arch Linux, Fedora, Ubuntu/Debian, openSUSE, Alpine,
  Void Linux, Gentoo, NixOS, and any Linux with GNOME + dconf.

${BOLD}Dependencies:${RESET}
  * dconf, gsettings, rsync (required — auto-install prompt)
  * dialog (optional, for TUI — auto-install prompt)
  * gnome-extensions (optional, for extension listing)

${BOLD}Environment variables:${RESET}
  GNOME_CFG_EXPORTER_DIR   Base directory for backups
                           (default: ~/.local/share/gnome-cfg-exporter)

${BOLD}Examples:${RESET}
  $SCRIPT_NAME                          # Launch TUI
  $SCRIPT_NAME --backup                 # Quick full backup
  $SCRIPT_NAME --restore ~/.local/share/gnome-cfg-exporter/20260303_143000
  $SCRIPT_NAME --list                   # List all backups

EOF
}

# ==============================================================================
# MAIN — Argument parsing
# ==============================================================================

main() {
    # Create base directory
    mkdir -p "$BACKUP_BASE_DIR"

    case "${1:-}" in
        --backup|-b)
            check_dependencies || exit 1
            do_backup_cli
            ;;
        --restore|-r)
            check_dependencies || exit 1
            if [[ -z "${2:-}" ]]; then
                msg_fail "Usage: $SCRIPT_NAME --restore <backup_directory>"
                msg_info "Available backups:"
                do_list_cli
                exit 1
            fi
            do_restore_cli "$2"
            ;;
        --list|-l)
            do_list_cli
            ;;
        --help|-h)
            show_help
            ;;
        --version|-v)
            echo "GNOME Config Exporter v${VERSION}"
            ;;
        "")
            check_dependencies || exit 1
            tui_main_menu
            ;;
        *)
            msg_fail "Unknown argument: $1"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
