@{
    RootModule           = 'PlanetCrafterServer.psm1'
    ModuleVersion        = '0.1.1'
    GUID                 = '7a7d42d1-b6ea-4e62-b981-7299f4a178ce'
    Author               = 'GitHub Copilot'
    CompanyName          = 'GitHub'
    Copyright            = '(c) GitHub. All rights reserved.'
    Description          = 'Manage experimental Planet Crafter headless server installations on Windows.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FormatsToProcess     = @('PlanetCrafterServer.Format.ps1xml')
    FunctionsToExport    = @(
        'Get-PlanetCrafterServer',
        'Start-PlanetCrafterServer',
        'New-PlanetCrafterServerSave',
        'Save-PlanetCrafterServer',
        'Complete-PlanetCrafterServerIntro',
        'Stop-PlanetCrafterServer',
        'Set-PlanetCrafterServer',
        'Install-PlanetCrafterServer',
        'Uninstall-PlanetCrafterServer'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('PlanetCrafter', 'GameServer', 'Headless', 'Experimental')
            ProjectUri = 'https://store.steampowered.com/app/1284190/The_Planet_Crafter/'
        }
    }
}

