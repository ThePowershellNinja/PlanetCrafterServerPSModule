# PlanetCrafterServer PowerShell Module

`PlanetCrafterServer` is a PowerShell module for managing an **experimental Windows-based Planet Crafter headless server workflow**.

It packages the module files under:

```text
PlanetCrafterServer/0.1.0/
```

and provides cmdlets to:

- install or adopt a server instance
- start and stop the game process
- inspect server status and save metadata
- change server settings
- create fresh saves
- request in-game saves
- complete intro flow when needed
- uninstall a managed instance

> [!IMPORTANT]
> Planet Crafter does **not** ship an official dedicated server product. This module automates an unsupported headless/client-host workflow.

## What is in this repository

The current release package contains:

- `PlanetCrafterServer/0.1.0/PlanetCrafterServer.psm1`
- `PlanetCrafterServer/0.1.0/PlanetCrafterServer.psd1`
- `PlanetCrafterServer/0.1.0/PlanetCrafterServer.Format.ps1xml`
- `PlanetCrafterServer/0.1.0/lib/net40/Mono.Cecil.dll`
- `PlanetCrafterServer/0.1.0/lib/netstandard2.0/Mono.Cecil.dll`

## Requirements

To use this module successfully, you need:

- **Windows**
- **PowerShell 5.1 or PowerShell 7**
- a local copy of **The Planet Crafter** client files
- enough disk space for one or more server copies

Optional but often useful:

- an elevated PowerShell session if you want the module to create or update Windows Firewall rules automatically
- `steamcmd.exe` if you want to install game files through SteamCMD instead of copying from an existing local game install

## Install the module from the GitHub release

The easiest install method is to use the packaged ZIP from the repository's Releases page.

### 1. Download the release ZIP

Download the latest release asset from GitHub Releases:

```text
PlanetCrafterServer-v0.1.0.zip
```

Release page:

```text
https://github.com/ThePowershellNinja/PlanetCrafterServerPSModule/releases
```

### 2. Extract the module into a PowerShell module path

The ZIP contains a `PlanetCrafterServer/0.1.0/` folder. That folder must end up under a directory in `$env:PSModulePath`.

Common choices:

| Scope | Typical path |
| --- | --- |
| Current user, Windows PowerShell 5.1 | `$HOME\Documents\WindowsPowerShell\Modules\` |
| Current user, PowerShell 7 | `$HOME\Documents\PowerShell\Modules\` |
| All users, Windows PowerShell 5.1 | `$env:ProgramFiles\WindowsPowerShell\Modules\` |
| All users, PowerShell 7 | `$env:ProgramFiles\PowerShell\Modules\` |

### Example: install for the current user

In PowerShell:

```powershell
$releaseZip = Join-Path $HOME 'Downloads\PlanetCrafterServer-v0.1.0.zip'
$moduleRoot = Join-Path $HOME 'Documents\PowerShell\Modules'

Expand-Archive -LiteralPath $releaseZip -DestinationPath $moduleRoot -Force
```

After extraction, the final layout should look like:

```text
<ModulePath>\PlanetCrafterServer\0.1.0\PlanetCrafterServer.psd1
<ModulePath>\PlanetCrafterServer\0.1.0\PlanetCrafterServer.psm1
```

### 3. Import the module

```powershell
Import-Module PlanetCrafterServer -Force
```

### 4. Verify installation

```powershell
Get-Command -Module PlanetCrafterServer
```

You should see at least:

- `Install-PlanetCrafterServer`
- `Set-PlanetCrafterServer`
- `Start-PlanetCrafterServer`
- `Stop-PlanetCrafterServer`
- `Get-PlanetCrafterServer`
- `Uninstall-PlanetCrafterServer`
- `New-PlanetCrafterServerSave`
- `Save-PlanetCrafterServer`
- `Complete-PlanetCrafterServerIntro`

## Recommended first server install

For a first server, the simplest reliable path is:

1. use an existing local Planet Crafter client install as the source
2. create a dedicated save root for the server
3. point the server at an existing save or generate a new one later

### Example folders

This example assumes:

- your game is installed in Steam under the default Windows location
- you want your server copy under `GameServers`
- you want save data under `ProgramData`

```powershell
$gameSource = Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\common\The Planet Crafter'
$installPath = Join-Path $env:SystemDrive 'GameServers\MyFirstPlanetCrafterServer'
$saveRoot = Join-Path $env:ProgramData 'PlanetCrafterServer\Saves\MyFirstPlanetCrafterServer'
$localSaveRoot = Join-Path $env:USERPROFILE 'AppData\LocalLow\MijuGames\Planet Crafter'
```

### First server from local game files

If you already have a save you want to host:

```powershell
$selectedSave = Join-Path $localSaveRoot 'Standard-1.json'

Install-PlanetCrafterServer `
  -Name 'MyFirstPlanetCrafterServer' `
  -InstallPath $installPath `
  -SourcePath $gameSource `
  -SaveRootPath $saveRoot `
  -SelectedSavePath $selectedSave `
  -HostPlayerName 'ServerHost' `
  -Port 7777 `
  -StartAfterInstall
