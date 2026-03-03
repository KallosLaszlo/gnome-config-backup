# GNOME Config Exporter

**Full GNOME desktop configuration backup & restore tool** — a single Bash script that saves _everything_ about your GNOME setup so you can restore it after a clean install, distro-hop, or broken update.

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![Shell: Bash](https://img.shields.io/badge/shell-bash-green.svg)
![Platform: Linux](https://img.shields.io/badge/platform-linux-lightgrey.svg)

---

## Why?

Ever had a bad system update wipe out your carefully tuned GNOME setup? Extensions disabled, keybindings gone, theme settings reverted? This tool makes sure that never happens again.

One command to back up **every** aspect of your GNOME configuration. One command (or an interactive menu) to restore it all.

## What Gets Backed Up

| Category | Details |
|---|---|
| **dconf database** | Full dump + 12 selective section dumps + binary DB copy |
| **Extensions** | Extension files + enabled/disabled state + per-extension settings |
| **Keybindings** | Window manager, Shell, media keys, custom shortcuts |
| **Themes & Icons** | `~/.themes`, `~/.icons`, `~/.local/share/themes`, `~/.local/share/icons` |
| **Fonts** | `~/.fonts`, `~/.local/share/fonts` |
| **Wallpapers** | `~/.local/share/backgrounds` |
| **GTK 3/4** | `settings.ini`, `gtk.css`, bookmarks |
| **Autostart** | `~/.config/autostart` entries |
| **Terminal** | All GNOME Terminal / Console profiles (via dconf) |
| **Monitors** | `monitors.xml` (multi-monitor layout, scaling, refresh rate) |
| **Nautilus** | File manager settings & custom scripts |
| **Default apps** | `mimeapps.list` |
| **Online Accounts** | GNOME Online Accounts (GOA) configuration |
| **Keyrings** | GNOME Keyring files (WiFi passwords, tokens, etc.) |
| **Desktop files** | Custom `.desktop` launchers |
| **Metadata** | GNOME version, hostname, username, installed GNOME packages, extension lists |

## Installation

No installation needed. It's a single script.

```bash
git clone https://github.com/KallosLaszlo/gnome-config-backup.git
cd gnome-config-backup
chmod +x gnome-cfg-exporter.sh
```

### Dependencies

| Dependency | Required | Purpose |
|---|---|---|
| `dconf` | **Yes** | Read/write GNOME settings database |
| `gsettings` | **Yes** | Query GNOME settings schemas |
| `rsync` | **Yes** | Efficient file copying |
| `dialog` | No (for TUI) | Interactive ncurses terminal UI |
| `gnome-extensions` | No | Extension listing and metadata |

**Missing dependencies are detected automatically** — the script will offer to install them using your distribution's package manager.

## Usage

### Interactive TUI (recommended)

```bash
./gnome-cfg-exporter.sh
```

Launches a full ncurses terminal UI with menus for:
- Full / selective backup
- Full / selective restore (with progress bar)
- Backup management (list, delete, compare, show path)
- System info (GNOME version, theme, extensions, etc.)

### CLI Mode

```bash
# Full backup
./gnome-cfg-exporter.sh --backup

# Restore from a specific backup
./gnome-cfg-exporter.sh --restore ~/.local/share/gnome-cfg-exporter/20250303_143000

# List all backups
./gnome-cfg-exporter.sh --list

# Show help
./gnome-cfg-exporter.sh --help
```

## Supported Distributions

The script automatically detects your package manager and maps package names accordingly:

| Distribution | Package Manager |
|---|---|
| Arch Linux / Manjaro | `pacman` |
| Fedora / RHEL / CentOS | `dnf` |
| Ubuntu / Debian / Mint | `apt` |
| openSUSE | `zypper` |
| Alpine Linux | `apk` |
| Void Linux | `xbps` |
| Gentoo | `portage` |
| NixOS | `nix` |

Any Linux distribution running GNOME with `dconf` should work.

## Backup Location

Default: `~/.local/share/gnome-cfg-exporter/`

Override with environment variable:
```bash
export GNOME_CFG_EXPORTER_DIR="/path/to/my/backups"
./gnome-cfg-exporter.sh --backup
```

Each backup is stored in a timestamped directory:
```
~/.local/share/gnome-cfg-exporter/
├── 20250303_143000/
│   ├── metadata/
│   │   ├── timestamp.txt
│   │   ├── gnome_version.txt
│   │   ├── hostname.txt
│   │   ├── extensions_enabled.txt
│   │   └── ...
│   ├── dconf/
│   │   ├── full_dump.ini
│   │   ├── gnome_desktop.ini
│   │   ├── gnome_shell.ini
│   │   ├── dconf_user.bak
│   │   └── ...
│   ├── extensions/
│   │   └── (all extension directories)
│   └── files/
│       ├── themes_local/
│       ├── icons_local/
│       ├── keyrings/
│       ├── single/
│       │   ├── monitors.xml
│       │   └── mimeapps.list
│       └── ...
└── 20250310_090000/
    └── ...
```

## Safety Features

- **Automatic pre-restore backup** — Before any restore, a safety snapshot of your current config is created automatically
- **GNOME version mismatch warning** — Warns if the backup was made on a different GNOME version
- **Username mismatch detection** — Warns if restoring as a different user
- **Selective backup/restore** — Choose exactly which categories to back up or restore
- **Backup comparison** — Diff two backups to see what changed
- **Logging** — All actions logged to `~/.local/share/gnome-cfg-exporter/exporter.log`

## FAQ

**Q: Will this work on Wayland and X11?**
A: Yes. The script works on both session types.

**Q: Is it safe to restore on a different GNOME version?**
A: Usually yes, but some settings may not apply. The script will warn you about version mismatches. A safety backup is always created before restoring.

**Q: Can I transfer my config to a different machine?**
A: Yes! Copy the backup directory to the target machine and run `--restore`. Note that paths containing your username in dconf values (e.g., wallpaper paths) may need manual adjustment.

**Q: How big are the backups?**
A: Depends on your themes, icons, and fonts. A typical backup is 100MB–3GB. The dconf database itself is usually just a few hundred KB.

## License

[MIT](LICENSE) — do whatever you want with it.

## Contributing

Issues and pull requests are welcome. If you find a GNOME configuration source that isn't backed up, please open an issue.
