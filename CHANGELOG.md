# Changelog

This file lists all notable changes to this project.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `rg` and `grep` filter piped text, for example `ipconfig | rg IPv4`. A piped full path that exists is still searched as a file.
- `cd -` goes back to the previous folder. Windows PowerShell 5.1 does not have this.
- `tail -f` shows new lines as they arrive.
- `wc` takes `-l`, `-w` and `-c` and then shows only that number.
- `$env:LOCALAPPDATA\ps-profile\share-roots.txt` keeps your share roots after an upgrade.
- `tldr` has a page for every command.
- `rg` has `-v`, `-w`, `-n`, `-A`, `-B` and `-s`.
- `fd` has `-e`, `-t` and `-H`, and colors its output.
- Tab completes `z` and `zi` folders and `tldr` pages.
- `bat` has basic syntax colors. `du` has bars. `tldr` has colors.
- `delta -s` shows two columns. `head -5` and `tail -5` work.

### Changed

- `rg` and `fd` use smart case. Lower-case text ignores case, and an upper-case letter makes the search case-sensitive. Before this change, `rg` was always case-sensitive and `fd` always ignored case.
- `fd` hides hidden files and dot files. Use `-H` to show them.
- The picker shows up to 50 rows when the window is tall enough.
- The picker and the helpers read optional properties of an item safely, so they work in strict mode.
- `$global:PSProfileVersion` holds the profile version.
- The profile checks `$ShareRoots` at load. It warns about an entry that is not a non-empty string or not on a mapped network drive. It skips an entry that is not a non-empty string.

## [1.2.0] - 2026-11-01

### Changed in 1.2.0

- The picker takes `#12` as a pick of item 12. A plain number now filters the list, so you can search for a small number.
- `z` and `zi` record the jump, so the rank of the folder rises.
- `du` under `$ShareRoots` reads the sizes from the index, not from a scan of the network.
- Ctrl+T outside `$ShareRoots` stops the scan after 20000 items and shows a warning.

### Fixed

- The index build keeps the old index when a root is not reachable. It keeps the old lines of a folder that it cannot read.
- The index build saves its progress every 2 minutes. A closed window no longer loses the work. The index is `old` until a build ends.
- Reading an Office file is faster, because the progress bar of `Expand-Archive` is off.

## [1.1.0] - 2026-11-01

### Added in 1.1.0

- `bat` shows a file with line numbers. Office files show as text. `-Range` shows some lines and `-Pattern` highlights text.
- `du` shows folder sizes as a tree, largest first.
- `recent` shows the most recently changed files. It uses the same search as `fd -Changed`.
- `tldr` shows examples for the profile commands.
- `rgi` shows `rg` matches in the picker. A pick opens the file.
- `br` browses folders in the picker.
- `fd` filters: `-Ext`, `-Changed` and `-Size`.
- The picker shows a preview of item 1 at the side of the list.
- Ctrl+R picks a command from the full history. Ctrl+T picks a file under the current folder. The pick goes to the clipboard, because ConstrainedLanguage mode blocks text input on the command line. Press Ctrl+V to insert it.

### Changed in 1.1.0

- The file index keeps the size and the change time of each file. The index files have the new name `idx2_*`. The profile builds the index of each share root again one time, and deletes the old `idx_*` files.
- Ctrl+R replaces the standard reverse history search of PSReadLine.

## [1.0.0] - 2026-11-01

### Added in 1.0.0

- Initial release of the profile for Windows PowerShell 5.1 in ConstrainedLanguage mode.
- Commands to find files (`fd`), search content (`rg`), pick items (`fzf`), and jump to folders (`z`, `zi`).
- File index for share roots, built with `Update-Index`.
- Office file search in `rg` with `-Office`, and text comparison in `delta`.
- Helper commands to list files, to handle paths, to use the clipboard, and to work with text files.
