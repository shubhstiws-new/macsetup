#!/bin/bash
# End-to-end test: builds the daemon, points it at a scratch folder (--dir) and checks what lands
# on the clipboard. It never touches your real screenshot folder or settings.
# The clipboard is overwritten while this runs; its text is restored afterwards.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/screenshot-to-clipboard-test.XXXXXX")"
BIN="$WORK/screenshot-to-clipboard"
SHOTS="$WORK/shots"        # watched by the daemon
STAGING="$WORK/staging"    # files are prepared here and moved into SHOTS, the way macOS delivers them
LOG="$WORK/daemon.log"
SENTINEL="screenshot-to-clipboard-test-sentinel"
SAVED_CLIPBOARD="$(pbpaste | base64)"
NNBSP="$(printf '\xe2\x80\xaf')"  # macOS puts U+202F before AM/PM in screenshot names

# A 2x2 PNG that is resized with sips to make the test images.
BASE_PNG_B64='iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR42mPQa7v3H4QZYAwAVuAKReHD0WwAAAAASUVORK5CYII='
# Binary plist holding the boolean "true", which is what macOS stores in kMDItemIsScreenCapture.
SCREEN_CAPTURE_HEX='62 70 6C 69 73 74 30 30 09 08 00 00 00 00 00 00 01 01 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 09'

daemon_pid=""
passed=0
failed=0

cleanup() {
    if [ -n "$daemon_pid" ]; then
        kill "$daemon_pid" 2>/dev/null || true
        wait "$daemon_pid" 2>/dev/null || true
    fi
    printf '%s' "$SAVED_CLIPBOARD" | base64 -D | pbcopy
    rm -rf "$WORK"
}
trap cleanup EXIT

check() {
    local description="$1"
    shift
    if "$@"; then
        echo "  ok    $description"
        passed=$((passed + 1))
    else
        echo "  FAIL  $description"
        failed=$((failed + 1))
    fi
}

wait_for() {
    local deadline=$((SECONDS + $1))
    shift
    while [ "$SECONDS" -le "$deadline" ]; do
        if "$@"; then return 0; fi
        sleep 0.1
    done
    return 1
}

reset_clipboard() { printf '%s' "$SENTINEL" | pbcopy; }
clipboard_untouched() { [ "$(pbpaste)" = "$SENTINEL" ]; }
clipboard_has_tiff() { osascript -e 'clipboard info' | grep -q TIFF; }

save_clipboard_png() {
    rm -f "$WORK/clipboard.png"
    osascript - "$WORK/clipboard.png" >/dev/null 2>&1 <<'EOF' || true
on run argv
    set pngData to the clipboard as «class PNGf»
    set fileRef to open for access POSIX file (item 1 of argv) with write permission
    try
        set eof fileRef to 0
        write pngData to fileRef
    end try
    close access fileRef
end run
EOF
    [ -s "$WORK/clipboard.png" ]
}

clipboard_is_file() { save_clipboard_png && cmp -s "$WORK/clipboard.png" "$1"; }
clipboard_is_png_of_size() { save_clipboard_png && file "$WORK/clipboard.png" | grep -q "PNG image data, $1 x $2,"; }

copied() { grep -qF "Copied $1 to the clipboard" "$LOG"; }
did_not_copy() { ! copied "$1"; }

# stage NAME WIDTH HEIGHT [mark]: creates an image in the staging folder, flagged as a screenshot when "mark" is given.
stage() {
    local format=png
    case "$1" in *.jpg) format=jpeg ;; esac
    sips -s format "$format" -z "$3" "$2" "$WORK/base.png" --out "$STAGING/$1" >/dev/null
    if [ "${4:-}" = mark ]; then
        xattr -wx com.apple.metadata:kMDItemIsScreenCapture "$SCREEN_CAPTURE_HEX" "$STAGING/$1"
    fi
}

deliver() { mv "$STAGING/$1" "$SHOTS/$1"; }

echo "Building"
mkdir -p "$SHOTS" "$STAGING"
swiftc -O -swift-version 5 "$HERE/screenshot-to-clipboard.swift" -o "$BIN"
printf '%s' "$BASE_PNG_B64" | base64 -D > "$WORK/base.png"

"$BIN" --dir "$SHOTS" >"$LOG" 2>&1 &
daemon_pid=$!
if ! wait_for 10 grep -q "Watching" "$LOG"; then
    echo "The daemon did not start:"
    cat "$LOG"
    exit 1
fi
sleep 0.5

echo "Screenshots that should be copied"

name="Screenshot 2026-10-05 at 8.15.39${NNBSP}PM.png"
reset_clipboard
stage "$name" 120 80 mark
deliver "$name"
check "a ⌘⇧4 style screenshot is copied byte for byte" wait_for 5 clipboard_is_file "$SHOTS/$name"
check "it is on the clipboard as PNG and TIFF, like ⌘⌃⇧4" clipboard_has_tiff
check "the saved file is left in place" test -f "$SHOTS/$name"

