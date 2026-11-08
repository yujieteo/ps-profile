# ps-profile

[![License: MIT](https://img.shields.io/github/license/yujieteo/ps-profile)](LICENSE)
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)](https://learn.microsoft.com/powershell/scripting/windows-powershell/install/windows-powershell-system-requirements)
[![Latest release](https://img.shields.io/github/v/release/yujieteo/ps-profile)](https://github.com/yujieteo/ps-profile/releases/latest)

This profile adds commands to find files, search content, show files, and move folders, using only cmdlets and core types.

It is for Windows PowerShell 5.1 on computers that use ConstrainedLanguage mode.

## What it does

The profile adds these commands:

| Command | Purpose |
|---|---|
| `fd` | Find files by name, with colors. Lower-case text ignores case, and an upper-case letter makes the search case-sensitive. Use `-e` for extensions, `-t f` or `-t d` for the type, `-Changed` (for example `30d`) and `-Size` (for example `+1MB`) to filter. Hidden files and dot files show only with `-H`. In a Git repository, files that `.gitignore` ignores show only with `-I`. Uses the file index for folders under `ShareRoots`. |
| `recent` | Show the 20 most recently changed files of the last 7 days under the current folder. Use `-Days` and `-Count` to change the limits. |
| `rg` (alias `grep`) | Search file content or filter piped text. Lower-case text ignores case, and an upper-case letter makes the search case-sensitive. Use `-i` or `-s` to choose. It skips dot files and, in a Git repository, the files that `.gitignore` ignores. Use `-Hidden` or `-u` to include them. Other options are `-v`, `-w`, `-n`, `-l`, `-A`, `-B`, `-C` and `-g`. Use `-Office` to search `.docx`, `.xlsx` and `.pptx` files. |
| `rgi` | Search file content and pick a match in the picker. The preview shows the lines around the match. The pick opens the file. |
| `fzf` | Pick an item from a list. Type text to filter the list. Type `#2` to pick item 2. |
| `br` | Browse a folder in the picker. The picker shows 2 levels. A folder pick enters the folder. A file pick opens the file. |
| `bat` | Show a file with line numbers and basic syntax colors. Office files show as text. Use `-Range 100-200` to show some lines and `-Pattern` to highlight text. |
| `du` | Show folder sizes as a tree with bars, largest first. Use `-Depth` to change the number of levels. |
| `tldr` | Show examples for the profile commands. Run `tldr` with no argument to list the commands. |
| `z`, `zi` | Jump to a folder you used before. `zi` shows a picker. |
| `cd` | Change folder. Records the visit for `z`. `cd -` goes back to the previous folder. |
| `delta` | Show the differences between two files. Use `-s` for side by side. The command compares Office files as text. |
| `ls`, `ll` | List files. Colors show the file type. |
| `cpath`, `unc`, `cb`, `pb` | Copy paths or text to the clipboard, or get the clipboard text. |
| `wc`, `head`, `tail`, `which`, `touch` | Small versions of common Unix commands. `wc` takes `-l`, `-w` and `-c`. `tail -f` shows new lines as they arrive. |
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

## Tab completion

Press Tab after `z` or `zi` to complete a folder from the history. Press Tab after `tldr` to complete a page name. Press Tab after `-` to complete the long option names of a command.

## Prompt

The prompt shows the current folder. It also shows the time of commands that take more than 2 seconds.

## Install

1. Open Windows PowerShell and run `$PROFILE`. The output is the path of the profile file.
2. If the file does not exist, create it at that path.
3. Download [`Microsoft.PowerShell_profile.ps1` version 1.3.0](https://github.com/yujieteo/ps-profile/releases/download/v1.3.0/Microsoft.PowerShell_profile.ps1). Copy it to that path. Replace the file if it exists.
4. Open a new Windows PowerShell window.
5. Run `$PSProfileVersion` to see the installed version.

If PowerShell does not load the profile, run `Get-ExecutionPolicy` to check the execution policy.

## Share roots

The `fd` command uses a file index for network shares and mapped drives. Set the folders to index in the `$global:ShareRoots` setting at the top of the profile:

```powershell
$global:ShareRoots = @('S:\Finance', '\\fileserver\public')
```

An upgrade replaces the profile file, and this setting with it. To keep your share roots after an upgrade, put them in `$env:LOCALAPPDATA\ps-profile\share-roots.txt`, one folder on each line. The profile adds these folders to `$ShareRoots` at load.

- You can use mapped drive letters. The profile converts them to the UNC path that Windows shows for the drive.
- The profile checks `$ShareRoots` at load. An entry that is not a non-empty string, or a drive letter that is not a mapped network drive, gives a warning. The warning starts with `$ShareRoots:` and shows the example `'S:\Finance'`. The profile skips an entry that is not a non-empty string.
- Run `Update-Index` to build or refresh the index for all share roots.
- Run `Update-Index 'S:\Finance\2026'` to refresh one folder under a share root.
- At startup, the profile starts a background index job when the index is older than 24 hours. The prompt shows `[index building]` or `[index old]` when this applies.
- `fd` in a folder that is not under `ShareRoots` uses a recursive search instead.
- The index does not keep the Windows hidden attribute. Under `ShareRoots`, `fd` without `-H` hides only names that start with a dot.
- The index keeps the size and the change time of each file. Thus `fd -Changed`, `fd -Size` and `recent` are fast on share roots.
- The index builder lists a folder again only when the time of the folder changes. If a program changes a file but not its folder, the index keeps the old size and time of that file.
- Version 1.1.0 uses a new index format. After the upgrade, the profile builds the index of each share root again one time. The profile does not read an index of version 1.0.0, and it deletes the old files.

## Where the profile writes data

The profile writes its data to `$env:LOCALAPPDATA\ps-profile`. The profile creates this folder at startup. The folder contains:

- `idx2_*.idx` and `idx2_*.state`: the file index for each share root.
- `index.lock`: exists only while an index build runs.
- `idx2_*.partial`: exists while an index build runs. The index is `old` until the build ends.
- `z.txt`: the folder history for `z`.
- `share-roots.txt`: your share roots, if you create this file.

When `rg -Office`, `bat`, `delta` or the preview reads an Office file, it unpacks the file in a temporary folder under `$env:TEMP`. The profile deletes this folder after the search.

## ConstrainedLanguage limits

The profile does not use `Add-Type`, COM objects, or `Invoke-Expression`. Because of these limits:

- The commands are PowerShell code. They do not call external programs such as `rg.exe` or `fzf.exe`.
- `ep` starts `notepad.exe`.
- `rg -Office`, `bat`, `delta` and the preview read Office files. They unpack the file and read its XML. The commands do not read legacy `.doc`, `.xls` and `.ppt` files.
- `rg` skips binary files and files over 20 MB by default. Use `-MaxSizeMB` to change the limit.
- `rg` and `rgi` refuse a content search of a whole share. Give a folder instead.
- The picker uses `Read-Host`. Type text and press Enter to filter. Type `#` and the item number, for example `#12`, and press Enter to pick. A plain number filters the list. It does not filter on each key.
- `bat` colors files of up to 5000 lines.
- `fd` and `rg` read `.gitignore` files and `.git/info/exclude`. They do not read the global Git ignore file.
- Ctrl+R and Ctrl+T put the pick on the clipboard, not on the command line. See [Keys](#keys).

## Release

The current version is 1.3.0. See [CHANGELOG.md](CHANGELOG.md).

Before the merge, change the version in [Install](#install) and in this section.

After the change merges to the default branch:

1. Run `git tag v1.3.0` on the merged commit.
2. Run `git push origin v1.3.0`.
3. Create a GitHub release for the tag `v1.3.0`.
4. Attach `Microsoft.PowerShell_profile.ps1` to the release.

## License

This project uses the MIT License. See [LICENSE](LICENSE).
