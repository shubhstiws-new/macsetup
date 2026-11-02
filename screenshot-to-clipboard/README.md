# screenshot-to-clipboard

Press ⌘⇧4 as usual and the screenshot is also on your clipboard, ready to paste with ⌘V. The screenshot file is still saved exactly as before.

It also covers ⌘⇧3, ⌘⇧5 and window captures: anything macOS saves as a screenshot gets copied.

## Install

```sh
./screenshot-to-clipboard/install.sh
```

This builds a small Swift program (it needs Xcode or the command line tools: `xcode-select --install`), puts it in `~/.local/bin` and starts it as a LaunchAgent, so it runs at every login and restarts if it crashes.

The first time, macOS may:

- show a **Background Items Added** notification. Leave it allowed (System Settings → General → Login Items & Extensions).
- ask whether it can access your **Desktop** folder. Choose Allow, otherwise it can't see new screenshots.

Then take a screenshot with ⌘⇧4 and paste it with ⌘V.

To uninstall:

```sh
./screenshot-to-clipboard/install.sh --uninstall
```

## The floating thumbnail

While the thumbnail in the corner of the screen is showing, macOS doesn't write the screenshot file until it goes away: about 5 seconds, or longer if you click it. Because this tool reacts to the saved file, the clipboard would update that late too.

So the installer turns the thumbnail off (`defaults write com.apple.screencapture show-thumbnail -bool false`), which makes screenshots land on the clipboard about a third of a second after they are saved. It remembers your previous setting and `--uninstall` restores it.

To keep the thumbnail, install with `./screenshot-to-clipboard/install.sh --keep-thumbnail` and expect the clipboard to update a few seconds after each screenshot.

## How it works

- It watches the folder macOS saves screenshots to: the Desktop, or whatever you set as the location in the Screenshot app. It follows the setting when you change it.
- When a new screenshot appears it puts the image on the clipboard as PNG and TIFF, the same formats ⌘⌃⇧4 uses. Other image types are converted to PNG.
- A file counts as a screenshot if macOS marked it as one, or its name starts with "Screenshot" or "Screen Shot", or with your custom screenshot name.
- Only files created in the last minute are copied, so renaming or touching an old screenshot doesn't put it back on the clipboard.
- A file is copied once it has stopped changing, so a screenshot that is still being written is never copied half-done.
- Screen recordings and other files are ignored.

## Troubleshooting

- Log: `~/Library/Logs/screenshot-to-clipboard.log`
- Status: `launchctl print gui/$(id -u)/com.macsetup.screenshot-to-clipboard`
- If the log says it can't read the screenshot folder, allow `~/.local/bin/screenshot-to-clipboard` in System Settings → Privacy & Security → Files & Folders (or Full Disk Access). It retries every few seconds, or run the installer again to restart it.

## Good to know

- Everything you screenshot goes on the clipboard, so clipboard managers and Universal Clipboard (your other Apple devices) can see it.
- If you don't need the saved file, macOS can already do this without any tool: press ⌘⌃⇧4 (copies without saving), or in the Screenshot app (⌘⇧5) choose Options → Save to → Clipboard.

## Tests

```sh
./screenshot-to-clipboard/test.sh
```

Builds the program and runs it against a scratch folder, so your real screenshot folder and settings are not touched. It does overwrite the clipboard while it runs; text is restored at the end.