name="Bildschirmfoto 2026-10-05 um 20.15.39.png"
reset_clipboard
stage "$name" 130 90 mark
deliver "$name"
check "a custom or localized name is recognized by the macOS marker" wait_for 5 clipboard_is_file "$SHOTS/$name"

name="Screen Shot 2019-01-01 at 1.00.00 PM.png"
reset_clipboard
stage "$name" 140 95
deliver "$name"
check "a screenshot name is recognized without the marker" wait_for 5 clipboard_is_file "$SHOTS/$name"

name="Screenshot as jpeg.jpg"
reset_clipboard
stage "$name" 90 60 mark
deliver "$name"
check "a JPEG screenshot is put on the clipboard as a PNG" wait_for 5 clipboard_is_png_of_size 90 60

name="late-marker.png"
reset_clipboard
stage "$name" 150 100
deliver "$name"
sleep 0.6
xattr -wx com.apple.metadata:kMDItemIsScreenCapture "$SCREEN_CAPTURE_HEX" "$SHOTS/$name"
check "a marker that arrives after the file is still picked up" wait_for 5 clipboard_is_file "$SHOTS/$name"

name="Screenshot partial.png"
reset_clipboard
sips -s format png -z 400 600 "$WORK/base.png" --out "$WORK/partial-source.png" >/dev/null
size="$(stat -f %z "$WORK/partial-source.png")"
chunk=$((size / 4 + 1))
: > "$SHOTS/$name"
for part in 0 1 2 3; do
    dd if="$WORK/partial-source.png" bs=1 skip=$((part * chunk)) count="$chunk" 2>/dev/null >> "$SHOTS/$name"
    sleep 0.1
done
check "a file that is still being written is only copied once complete" wait_for 5 clipboard_is_file "$WORK/partial-source.png"

# Every frame is a complete, decodable PNG, so only waiting for the file to stop changing gets the last one.
# The gap is longer than the daemon's debounce but shorter than its stability re-check.
name="Screenshot rewritten.png"
reset_clipboard
for frame in 1 2 3 4 5 6; do
    sips -s format png -z $((50 + frame * 10)) 100 "$WORK/base.png" --out "$WORK/frame$frame.png" >/dev/null
done
for frame in 1 2 3 4 5 6; do
    cp "$WORK/frame$frame.png" "$SHOTS/$name"
    sleep 0.15
done
check "a file that keeps being rewritten is copied once it settles" wait_for 5 clipboard_is_file "$WORK/frame6.png"

echo "Files that should be ignored"

reset_clipboard
stage "vacation.png" 70 70
stage "Screenshot old.png" 71 71 mark
touch -t 202001010000 "$STAGING/Screenshot old.png"
stage ".Screenshot hidden.png" 72 72 mark
deliver "vacation.png"
deliver "Screenshot old.png"
deliver ".Screenshot hidden.png"
printf 'not an image' > "$SHOTS/Screenshot notes.txt"
printf 'not a movie' > "$SHOTS/Screenshot recording.mov"
sleep 4
check "an image that is not a screenshot" did_not_copy "vacation.png"
check "a screenshot from long ago" did_not_copy "Screenshot old.png"
check "a hidden file" did_not_copy ".Screenshot hidden.png"
check "a text file" did_not_copy "Screenshot notes.txt"
check "a screen recording" did_not_copy "Screenshot recording.mov"
check "the clipboard was left alone" clipboard_untouched

echo "Screenshots that were already copied"

name="Screenshot repeat.png"
reset_clipboard
stage "$name" 160 110 mark
deliver "$name"
check "the first copy happens" wait_for 5 clipboard_is_file "$SHOTS/$name"

reset_clipboard
touch "$SHOTS/$name"
xattr -wx com.apple.metadata:kMDItemIsScreenCapture "$SCREEN_CAPTURE_HEX" "$SHOTS/$name"
mv "$SHOTS/$name" "$SHOTS/Screenshot repeat renamed.png"
sleep 2
check "touching, re-marking or renaming it does not copy it again" clipboard_untouched

stage "$name" 170 120 mark
deliver "$name"
check "a new screenshot that reuses the name is copied" wait_for 5 clipboard_is_file "$SHOTS/$name"

echo "Shutdown"

kill -TERM "$daemon_pid"
status=0
wait "$daemon_pid" || status=$?
daemon_pid=""
check "the daemon exits cleanly on SIGTERM" test "$status" -eq 0

echo
echo "$passed passed, $failed failed"
if [ "$failed" -ne 0 ]; then
    echo "--- daemon log ---"
    cat "$LOG"
    exit 1
fi
