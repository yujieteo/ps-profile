# ps-profile

[![License: MIT](https://img.shields.io/github/license/yujieteo/ps-profile)](LICENSE)
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/scripting/windows-powershell/install/windows-powershell-system-requirements)
[![Latest release](https://img.shields.io/github/v/release/yujieteo/ps-profile)](https://github.com/yujieteo/ps-profile/releases/latest)

A PowerShell profile for Windows PowerShell 5.1 on computers that use ConstrainedLanguage mode. It adds commands to find files, search content, show files and move between folders. It uses only cmdlets and core types.

## What it does

The profile adds these commands:

| Command | Purpose |
|---|---|
| `fd` | Find files by name. Use `-Ext`, `-Changed` (for example `30d`) and `-Size` (for example `+1MB`) to filter. Uses the file index for folders under `ShareRoots`. |
| `recent` | Show the 20 most recently changed files of the last 7 days under the current folder. Use `-Days` and `-Count` to change the limits. |
| `rg` (alias `grep`) | Search file content. Use `-Office` to search `.docx`, `.xlsx` and `.pptx` files. |
| `rgi` | Search file content and pick a match in the picker. The preview shows the lines around the match. The pick opens the file. |
| `fzf` | Pick an item from a list. Type text to filter the list. Type a number to pick an item. |
| `br` | Browse a folder in the picker. The picker shows 2 levels. A folder pick enters the folder. A file pick opens the file. |
| `bat` | Show a file with line numbers. Office files show as text. Use `-Range 100-200` to show some lines and `-Pattern` to highlight text. |
| `du` | Show folder sizes as a tree, largest first. Use `-Depth` to change the number of levels. |
| `tldr` | Show examples for the profile commands. Run `tldr` with no argument to list the commands. |
| `z`, `zi` | Jump to a folder you used before. `zi` shows a picker. |
| `cd` | Change folder. Records the visit for `z`. |
| `delta` | Show the differences between two files. Office files are compared as text. |
| `ls`, `ll` | List files. Colors show the file type. |
| `cpath`, `unc`, `cb`, `pb` | Copy paths or text to the clipboard, or get the clipboard text. |
| `wc`, `head`, `tail`, `which`, `touch` | Small versions of common Unix commands. |
| `mkcd`, `up`, `..`, `...` | Create and enter a folder, or go to a parent folder. |
| `open` | Open a file with its default program. |
| `ep`, `reload` | Open the profile in Notepad. Load the profile again. |

## Picker and preview

The picker (`fzf`, `zi`, `rgi`, `br`, Ctrl+R and Ctrl+T) shows a preview at the side of the list. The preview shows item 1 of the list:

- For a file, the preview shows the first lines with line numbers, as `bat` shows them. Office files show as text.
- For a folder, the preview shows the items in the folder.
- For an `rg` match, the preview shows the lines around the match. The match line is yellow.

The preview needs a window width of 60 characters or more. The preview does not read files over 20 MB.

## Keys

| Key | Purpose |
|---|---|
| Ctrl+R | Pick a command from the full PSReadLine history. The command goes to the clipboard. |
| Ctrl+T | Pick a file under the current folder. The path goes to the clipboard. |

After the pick, press Ctrl+V to insert the text on the command line. ConstrainedLanguage mode blocks the PSReadLine methods that put text on the command line. Thus the keys use the clipboard.

## Prompt

The prompt shows the current folder. It also shows the time of commands that take more than 2 seconds.

## Install

1. Open Windows PowerShell and run `$PROFILE`. The output is the path of the profile file.
2. If the file does not exist, create it at that path.
3. Copy `Microsoft.PowerShell_profile.ps1` to that path. Replace the file if it exists.
4. Open a new Windows PowerShell window.

If PowerShell does not load the profile, run `Get-ExecutionPolicy` to check the execution policy.

## Share roots

The `fd` command uses a file index for network shares and mapped drives. Set the folders to index in `$global:ShareRoots`, near the top of the profile:

```powershell
$global:ShareRoots = @('S:\Finance', '\\fileserver\public')
```

- Mapped drive letters are allowed. The profile converts them to the UNC path that Windows shows for the drive.
- Run `Update-Index` to build or refresh the index for all share roots.
- Run `Update-Index 'S:\Finance\2026'` to refresh one folder under a share root.
- At startup, the profile starts a background index job when the index is older than 24 hours. The prompt shows `[index building]` or `[index old]` when this applies.
- `fd` in a folder that is not under `ShareRoots` uses a recursive search instead.
- The index keeps the size and the change time of each file. Thus `fd -Changed`, `fd -Size` and `recent` are fast on share roots.
- The index builder lists a folder again only when the time of the folder changes. If a program changes a file but not its folder, the index keeps the old size and time of that file.
- Version 1.1.0 uses a new index format. After the upgrade, the profile builds the index of each share root again one time. The profile does not read an index of version 1.0.0, and it deletes the old files.

## Where the profile writes data

The profile writes its data to `$env:LOCALAPPDATA\ps-profile`. The profile creates this folder at startup. The folder contains:

- `idx2_*.idx` and `idx2_*.state`: the file index for each share root.
- `index.lock`: exists only while an index build runs.
- `z.txt`: the folder history for `z`.

When `rg -Office`, `bat`, `delta` or the preview reads an Office file, it unpacks the file in a temporary folder under `$env:TEMP`. The profile deletes this folder after the search.

## ConstrainedLanguage limits

The profile does not use `Add-Type`, COM objects, or `Invoke-Expression`. Because of these limits:

- The commands are PowerShell code. They do not call external programs such as `rg.exe` or `fzf.exe`.
- `ep` starts `notepad.exe`.
- `rg -Office`, `bat`, `delta` and the preview read Office files by unpacking the file and reading its XML. Legacy `.doc`, `.xls` and `.ppt` files are not read.
- `rg` skips binary files and files over 20 MB by default. Use `-MaxSizeMB` to change the limit.
- `rg` and `rgi` refuse a content search of a whole share. Give a folder instead.
- The picker uses `Read-Host`. Type text and press Enter to filter, or type a number and press Enter to pick. It does not filter on each key.
- Ctrl+R and Ctrl+T put the pick on the clipboard, not on the command line. See [Keys](#keys).

## Release

The current version is 1.1.0. See [CHANGELOG.md](CHANGELOG.md).

After the change merges to the default branch:

1. Run `git tag v1.1.0` on the merged commit.
2. Run `git push origin v1.1.0`.
3. Create a GitHub release for the tag `v1.1.0`.
4. Attach `Microsoft.PowerShell_profile.ps1` to the release.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
