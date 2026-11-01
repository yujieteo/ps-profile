# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-11-01

### Added

- `bat` shows a file with line numbers. Office files show as text. `-Range` shows some lines and `-Pattern` highlights text.
- `du` shows folder sizes as a tree, largest first.
- `recent` shows the most recently changed files. It uses the same search as `fd -Changed`.
- `tldr` shows examples for the profile commands.
- `rgi` shows `rg` matches in the picker. A pick opens the file.
- `br` browses folders in the picker.
- `fd` filters: `-Ext`, `-Changed` and `-Size`.
- The picker shows a preview of item 1 at the side of the list.
- Ctrl+R picks a command from the full history. Ctrl+T picks a file under the current folder. The pick goes to the clipboard, because ConstrainedLanguage mode blocks text input on the command line. Press Ctrl+V to insert it.

### Changed

- The file index keeps the size and the change time of each file. The index files have the new name `idx2_*`. The profile builds the index of each share root again one time, and deletes the old `idx_*` files.
- Ctrl+R replaces the standard reverse history search of PSReadLine.

## [1.0.0] - 2026-11-01

### Added

- Initial release of the profile for Windows PowerShell 5.1 in ConstrainedLanguage mode.
- Commands for finding files (`fd`), searching content (`rg`), picking items (`fzf`), and jumping to folders (`z`, `zi`).
- File index for share roots, built with `Update-Index`.
- Office file search in `rg` with `-Office`, and text comparison in `delta`.
- Helper commands for listing, paths, the clipboard, and text files.
