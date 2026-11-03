# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `check.ps1` and `tests.ps1` check the profile: parse, no comments, PSScriptAnalyzer, unused functions, tests in ConstrainedLanguage mode with strict mode, and a replay of the tests against `origin/main`.

### Changed

- The picker and the helpers read optional properties of an item safely, so they work in strict mode.
- `$global:PSProfileVersion` holds the profile version.
- The profile checks `$ShareRoots` at load. It warns about an entry that is not a non-empty string or not on a mapped network drive, and it skips an entry that is not a non-empty string.

## [1.2.0] - 2026-11-01

### Changed

- The picker takes `#12` as a pick of item 12. A plain number now filters the list, so you can search for a small number.
- `z` and `zi` record the jump, so the rank of the folder rises.
- `du` under `$ShareRoots` reads the sizes from the index, not from a scan of the network.
- Ctrl+T outside `$ShareRoots` stops the scan after 20000 items and shows a warning.

### Fixed

- The index build keeps the old index when a root is not reachable. It keeps the old lines of a folder that it cannot read.
- The index build saves its progress every 2 minutes. A closed window no longer loses the work. The index is `old` until a build ends.
- Reading an Office file is faster, because the progress bar of `Expand-Archive` is off.

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
