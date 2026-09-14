[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$NewVersion
)

$ErrorActionPreference = 'Stop'

try {
    [version]$NewVersion | Out-Null
}
catch {
    throw "Version '$NewVersion' is not a valid semantic version. Use a format like 0.1.1."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $repoRoot 'PlanetCrafterServer-module/PlanetCrafterServer'

$existingVersionDir = Get-ChildItem -Path $moduleRoot -Directory |
    Sort-Object { [version]$_.Name } |
    Select-Object -Last 1

if (-not $existingVersionDir) {
    throw "No versioned module folder was found under $moduleRoot."
}

$currentVersion = $existingVersionDir.Name
$sourceDir = $existingVersionDir.FullName
$targetDir = Join-Path $moduleRoot $NewVersion

if (Test-Path -LiteralPath $targetDir) {
    throw "A module folder already exists for version '$NewVersion'."
}

Rename-Item -LiteralPath $sourceDir -NewName $NewVersion

$manifestPath = Join-Path $targetDir 'PlanetCrafterServer.psd1'
$modulePath = Join-Path $targetDir 'PlanetCrafterServer.psm1'

$manifestContent = Get-Content -LiteralPath $manifestPath -Raw
$manifestContent = [regex]::Replace(
    $manifestContent,
    "ModuleVersion\s*=\s*'[^']+'",
    "ModuleVersion        = '$NewVersion'"
)
Set-Content -LiteralPath $manifestPath -Value $manifestContent -Encoding UTF8

$moduleContent = Get-Content -LiteralPath $modulePath -Raw
$moduleContent = [regex]::Replace(
    $moduleContent,
    "\$script:ModuleVersion\s*=\s*'[^']+'",
    "`$script:ModuleVersion = '$NewVersion'"
)
Set-Content -LiteralPath $modulePath -Value $moduleContent -Encoding UTF8

Write-Host "Updated module version from $currentVersion to $NewVersion."
Write-Host "Folder renamed to $targetDir"
Write-Host "Next steps:"
Write-Host "  git add ."
Write-Host "  git commit -m 'Bump module version to $NewVersion'"
Write-Host "  git tag v$NewVersion"
Write-Host "  git push origin main --tags"