```

### What the important parameters mean

| Parameter | Purpose |
| --- | --- |
| `-Name` | Logical name used by the module to track this server instance |
| `-InstallPath` | Folder where the copied/installed Planet Crafter server files live |
| `-SourcePath` | Existing local Planet Crafter client files to copy |
| `-SaveRootPath` | Folder that stores runtime save files and `Server.conf` for this instance |
| `-SelectedSavePath` | Existing save file to copy into the runtime slot |
| `-HostPlayerName` | Host player name written into config/runtime save handling |
| `-Port` | Multiplayer host port |
| `-StartAfterInstall` | Starts the server immediately after installation |

### When you may need elevation

If you want the module to manage Windows Firewall rules automatically, run the install command in an elevated PowerShell session.

If you do **not** want firewall rule changes, add:

```powershell
-SkipFirewallRuleUpdate
```

## Installing a first server with a fresh generated save

The module can also stage a brand-new save request during install:

```powershell
Install-PlanetCrafterServer `
  -Name 'FreshWorldServer' `
  -InstallPath (Join-Path $env:SystemDrive 'GameServers\FreshWorldServer') `
  -SourcePath $gameSource `
  -SaveRootPath (Join-Path $env:ProgramData 'PlanetCrafterServer\Saves\FreshWorldServer') `
  -HostPlayerName 'ServerHost' `
  -Port 7777 `
  -NewSaveRequestAfterInstall `
  -NewSavePlanetId 'Prime' `
  -NewSaveGameMode 'Standard' `
  -NewSaveStartLocation 'Standard' `
  -StartAfterInstall
```

If you omit `-SelectedSavePath` in the new-save flow, the module defaults the selected save to the runtime save path for the generated save.

## Core cmdlets

### `Get-PlanetCrafterServer`

Use this to inspect the current state of one or more registered instances.

Example:

```powershell
Get-PlanetCrafterServer
Get-PlanetCrafterServer -Name 'MyFirstPlanetCrafterServer'
```

Useful for checking:

- whether the server is running
- current port
- runtime save path
- selected save path
- patch state
- IP address information

### `Start-PlanetCrafterServer`

Starts a registered server instance.

Example:

```powershell
Start-PlanetCrafterServer -Name 'MyFirstPlanetCrafterServer'
```

Use `-ForceRestart` to stop and restart an already running instance.

### `Stop-PlanetCrafterServer`

Stops a running server instance.

Example:

```powershell
Stop-PlanetCrafterServer -Name 'MyFirstPlanetCrafterServer'
```

### `Set-PlanetCrafterServer`

Changes settings for an existing managed instance.

Example: change the port

```powershell
Set-PlanetCrafterServer -Name 'MyFirstPlanetCrafterServer' -Port 7788
```

Example: update the selected save

```powershell
Set-PlanetCrafterServer -Name 'MyFirstPlanetCrafterServer' -SelectedSavePath $selectedSave
```

Example: update and restart immediately

```powershell
Set-PlanetCrafterServer -Name 'MyFirstPlanetCrafterServer' -HostPlayerName 'ServerHost' -RestartIfRunning
```

### `Uninstall-PlanetCrafterServer`

Removes a managed server instance.

Example:

```powershell
Uninstall-PlanetCrafterServer -Name 'MyFirstPlanetCrafterServer'
```

Use `-KeepSaveData` if you want to preserve the runtime save/config files.

## Save-management cmdlets

### `New-PlanetCrafterServerSave`

Requests a fresh save from a running patched server.

Example:

```powershell
New-PlanetCrafterServerSave `
  -Name 'MyFirstPlanetCrafterServer' `
  -SaveDisplayName 'FreshWorld' `
  -PlanetId 'Prime' `
  -GameMode 'Standard' `
  -StartLocation 'Standard'
```

This is useful when you want the game to create a world using its own new-save path instead of copying an existing save.

### `Save-PlanetCrafterServer`

Requests an immediate in-game save from a running server.

Example:

```powershell
Save-PlanetCrafterServer -Name 'MyFirstPlanetCrafterServer'
```

### `Complete-PlanetCrafterServerIntro`

Requests intro/cutscene completion for a running patched server when that is needed before a world is fully usable, then optionally saves the result.

Example:

```powershell
Complete-PlanetCrafterServerIntro -Name 'MyFirstPlanetCrafterServer'
```

## Typical day-to-day workflow

After the module is installed and a server has been created, most usage looks like:

```powershell
Import-Module PlanetCrafterServer -Force
Get-PlanetCrafterServer
Start-PlanetCrafterServer -Name 'MyFirstPlanetCrafterServer'
Save-PlanetCrafterServer -Name 'MyFirstPlanetCrafterServer'
Stop-PlanetCrafterServer -Name 'MyFirstPlanetCrafterServer'
```

## Notes and caveats

- This module is for **Windows-based** hosting workflows.
- Planet Crafter itself is not an official dedicated server product.
- A stable unattended host process is best launched from a **local Windows session**, scheduled task, service wrapper, or other detached/local host mechanism. A process started from an SSH-owned shell may inherit that session's lifetime.
- The fresh-save and intro-completion flows depend on the module's game patching logic. If the game updates and internal methods or fields change, those flows may need module updates.

## Troubleshooting

### `Import-Module PlanetCrafterServer` does not work

Check:

- the module folder is under a valid `$env:PSModulePath` directory
- the final layout includes `PlanetCrafterServer\0.1.0\PlanetCrafterServer.psd1`
- you extracted the release ZIP fully rather than copying only one file

### `Install-PlanetCrafterServer` fails to create firewall rules

Run PowerShell as Administrator, or add:

```powershell
-SkipFirewallRuleUpdate
```

### The server starts but clients cannot join

Check:

- the configured port
- Windows Firewall rules
- whether the correct save/runtime world loaded
- whether the server needs a client-side direct-join plugin for IP joining, depending on how clients connect

### The game or module patch breaks after an update

If Planet Crafter updates and internal methods change, patch-dependent cmdlets may need to be updated before they work again.

## License

See [LICENSE](LICENSE).
