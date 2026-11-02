#!/bin/bash
# Builds screenshot-to-clipboard and installs it as a LaunchAgent that runs at login.
#
#   ./install.sh                   build, install and start it
#   ./install.sh --keep-thumbnail  same, but leave the floating screenshot thumbnail alone
#   ./install.sh --uninstall       stop and remove it, and restore the thumbnail setting
set -euo pipefail

LABEL="com.macsetup.screenshot-to-clipboard"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$HERE/screenshot-to-clipboard.swift"
BIN="$HOME/.local/bin/screenshot-to-clipboard"
STAGED_BIN="$BIN.new"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/screenshot-to-clipboard.log"
STATE_DIR="$HOME/Library/Application Support/screenshot-to-clipboard"
THUMBNAIL_BACKUP="$STATE_DIR/show-thumbnail"
DOMAIN="gui/$(id -u)"

usage() {
    cat <<'EOF'
Usage: install.sh [--keep-thumbnail | --uninstall]

  --keep-thumbnail  don't turn off the floating screenshot thumbnail (screenshots are then
                    copied a few seconds after they are taken instead of right away)
  --uninstall       stop and remove screenshot-to-clipboard and restore the thumbnail setting
EOF
}

xml_escape() {
    local text="$1"
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    printf '%s' "$text"
}

write_plist() {
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(xml_escape "$BIN")</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>$(xml_escape "$LOG")</string>
    <key>StandardErrorPath</key>
    <string>$(xml_escape "$LOG")</string>
</dict>
</plist>
EOF
    plutil -lint "$PLIST" >/dev/null
}

build_binary() {
    if ! command -v swiftc >/dev/null 2>&1; then
        echo "swiftc not found. Install the Xcode command line tools with: xcode-select --install" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$BIN")"
    swiftc -O -swift-version 5 "$SOURCE" -o "$STAGED_BIN"
    codesign --force --sign - --identifier "$LABEL" "$STAGED_BIN" >/dev/null 2>&1 || true
}

stop_agent() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
}

start_agent() {
    launchctl enable "$DOMAIN/$LABEL" 2>/dev/null || true
    # Right after bootout, launchd can still be tearing the old instance down.
    local attempt
    for attempt in 1 2 3 4 5; do
        if launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then return 0; fi
        sleep 1
    done
    launchctl bootstrap "$DOMAIN" "$PLIST"
}

agent_is_running() {
    local attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q 'state = running'; then return 0; fi
        sleep 0.5
    done
    return 1
}

# While the floating thumbnail is shown, macOS only saves the screenshot once it goes away.
disable_thumbnail() {
    mkdir -p "$STATE_DIR"
    if [ ! -f "$THUMBNAIL_BACKUP" ]; then
        (defaults read com.apple.screencapture show-thumbnail 2>/dev/null || echo unset) > "$THUMBNAIL_BACKUP"
    fi
    defaults write com.apple.screencapture show-thumbnail -bool false
}

restore_thumbnail() {
    [ -f "$THUMBNAIL_BACKUP" ] || return 0
    case "$(cat "$THUMBNAIL_BACKUP")" in
        unset) defaults delete com.apple.screencapture show-thumbnail 2>/dev/null || true ;;
        0) defaults write com.apple.screencapture show-thumbnail -bool false ;;
        *) defaults write com.apple.screencapture show-thumbnail -bool true ;;
    esac
    rm -f "$THUMBNAIL_BACKUP"
    rmdir "$STATE_DIR" 2>/dev/null || true
}

install() {
    local keep_thumbnail="$1"
    trap 'rm -f "$STAGED_BIN"' EXIT

    echo "Building"
    build_binary
    stop_agent
    mv "$STAGED_BIN" "$BIN"
    write_plist

    if [ "$keep_thumbnail" = 1 ]; then
        restore_thumbnail
    else
        disable_thumbnail
    fi

    echo "Starting"
    start_agent
    if ! agent_is_running; then
        echo "The agent did not start. Log:" >&2
        tail -n 20 "$LOG" >&2 2>/dev/null || true
        exit 1
    fi

    echo
    echo "Installed. Take a screenshot with ⌘⇧4, then paste with ⌘V."
    if [ "$keep_thumbnail" = 1 ]; then
        echo "The floating thumbnail is still on, so a screenshot is copied a few seconds after you take it."
    else
        echo "The floating screenshot thumbnail is now off, so screenshots are saved and copied right away."
    fi
    echo
    echo "macOS may show a 'Background Items Added' notification and ask whether screenshot-to-clipboard"
    echo "can access your Desktop folder. Allow both, otherwise it can't see new screenshots."
    echo "Log: $LOG"
}

uninstall() {
    stop_agent
    rm -f "$PLIST" "$BIN" "$STAGED_BIN" "$LOG"
    restore_thumbnail
    echo "Removed screenshot-to-clipboard."
}

main() {
    local keep_thumbnail=0 action=install
    while [ $# -gt 0 ]; do
        case "$1" in
            --keep-thumbnail) keep_thumbnail=1 ;;
            --uninstall) action=uninstall ;;
            -h|--help) usage; exit 0 ;;
            *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
        shift
    done

    if [ "$(uname)" != Darwin ]; then
        echo "screenshot-to-clipboard only works on macOS." >&2
        exit 1
    fi
    if [ "$(id -u)" -eq 0 ]; then
        echo "Run this as your normal user, not as root." >&2
        exit 1
    fi

    if [ "$action" = uninstall ]; then
        uninstall
    else
        install "$keep_thumbnail"
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
