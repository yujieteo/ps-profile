# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-11-01

### Added

- Initial release of the profile for Windows PowerShell 5.1 in ConstrainedLanguage mode.
- Commands for finding files (`fd`), searching content (`rg`), picking items (`fzf`), and jumping to folders (`z`, `zi`).
- File index for share roots, built with `Update-Index`.
- Office file search in `rg` with `-Office`, and text comparison in `delta`.
- Helper commands for listing, paths, the clipboard, and text files.
