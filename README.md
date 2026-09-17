# PlanetCrafterServer

PowerShell module for running an **experimental Windows Planet Crafter headless server**.

> [!IMPORTANT]
> Planet Crafter has no official dedicated server. This module automates an unsupported headless/client-host workflow.

## Requirements

- Windows
- PowerShell 5.1 or PowerShell 7
- SteamCMD, or a local copy of the Planet Crafter client files
- ~6 GB free disk space
- An elevated session if you want firewall rules created automatically

## Install

```powershell
Install-Module PlanetCrafterServer
Import-Module PlanetCrafterServer
```

To update later:

```powershell
Update-Module PlanetCrafterServer
```

## Install a server

```powershell
Install-PlanetCrafterServer -Name 'MyNewPlanetCrafterServer' -SteamCredential '<SteamUserID>' -SteamCmdPath 'D:\Steam\steamcmd.exe' -NewSavePlanetId 'Prime' -NewSaveStartLocation 'Ice plains' -HostPlayerName 'Goober' -Port 7777 -StartAfterInstall -InstallPath 'D:\Servers\'
```

- `-InstallPath` ending in `\` creates the server folder as `D:\Servers\<Name>`.
- Use `-SourcePath <path>` instead of `-SteamCredential`/`-SteamCmdPath` to copy existing local game files.
- Add `-SkipFirewallRuleUpdate` if you do not want firewall changes.

## Everyday commands

```powershell
# Show status for every registered instance
Get-PlanetCrafterServer

# Launch the server and wait for it to bind its port
Start-PlanetCrafterServer -Name MyNewPlanetCrafterServer

# Stop the server, then start it again
Restart-PlanetCrafterServer -Name MyNewPlanetCrafterServer

# Ask the running server to write its world to disk now
Save-PlanetCrafterServer -Name MyNewPlanetCrafterServer

# Shut the server down gracefully
Stop-PlanetCrafterServer -Name MyNewPlanetCrafterServer

# Change instance settings such as port, save, or host player name
Set-PlanetCrafterServer -Name MyNewPlanetCrafterServer -Port 7788 -RestartIfRunning

# Generate a brand-new world for the instance
New-PlanetCrafterServerSave -Name MyNewPlanetCrafterServer -PlanetId Prime -StartLocation 'Ice plains'

# Skip the intro sequence on a freshly generated world
Complete-PlanetCrafterServerIntro -Name MyNewPlanetCrafterServer

# Remove the instance and everything it owns (-KeepSaveData preserves saves)
Uninstall-PlanetCrafterServer -Name MyNewPlanetCrafterServer
```

`Uninstall-PlanetCrafterServer` deletes the entire install folder, backups, and firewall rules, plus the instance's save folder unless `-KeepSaveData` is used.

## Notes

- Run the server from a local Windows session, scheduled task, or service wrapper. A process started from an SSH shell dies with that session.
- Fresh-save and intro-completion flows rely on game patching, so a Planet Crafter update may require a module update.

## License

See [LICENSE](LICENSE).
