Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ModuleVersion = '0.1.1'
$script:GameAppId = 1284190
$script:DefaultExecutableName = 'Planet Crafter.exe'
$script:DefaultAssemblyRelativePath = 'Planet Crafter_Data\Managed\Assembly-CSharp.dll'
$script:DefaultLogRelativePath = 'Logs\server.log'
$script:DefaultRuntimeSaveFileName = 'Server-1.json'
$script:DefaultServerConfigFileName = 'Server.conf'
$script:DefaultHostPlayerName = 'Convict-1'
$script:DefaultHostPort = [uint16]7777
$script:DefaultLaunchArguments = @('-batchmode', '-nographics')
$script:DefaultReadyTimeoutSeconds = 90
$script:SaveRootEnvironmentVariableName = 'PLANETCRAFTERSERVER_SAVE_ROOT'
$script:SaveSlotNameEnvironmentVariableName = 'PLANETCRAFTERSERVER_SAVE_SLOT_NAME'
$script:PersistentDataPathOverrideMethodName = 'GetPlanetCrafterServerPersistentDataPath'
$script:SaveSlotNameOverrideMethodName = 'GetPlanetCrafterServerSaveSlotName'
$script:SaveSlotFileNameOverrideMethodName = 'GetPlanetCrafterServerSaveFileName'
$script:SaveSlotFilePathOverrideMethodName = 'GetPlanetCrafterServerSaveFilePath'
$script:SaveRequestFileName = '.planet-crafter-server-save-request'
$script:SaveRequestMethodName = 'ProcessPlanetCrafterServerSaveRequest'
$script:IntroSkipRequestFileName = '.planet-crafter-server-skip-intro-request'
$script:IntroSkipRequestMethodName = 'ProcessPlanetCrafterServerIntroSkipRequest'
$script:IntroSkipMethodName = 'PlanetCrafterServerCompleteIntro'
$script:NewSaveRequestFileName = '.planet-crafter-server-new-save-request'
$script:NewSaveRequestMethodName = 'ProcessPlanetCrafterServerNewSaveRequest'
$script:PublicIpCacheValue = $null
$script:PublicIpCacheExpiresAt = Get-Date '2000-01-01T00:00:00Z'
$script:PublicIpCacheError = $null

function ConvertTo-PCSHashtable {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[$key] = ConvertTo-PCSHashtable -Value $Value[$key]
        }
        return $result
    }

    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-PCSHashtable -Value $property.Value
        }
        return $result
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) {
            $items += ,(ConvertTo-PCSHashtable -Value $item)
        }
        return $items
    }

    return $Value
}

function Test-PCSMapContains {
    param(
        $Map,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    if ($null -eq $Map) {
        return $false
    }

    if ($Map -is [System.Collections.IDictionary]) {
        return $Map.Contains($Key)
    }

    if ($Map.PSObject -and $Map.PSObject.Properties[$Key]) {
        return $true
    }

    return $false
}

function Resolve-PCSPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Resolve-PCSInstallPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallPath,
        [string]$Name
    )

    $hasTrailingSeparator = $InstallPath.EndsWith('\') -or $InstallPath.EndsWith('/')
    if ($hasTrailingSeparator -and [string]::IsNullOrWhiteSpace($Name)) {
        throw "InstallPath '$InstallPath' ends with a path separator, so -Name is required to determine the server subfolder."
    }

    $resolvedPath = Resolve-PCSPath -Path $InstallPath
    if ($hasTrailingSeparator) {
        return Resolve-PCSPath -Path (Join-Path $resolvedPath $Name)
    }

    $resolvedPath
}

function Get-PCSProcessesUnderPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalizedPath = (Resolve-PCSPath -Path $Path).TrimEnd('\')
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath -like ($normalizedPath + '\*')
        })
}

function Copy-PCSFileWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [int]$RetryCount = 20,
        [int]$DelayMilliseconds = 500
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force -ErrorAction Stop
            return
        }
        catch {
            $lastError = $_
            if ($attempt -ge $RetryCount) {
                throw
            }

            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }

    if ($lastError) {
        throw "Failed to replace '$DestinationPath' after $RetryCount attempts. The file appears to be locked by another process or service. Original error: $($lastError.Exception.Message)"
    }
}

function Remove-PCSDirectoryTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$RetryCount = 5,
        [int]$DelayMilliseconds = 500
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            # Read-only attributes on Steam content can block deletion.
            Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                    $_.Attributes = $_.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
                }
            }

            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
        catch {
            $lastError = $_
        }

        if (-not (Test-Path -LiteralPath $Path)) {
            return
        }

        if ($attempt -lt $RetryCount) {
            Start-Sleep -Milliseconds $DelayMilliseconds
        }
    }

    $details = if ($lastError) { " Original error: $($lastError.Exception.Message)" } else { '' }
    throw "Failed to delete folder '$Path' after $RetryCount attempts. Stop any process using it, close Explorer windows or previews, and retry.$details"
}

function Get-PCSSaveNewline {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    if ($Content -match "`r`n") {
        return "`r`n"
    }

    return "`n"
}

function Set-PCSHostPlayerNameInSave {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SavePath,
        [Parameter(Mandatory = $true)]
        [string]$HostPlayerName,
        [System.Collections.IDictionary]$Instance
    )

    if (-not (Test-Path -LiteralPath $SavePath)) {
        return 0
    }

    $raw = Get-Content -LiteralPath $SavePath -Raw -ErrorAction Stop
    $sections = $raw -split '@', 0, 'SimpleMatch'
    if ($sections.Count -lt 3) {
        throw "Save file '$SavePath' is not in the expected Planet Crafter format."
    }

    $players = @(Convert-PCSSectionToList -Section $sections[2])
    if ($players.Count -eq 0) {
        return 0
    }

    $updatedCount = 0
    foreach ($player in $players) {
        $isHost = $false
        if ($player.PSObject.Properties['host']) {
            $isHost = [bool]$player.host
        }

        if ($isHost -and $player.PSObject.Properties['name']) {
            $player.name = $HostPlayerName
            $updatedCount++
        }
    }

    if ($updatedCount -eq 0) {
        return 0
    }

    if ($Instance) {
        New-PCSBackupFile -Instance $Instance -Path $SavePath | Out-Null
    }

    $newline = Get-PCSSaveNewline -Content $raw
    $sections[2] = $newline + ((@($players | ForEach-Object { $_ | ConvertTo-Json -Compress })) -join ('|' + $newline)) + $newline
    $updatedContent = [string]::Join('@', $sections)
    Set-Content -LiteralPath $SavePath -Value $updatedContent -Encoding UTF8 -NoNewline

    return $updatedCount
}

function Test-PCSIsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-PCSAdministrator {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ActionDescription
    )

    if (-not (Test-PCSIsAdministrator)) {
        throw "Administrative privileges are required to $ActionDescription. Re-run PowerShell as Administrator or use the relevant skip parameter when available."
    }
}

function Get-PCSDefaultSaveRoot {
    Join-Path $env:USERPROFILE 'AppData\LocalLow\MijuGames\Planet Crafter'
}

function Get-PCSLoadedAssemblyByName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq $Name } | Select-Object -First 1
}

function Get-PCSDataRoot {
    Join-Path $env:ProgramData 'PlanetCrafterServer'
}

function Get-PCSInstancesRoot {
    Join-Path (Get-PCSDataRoot) 'Instances'
}

function Get-PCSBackupsRoot {
    Join-Path (Get-PCSDataRoot) 'Backups'
}

function Initialize-PCSStorage {
    foreach ($path in @((Get-PCSDataRoot), (Get-PCSInstancesRoot), (Get-PCSBackupsRoot))) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }
}

function Get-PCSInstanceFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    Join-Path (Get-PCSInstancesRoot) ($Name + '.json')
}

function New-PCSInstanceRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$InstallPath,
        [Parameter(Mandatory = $true)]
        [string]$SaveRootPath,
        [Parameter(Mandatory = $true)]
        [string]$RuntimeSaveFileName,
        [string]$SelectedSavePath,
        [Parameter(Mandatory = $true)]
        [uint16]$Port,
        [Parameter(Mandatory = $true)]
        [string]$HostPlayerName,
        [Parameter(Mandatory = $true)]
        [string]$InstallMethod
    )

    $timestamp = (Get-Date).ToString('o')
    [ordered]@{
        Name                  = $Name
        InstallPath           = $InstallPath
        SaveRootPath          = $SaveRootPath
        RuntimeSaveFileName   = $RuntimeSaveFileName
        SelectedSavePath      = $SelectedSavePath
        ExecutableName        = $script:DefaultExecutableName
        AssemblyRelativePath  = $script:DefaultAssemblyRelativePath
        LogRelativePath       = $script:DefaultLogRelativePath
        ServerConfigFileName  = $script:DefaultServerConfigFileName
        HostPort              = [uint16]$Port
        HostPlayerName        = $HostPlayerName
        LaunchArguments       = $script:DefaultLaunchArguments
        ExperimentalHeadless  = $true
        ManagedByModule       = $true
        InstallMethod         = $InstallMethod
        AppId                 = $script:GameAppId
        CreatedAt             = $timestamp
        UpdatedAt             = $timestamp
    }
}

function Read-PCSJsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    ConvertTo-PCSHashtable -Value ($raw | ConvertFrom-Json)
}

function Write-PCSJsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Data
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $Data | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Save-PCSInstanceRecord {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Instance
    )

    Initialize-PCSStorage
    $Instance.UpdatedAt = (Get-Date).ToString('o')
    Write-PCSJsonFile -Path (Get-PCSInstanceFilePath -Name $Instance.Name) -Data $Instance
}

function Get-PCSRegisteredInstances {
    param(
        [string[]]$Name,
        [string]$InstallPath
    )

    Initialize-PCSStorage
    $items = @()
    foreach ($file in Get-ChildItem -LiteralPath (Get-PCSInstancesRoot) -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        $instance = Read-PCSJsonFile -Path $file.FullName
        if ($null -eq $instance) {
            continue
        }

        $include = $true
        if ($Name -and ($instance.Name -notin $Name)) {
            $include = $false
        }

        if ($InstallPath) {
            $resolvedInstallPath = Resolve-PCSPath -Path $InstallPath
            if ([string]::Compare($instance.InstallPath, $resolvedInstallPath, $true) -ne 0) {
                $include = $false
            }
        }

        if ($include) {
            $items += ,$instance
        }
    }

    return @($items)
}

function Resolve-PCSInstance {
    param(
        [string]$Name,
        [string]$InstallPath
    )

    $instances = @(Get-PCSRegisteredInstances -Name $Name -InstallPath $InstallPath)
    if ($instances.Count -eq 1) {
        return $instances[0]
    }

    if ($instances.Count -eq 0) {
        if ($Name) {
            throw "No Planet Crafter server instance named '$Name' is registered."
        }

        if ($InstallPath) {
            throw "No Planet Crafter server instance is registered for install path '$InstallPath'."
        }

        throw 'No Planet Crafter server instances are registered.'
    }

    throw 'Multiple Planet Crafter server instances matched. Specify -Name or -InstallPath.'
}

function Get-PCSExecutablePath {
    param([System.Collections.IDictionary]$Instance)
    Join-Path $Instance.InstallPath $Instance.ExecutableName
}

function Get-PCSAssemblyPath {
    param([System.Collections.IDictionary]$Instance)
    Join-Path $Instance.InstallPath $Instance.AssemblyRelativePath
}

function Get-PCSLogPath {
    param([System.Collections.IDictionary]$Instance)
    Join-Path $Instance.InstallPath $Instance.LogRelativePath
}

function Get-PCSSaveSlotBaseName {
    param([System.Collections.IDictionary]$Instance)

    $runtimeSaveFileName = if ($Instance.RuntimeSaveFileName) {
        [System.IO.Path]::GetFileName([string]$Instance.RuntimeSaveFileName)
    }
    else {
        $script:DefaultRuntimeSaveFileName
    }

    if ([string]::IsNullOrWhiteSpace($runtimeSaveFileName)) {
        $runtimeSaveFileName = $script:DefaultRuntimeSaveFileName
    }

    $slotName = [System.IO.Path]::GetFileNameWithoutExtension($runtimeSaveFileName)
    if ([string]::IsNullOrWhiteSpace($slotName)) {
        return [System.IO.Path]::GetFileNameWithoutExtension($script:DefaultRuntimeSaveFileName)
    }

    $slotName
}

function Get-PCSRuntimeSavePath {
    param([System.Collections.IDictionary]$Instance)
    Join-Path $Instance.SaveRootPath $Instance.RuntimeSaveFileName
}

function Test-PCSNewSaveRequestPending {
    param([System.Collections.IDictionary]$Instance)

    $requestPath = Join-Path $Instance.SaveRootPath $script:NewSaveRequestFileName
    Test-Path -LiteralPath $requestPath
}

function Get-PCSServerConfigPath {
    param([System.Collections.IDictionary]$Instance)
    Join-Path $Instance.SaveRootPath $Instance.ServerConfigFileName
}

function Get-PCSBackupRootForInstance {
    param([System.Collections.IDictionary]$Instance)
    Join-Path (Get-PCSBackupsRoot) $Instance.Name
}

function New-PCSBackupFile {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Instance,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $backupRoot = Get-PCSBackupRootForInstance -Instance $Instance
    if (-not (Test-Path -LiteralPath $backupRoot)) {
        New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $leaf = Split-Path -Leaf $Path
    $destination = Join-Path $backupRoot ($leaf + '.' + $timestamp + '.bak')
    Copy-Item -LiteralPath $Path -Destination $destination -Force
    $destination
}

function Get-PCSFirewallRuleBaseName {
    param([System.Collections.IDictionary]$Instance)

    $safeName = ($Instance.Name -replace '[^A-Za-z0-9_-]', '_')
    'PlanetCrafterServer-{0}' -f $safeName
}

function Set-PCSFirewallRules {
    param([System.Collections.IDictionary]$Instance)

    Assert-PCSAdministrator -ActionDescription 'create or update Planet Crafter firewall rules'

    $exePath = Get-PCSExecutablePath -Instance $Instance
    $baseName = Get-PCSFirewallRuleBaseName -Instance $Instance
    $udpRuleName = $baseName + '-UDP'
    $tcpRuleName = $baseName + '-TCP'

    foreach ($rule in @($udpRuleName, $tcpRuleName)) {
        Remove-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue | Out-Null
    }

    New-NetFirewallRule -Name $udpRuleName -DisplayName ('Planet Crafter Server {0} UDP' -f $Instance.Name) -Direction Inbound -Action Allow -Protocol UDP -Program $exePath -LocalPort ([int]$Instance.HostPort) -Profile Any -Enabled True -ErrorAction Stop | Out-Null
    New-NetFirewallRule -Name $tcpRuleName -DisplayName ('Planet Crafter Server {0} TCP' -f $Instance.Name) -Direction Inbound -Action Allow -Protocol TCP -Program $exePath -LocalPort ([int]$Instance.HostPort) -Profile Any -Enabled True -ErrorAction Stop | Out-Null
}

function Remove-PCSFirewallRules {
    param([System.Collections.IDictionary]$Instance)

    if (-not (Test-PCSIsAdministrator)) {
        Write-Warning "Skipping firewall rule removal for '$($Instance.Name)' because the current session is not elevated."
        return
    }

    $baseName = Get-PCSFirewallRuleBaseName -Instance $Instance
    foreach ($rule in @($baseName + '-UDP', $baseName + '-TCP')) {
        Remove-NetFirewallRule -Name $rule -ErrorAction SilentlyContinue | Out-Null
    }
}

function Get-PCSPlainTextFromCredential {
    param([pscredential]$Credential)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Invoke-PCSRobocopy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $arguments = @($Source, $Destination, '/E', '/R:2', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    & robocopy @arguments | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "Robocopy failed from '$Source' to '$Destination' with exit code $LASTEXITCODE."
    }
}

function Get-PCSPowerShellHostPath {
    # Prefers PowerShell 7 for out-of-process work, but Windows PowerShell can run it too.
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($PSVersionTable.PSEdition -eq 'Core') {
        $candidates.Add((Join-Path $PSHOME 'pwsh.exe'))
    }

    $pwshCommand = Get-Command -Name 'pwsh.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwshCommand) {
        $candidates.Add($pwshCommand.Source)
    }

    foreach ($programFiles in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($programFiles) {
            $candidates.Add((Join-Path $programFiles 'PowerShell\7\pwsh.exe'))
        }
    }

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $candidates.Add((Join-Path $PSHOME 'powershell.exe'))
    }

    $windowsPowerShellRoot = if ($env:SystemRoot) { $env:SystemRoot } else { 'C:\Windows' }
    $candidates.Add((Join-Path $windowsPowerShellRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))

    $powershellCommand = Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($powershellCommand) {
        $candidates.Add($powershellCommand.Source)
    }

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    throw 'Neither PowerShell 7 (pwsh.exe) nor Windows PowerShell (powershell.exe) was found. One of them is required for out-of-process Planet Crafter assembly patching.'
}

function Import-PCSMonoCecil {
    $loaded = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Mono.Cecil' } | Select-Object -First 1
    if ($loaded) {
        return
    }

    $moduleRoot = Split-Path -Parent $PSCommandPath
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $assemblyPath = Join-Path $moduleRoot 'lib\net40\Mono.Cecil.dll'
    }
    else {
        $assemblyPath = Join-Path $moduleRoot 'lib\netstandard2.0\Mono.Cecil.dll'
    }

    if (-not (Test-Path -LiteralPath $assemblyPath)) {
        throw "Mono.Cecil dependency not found at '$assemblyPath'."
    }

    Add-Type -Path $assemblyPath
}

function Get-PCSAllTypeDefinitions {
    param([Mono.Cecil.ModuleDefinition]$Module)

    $results = New-Object System.Collections.Generic.List[Mono.Cecil.TypeDefinition]

    function Add-TypeDefinitionTree {
        param([Mono.Cecil.TypeDefinition]$Type)
        $results.Add($Type) | Out-Null
        foreach ($nested in $Type.NestedTypes) {
            Add-TypeDefinitionTree -Type $nested
        }
    }

    foreach ($type in $Module.Types) {
        Add-TypeDefinitionTree -Type $type
    }

    $results
}

function Find-PCSTypeDefinition {
    param(
        [Mono.Cecil.ModuleDefinition]$Module,
        [string]$FullName
    )

    foreach ($type in Get-PCSAllTypeDefinitions -Module $Module) {
        if ($type.FullName -eq $FullName) {
            return $type
        }
    }

    throw "Type '$FullName' was not found in the target assembly."
}

function Find-PCSTypeReference {
    param(
        [Mono.Cecil.ModuleDefinition]$Module,
        [string]$FullName
    )

    $typeReference = $Module.GetTypeReferences() | Where-Object { $_.FullName -eq $FullName } | Select-Object -First 1
    if (-not $typeReference) {
        $typeDefinition = Get-PCSAllTypeDefinitions -Module $Module | Where-Object FullName -eq $FullName | Select-Object -First 1
        if ($typeDefinition) {
            return $Module.ImportReference($typeDefinition)
        }

        throw "Type reference '$FullName' was not found in the target assembly."
    }

    $typeReference
}

function Get-PCSNamedMethod {
    param(
        [Mono.Cecil.TypeDefinition]$Type,
        [string]$Name,
        [int]$ParameterCount = -1
    )

    foreach ($method in $Type.Methods) {
        if ($method.Name -ne $Name) {
            continue
        }

        if ($ParameterCount -ge 0 -and $method.Parameters.Count -ne $ParameterCount) {
            continue
        }

        return $method
    }

    throw "Method '$($Type.FullName)::$Name' was not found."
}

function Get-PCSOpCode {
    param([string]$Name)
    [Mono.Cecil.Cil.OpCodes].GetField($Name).GetValue($null)
}

function Ensure-PCSPersistentDataPathOverrideMethod {
    param(
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.ModuleDefinition]$Module,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$GameConfigType,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.MethodReference]$GetPersistentDataPathMethod
    )

    $existingMethod = $GameConfigType.Methods | Where-Object {
        $_.Name -eq $script:PersistentDataPathOverrideMethodName -and $_.Parameters.Count -eq 0
    } | Select-Object -First 1
    if ($existingMethod) {
        return $Module.ImportReference($existingMethod)
    }

    $coreLibrary = $Module.TypeSystem.CoreLibrary
    $environmentTypeReference = [Mono.Cecil.TypeReference]::new('System', 'Environment', $Module, $coreLibrary)

    $getEnvironmentVariableMethodReference = [Mono.Cecil.MethodReference]::new('GetEnvironmentVariable', $Module.TypeSystem.String, $environmentTypeReference)
    $getEnvironmentVariableMethodReference.HasThis = $false
    $null = $getEnvironmentVariableMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('variable', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $getEnvironmentVariableMethod = $Module.ImportReference($getEnvironmentVariableMethodReference)

    $isNullOrWhiteSpaceMethodReference = [Mono.Cecil.MethodReference]::new('IsNullOrWhiteSpace', $Module.TypeSystem.Boolean, $Module.TypeSystem.String)
    $isNullOrWhiteSpaceMethodReference.HasThis = $false
    $null = $isNullOrWhiteSpaceMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('value', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $isNullOrWhiteSpaceMethod = $Module.ImportReference($isNullOrWhiteSpaceMethodReference)

    $methodAttributes = [Mono.Cecil.MethodAttributes]::Public -bor [Mono.Cecil.MethodAttributes]::Static -bor [Mono.Cecil.MethodAttributes]::HideBySig
    $method = [Mono.Cecil.MethodDefinition]::new($script:PersistentDataPathOverrideMethodName, $methodAttributes, $Module.TypeSystem.String)
    $method.Body.InitLocals = $true
    $null = $method.Body.Variables.Add([Mono.Cecil.Cil.VariableDefinition]::new($Module.TypeSystem.String))

    $il = $method.Body.GetILProcessor()
    $returnDefaultPathInstruction = $il.Create((Get-PCSOpCode -Name 'Call'), $GetPersistentDataPathMethod)
    foreach ($instruction in @(
            $il.Create((Get-PCSOpCode -Name 'Ldstr'), $script:SaveRootEnvironmentVariableName),
            $il.Create((Get-PCSOpCode -Name 'Call'), $getEnvironmentVariableMethod),
            $il.Create((Get-PCSOpCode -Name 'Stloc_0')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_0')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $isNullOrWhiteSpaceMethod),
            $il.Create((Get-PCSOpCode -Name 'Brtrue_S'), $returnDefaultPathInstruction),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_0')),
            $il.Create((Get-PCSOpCode -Name 'Ret')),
            $returnDefaultPathInstruction,
            $il.Create((Get-PCSOpCode -Name 'Ret'))
        )) {
        $il.Append($instruction)
    }

    $GameConfigType.Methods.Add($method)
    $Module.ImportReference($method)
}

function Ensure-PCSSaveSlotOverrideMethods {
    param(
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.ModuleDefinition]$Module,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$GameConfigType,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.MethodReference]$PersistentDataPathOverrideMethod
    )

    $coreLibrary = $Module.TypeSystem.CoreLibrary
    $environmentTypeReference = [Mono.Cecil.TypeReference]::new('System', 'Environment', $Module, $coreLibrary)
    $pathTypeReference = [Mono.Cecil.TypeReference]::new('System.IO', 'Path', $Module, $coreLibrary)

    $getEnvironmentVariableMethodReference = [Mono.Cecil.MethodReference]::new('GetEnvironmentVariable', $Module.TypeSystem.String, $environmentTypeReference)
    $getEnvironmentVariableMethodReference.HasThis = $false
    $null = $getEnvironmentVariableMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('variable', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $getEnvironmentVariableMethod = $Module.ImportReference($getEnvironmentVariableMethodReference)

    $isNullOrWhiteSpaceMethodReference = [Mono.Cecil.MethodReference]::new('IsNullOrWhiteSpace', $Module.TypeSystem.Boolean, $Module.TypeSystem.String)
    $isNullOrWhiteSpaceMethodReference.HasThis = $false
    $null = $isNullOrWhiteSpaceMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('value', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $isNullOrWhiteSpaceMethod = $Module.ImportReference($isNullOrWhiteSpaceMethodReference)

    $concatMethodReference = [Mono.Cecil.MethodReference]::new('Concat', $Module.TypeSystem.String, $Module.TypeSystem.String)
    $concatMethodReference.HasThis = $false
    $null = $concatMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('str1', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $null = $concatMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('str2', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $concatMethod = $Module.ImportReference($concatMethodReference)

    $combineMethodReference = [Mono.Cecil.MethodReference]::new('Combine', $Module.TypeSystem.String, $pathTypeReference)
    $combineMethodReference.HasThis = $false
    $null = $combineMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path1', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $null = $combineMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path2', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $combineMethod = $Module.ImportReference($combineMethodReference)

    $methodAttributes = [Mono.Cecil.MethodAttributes]::Public -bor [Mono.Cecil.MethodAttributes]::Static -bor [Mono.Cecil.MethodAttributes]::HideBySig

    $slotNameMethod = $GameConfigType.Methods | Where-Object {
        $_.Name -eq $script:SaveSlotNameOverrideMethodName -and $_.Parameters.Count -eq 0
    } | Select-Object -First 1
    if (-not $slotNameMethod) {
        $slotNameMethod = [Mono.Cecil.MethodDefinition]::new($script:SaveSlotNameOverrideMethodName, $methodAttributes, $Module.TypeSystem.String)
        $slotNameMethod.Body.InitLocals = $true
        $null = $slotNameMethod.Body.Variables.Add([Mono.Cecil.Cil.VariableDefinition]::new($Module.TypeSystem.String))

        $il = $slotNameMethod.Body.GetILProcessor()
        $returnDefaultSlotInstruction = $il.Create((Get-PCSOpCode -Name 'Ldstr'), [System.IO.Path]::GetFileNameWithoutExtension($script:DefaultRuntimeSaveFileName))
        foreach ($instruction in @(
                $il.Create((Get-PCSOpCode -Name 'Ldstr'), $script:SaveSlotNameEnvironmentVariableName),
                $il.Create((Get-PCSOpCode -Name 'Call'), $getEnvironmentVariableMethod),
                $il.Create((Get-PCSOpCode -Name 'Stloc_0')),
                $il.Create((Get-PCSOpCode -Name 'Ldloc_0')),
                $il.Create((Get-PCSOpCode -Name 'Call'), $isNullOrWhiteSpaceMethod),
                $il.Create((Get-PCSOpCode -Name 'Brtrue_S'), $returnDefaultSlotInstruction),
                $il.Create((Get-PCSOpCode -Name 'Ldloc_0')),
                $il.Create((Get-PCSOpCode -Name 'Ret')),
                $returnDefaultSlotInstruction,
                $il.Create((Get-PCSOpCode -Name 'Ret'))
            )) {
            $il.Append($instruction)
        }

        $GameConfigType.Methods.Add($slotNameMethod)
    }
    $slotNameMethod = $Module.ImportReference($slotNameMethod)

    $slotFileNameMethod = $GameConfigType.Methods | Where-Object {
        $_.Name -eq $script:SaveSlotFileNameOverrideMethodName -and $_.Parameters.Count -eq 0
    } | Select-Object -First 1
    if (-not $slotFileNameMethod) {
        $slotFileNameMethod = [Mono.Cecil.MethodDefinition]::new($script:SaveSlotFileNameOverrideMethodName, $methodAttributes, $Module.TypeSystem.String)
        $il = $slotFileNameMethod.Body.GetILProcessor()
        foreach ($instruction in @(
                $il.Create((Get-PCSOpCode -Name 'Call'), $slotNameMethod),
                $il.Create((Get-PCSOpCode -Name 'Ldstr'), '.json'),
                $il.Create((Get-PCSOpCode -Name 'Call'), $concatMethod),
                $il.Create((Get-PCSOpCode -Name 'Ret'))
            )) {
            $il.Append($instruction)
        }

        $GameConfigType.Methods.Add($slotFileNameMethod)
    }
    $slotFileNameMethod = $Module.ImportReference($slotFileNameMethod)

    $slotFilePathMethod = $GameConfigType.Methods | Where-Object {
        $_.Name -eq $script:SaveSlotFilePathOverrideMethodName -and $_.Parameters.Count -eq 0
    } | Select-Object -First 1
    if (-not $slotFilePathMethod) {
        $slotFilePathMethod = [Mono.Cecil.MethodDefinition]::new($script:SaveSlotFilePathOverrideMethodName, $methodAttributes, $Module.TypeSystem.String)
        $il = $slotFilePathMethod.Body.GetILProcessor()
        foreach ($instruction in @(
                $il.Create((Get-PCSOpCode -Name 'Call'), $PersistentDataPathOverrideMethod),
                $il.Create((Get-PCSOpCode -Name 'Call'), $slotFileNameMethod),
                $il.Create((Get-PCSOpCode -Name 'Call'), $combineMethod),
                $il.Create((Get-PCSOpCode -Name 'Ret'))
            )) {
            $il.Append($instruction)
        }

        $GameConfigType.Methods.Add($slotFilePathMethod)
    }
    $slotFilePathMethod = $Module.ImportReference($slotFilePathMethod)

    [pscustomobject]@{
        SlotNameMethod     = $slotNameMethod
        SlotFileNameMethod = $slotFileNameMethod
        SlotFilePathMethod = $slotFilePathMethod
    }
}

function Ensure-PCSSaveRequestHook {
    param(
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.ModuleDefinition]$Module,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$GameConfigType,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$SessionType,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.MethodReference]$PersistentDataPathOverrideMethod,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.MethodReference]$SaveSlotNameMethod,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.MethodReference]$SaveWorldDataMethod,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.FieldReference]$SavedDataInstanceField
    )

    $coreLibrary = $Module.TypeSystem.CoreLibrary
    $pathTypeReference = [Mono.Cecil.TypeReference]::new('System.IO', 'Path', $Module, $coreLibrary)
    $fileTypeReference = [Mono.Cecil.TypeReference]::new('System.IO', 'File', $Module, $coreLibrary)

    $combineMethodReference = [Mono.Cecil.MethodReference]::new('Combine', $Module.TypeSystem.String, $pathTypeReference)
    $combineMethodReference.HasThis = $false
    $null = $combineMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path1', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $null = $combineMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path2', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $combineMethod = $Module.ImportReference($combineMethodReference)

    $existsMethodReference = [Mono.Cecil.MethodReference]::new('Exists', $Module.TypeSystem.Boolean, $fileTypeReference)
    $existsMethodReference.HasThis = $false
    $null = $existsMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $existsMethod = $Module.ImportReference($existsMethodReference)

    $deleteMethodReference = [Mono.Cecil.MethodReference]::new('Delete', $Module.TypeSystem.Void, $fileTypeReference)
    $deleteMethodReference.HasThis = $false
    $null = $deleteMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $deleteMethod = $Module.ImportReference($deleteMethodReference)

    $processMethod = $GameConfigType.Methods | Where-Object {
        $_.Name -eq $script:SaveRequestMethodName -and $_.Parameters.Count -eq 1
    } | Select-Object -First 1
    if (-not $processMethod) {
        $privateStaticAttributes = [Mono.Cecil.MethodAttributes]::Public -bor [Mono.Cecil.MethodAttributes]::Static -bor [Mono.Cecil.MethodAttributes]::HideBySig
        $processMethod = [Mono.Cecil.MethodDefinition]::new($script:SaveRequestMethodName, $privateStaticAttributes, $Module.TypeSystem.Void)
        $null = $processMethod.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('state', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.Object))
        $processMethod.Body.InitLocals = $true
        $null = $processMethod.Body.Variables.Add([Mono.Cecil.Cil.VariableDefinition]::new($Module.TypeSystem.String))
        $il = $processMethod.Body.GetILProcessor()
        $returnInstruction = $il.Create((Get-PCSOpCode -Name 'Ret'))
        foreach ($instruction in @(
                $il.Create((Get-PCSOpCode -Name 'Call'), $PersistentDataPathOverrideMethod),
                $il.Create((Get-PCSOpCode -Name 'Ldstr'), $script:SaveRequestFileName),
                $il.Create((Get-PCSOpCode -Name 'Call'), $combineMethod),
                $il.Create((Get-PCSOpCode -Name 'Stloc_0')),
                $il.Create((Get-PCSOpCode -Name 'Ldloc_0')),
                $il.Create((Get-PCSOpCode -Name 'Call'), $existsMethod),
                $il.Create((Get-PCSOpCode -Name 'Brfalse'), $returnInstruction),
                $il.Create((Get-PCSOpCode -Name 'Ldsfld'), $SavedDataInstanceField),
                $il.Create((Get-PCSOpCode -Name 'Call'), $SaveSlotNameMethod),
                $il.Create((Get-PCSOpCode -Name 'Callvirt'), $SaveWorldDataMethod),
                $il.Create((Get-PCSOpCode -Name 'Ldloc_0')),
                $il.Create((Get-PCSOpCode -Name 'Call'), $deleteMethod),
                $returnInstruction
            )) {
            $il.Append($instruction)
        }
        $GameConfigType.Methods.Add($processMethod)
    }
    $processMethod = $Module.ImportReference($processMethod)

    $updateMethod = $SessionType.Methods | Where-Object {
        $_.Name -eq 'Update' -and $_.Parameters.Count -eq 0
    } | Select-Object -First 1
    if (-not $updateMethod) {
        $privateAttributes = [Mono.Cecil.MethodAttributes]::Private -bor [Mono.Cecil.MethodAttributes]::HideBySig
        $updateMethod = [Mono.Cecil.MethodDefinition]::new('Update', $privateAttributes, $Module.TypeSystem.Void)
        $il = $updateMethod.Body.GetILProcessor()
        $il.Append($il.Create((Get-PCSOpCode -Name 'Ldnull')))
        $il.Append($il.Create((Get-PCSOpCode -Name 'Call'), $processMethod))
        $il.Append($il.Create((Get-PCSOpCode -Name 'Ret')))
        $SessionType.Methods.Add($updateMethod)
    }

    $processMethod = $Module.ImportReference($processMethod)
    $hasProcessCall = @($updateMethod.Body.Instructions | Where-Object {
            ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and $_.Operand.FullName -eq $processMethod.FullName
        }).Count -gt 0
    if (-not $hasProcessCall) {
        $il = $updateMethod.Body.GetILProcessor()
        $il.InsertBefore($updateMethod.Body.Instructions[0], $il.Create((Get-PCSOpCode -Name 'Call'), $processMethod))
        $il.InsertBefore($updateMethod.Body.Instructions[0], $il.Create((Get-PCSOpCode -Name 'Ldnull')))
    }

    $Module.ImportReference($processMethod)
}

function Test-PCSSaveRequestPatched {
    param(
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$GameConfigType,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$SessionType,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.MethodReference]$SaveWorldDataMethod
    )

    $processMethod = $GameConfigType.Methods | Where-Object {
        $_.Name -eq $script:SaveRequestMethodName -and $_.Parameters.Count -eq 1
    } | Select-Object -First 1
    $updateMethod = $SessionType.Methods | Where-Object {
        $_.Name -eq 'Update' -and $_.Parameters.Count -eq 0
    } | Select-Object -First 1
    if (-not $processMethod -or -not $updateMethod) {
        return $false
    }

    $processCallsSave = @($processMethod.Body.Instructions | Where-Object {
            ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and $_.Operand.FullName -eq $SaveWorldDataMethod.FullName
        }).Count -gt 0
    $updateCallsProcess = @($updateMethod.Body.Instructions | Where-Object {
            ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and $_.Operand.FullName -eq $processMethod.FullName
        }).Count -gt 0

    return ($processCallsSave -and $updateCallsProcess)
}

function Ensure-PCSIntroSkipHook {
    param(
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.ModuleDefinition]$Module,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$GameConfigType,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$SessionType,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$IntroVideoPlayerType,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.MethodReference]$PersistentDataPathOverrideMethod
    )

    $coreLibrary = $Module.TypeSystem.CoreLibrary
    $pathTypeReference = [Mono.Cecil.TypeReference]::new('System.IO', 'Path', $Module, $coreLibrary)
    $fileTypeReference = [Mono.Cecil.TypeReference]::new('System.IO', 'File', $Module, $coreLibrary)

    $endReachedMethod = Get-PCSNamedMethod -Type $IntroVideoPlayerType -Name 'EndReached' -ParameterCount 1
    $endReachedMethod = $Module.ImportReference($endReachedMethod)
    $introSkipMethod = $IntroVideoPlayerType.Methods | Where-Object {
        $_.Name -eq $script:IntroSkipMethodName -and $_.Parameters.Count -eq 0
    } | Select-Object -First 1
    if (-not $introSkipMethod) {
        $publicAttributes = [Mono.Cecil.MethodAttributes]::Public -bor [Mono.Cecil.MethodAttributes]::HideBySig
        $introSkipMethod = [Mono.Cecil.MethodDefinition]::new($script:IntroSkipMethodName, $publicAttributes, $Module.TypeSystem.Void)
        $il = $introSkipMethod.Body.GetILProcessor()
        $il.Append($il.Create((Get-PCSOpCode -Name 'Ldarg_0')))
        $il.Append($il.Create((Get-PCSOpCode -Name 'Ldnull')))
        $il.Append($il.Create((Get-PCSOpCode -Name 'Call'), $endReachedMethod))
        $il.Append($il.Create((Get-PCSOpCode -Name 'Ret')))
        $IntroVideoPlayerType.Methods.Add($introSkipMethod)
    }
    $introSkipMethod = $Module.ImportReference($introSkipMethod)

    $objectTypeReference = Find-PCSTypeReference -Module $Module -FullName 'UnityEngine.Object'
    $objectType = $objectTypeReference.Resolve()
    $findObjectMethodDefinition = $objectType.Methods | Where-Object {
        $_.Name -eq 'FindObjectOfType' -and $_.IsStatic -and $_.GenericParameters.Count -eq 1 -and $_.Parameters.Count -eq 0
    } | Select-Object -First 1
    if (-not $findObjectMethodDefinition) {
        throw "Generic UnityEngine.Object::FindObjectOfType<T>() was not found."
    }
    $findObjectMethod = [Mono.Cecil.GenericInstanceMethod]::new($Module.ImportReference($findObjectMethodDefinition))
    $null = $findObjectMethod.GenericArguments.Add($Module.ImportReference($IntroVideoPlayerType))
    $findObjectMethod = $Module.ImportReference($findObjectMethod)

    $combineMethodReference = [Mono.Cecil.MethodReference]::new('Combine', $Module.TypeSystem.String, $pathTypeReference)
    $combineMethodReference.HasThis = $false
    $null = $combineMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path1', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $null = $combineMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path2', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $combineMethod = $Module.ImportReference($combineMethodReference)

    $existsMethodReference = [Mono.Cecil.MethodReference]::new('Exists', $Module.TypeSystem.Boolean, $fileTypeReference)
    $existsMethodReference.HasThis = $false
    $null = $existsMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $existsMethod = $Module.ImportReference($existsMethodReference)

    $deleteMethodReference = [Mono.Cecil.MethodReference]::new('Delete', $Module.TypeSystem.Void, $fileTypeReference)
    $deleteMethodReference.HasThis = $false
    $null = $deleteMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $deleteMethod = $Module.ImportReference($deleteMethodReference)

    $processMethod = $GameConfigType.Methods | Where-Object {
        $_.Name -eq $script:IntroSkipRequestMethodName -and $_.Parameters.Count -eq 1
    } | Select-Object -First 1
    if (-not $processMethod) {
        $publicStaticAttributes = [Mono.Cecil.MethodAttributes]::Public -bor [Mono.Cecil.MethodAttributes]::Static -bor [Mono.Cecil.MethodAttributes]::HideBySig
        $processMethod = [Mono.Cecil.MethodDefinition]::new($script:IntroSkipRequestMethodName, $publicStaticAttributes, $Module.TypeSystem.Void)
        $null = $processMethod.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('state', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.Object))
        $processMethod.Body.InitLocals = $true
        $null = $processMethod.Body.Variables.Add([Mono.Cecil.Cil.VariableDefinition]::new($Module.TypeSystem.String))
        $null = $processMethod.Body.Variables.Add([Mono.Cecil.Cil.VariableDefinition]::new($Module.ImportReference($IntroVideoPlayerType)))
        $il = $processMethod.Body.GetILProcessor()
        $returnInstruction = $il.Create((Get-PCSOpCode -Name 'Ret'))
        foreach ($instruction in @(
                $il.Create((Get-PCSOpCode -Name 'Call'), $PersistentDataPathOverrideMethod),
                $il.Create((Get-PCSOpCode -Name 'Ldstr'), $script:IntroSkipRequestFileName),
                $il.Create((Get-PCSOpCode -Name 'Call'), $combineMethod),
                $il.Create((Get-PCSOpCode -Name 'Stloc_0')),
                $il.Create((Get-PCSOpCode -Name 'Ldloc_0')),
                $il.Create((Get-PCSOpCode -Name 'Call'), $existsMethod),
                $il.Create((Get-PCSOpCode -Name 'Brfalse'), $returnInstruction),
                $il.Create((Get-PCSOpCode -Name 'Call'), $findObjectMethod),
                $il.Create((Get-PCSOpCode -Name 'Stloc_1')),
                $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
                $il.Create((Get-PCSOpCode -Name 'Brfalse_S'), $returnInstruction),
                $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
                $il.Create((Get-PCSOpCode -Name 'Callvirt'), $introSkipMethod),
                $il.Create((Get-PCSOpCode -Name 'Ldloc_0')),
                $il.Create((Get-PCSOpCode -Name 'Call'), $deleteMethod),
                $returnInstruction
            )) {
            $il.Append($instruction)
        }
        $GameConfigType.Methods.Add($processMethod)
    }
    $processMethod = $Module.ImportReference($processMethod)

    $updateMethod = $SessionType.Methods | Where-Object {
        $_.Name -eq 'Update' -and $_.Parameters.Count -eq 0
    } | Select-Object -First 1
    if (-not $updateMethod) {
        $privateAttributes = [Mono.Cecil.MethodAttributes]::Private -bor [Mono.Cecil.MethodAttributes]::HideBySig
        $updateMethod = [Mono.Cecil.MethodDefinition]::new('Update', $privateAttributes, $Module.TypeSystem.Void)
        $il = $updateMethod.Body.GetILProcessor()
        $il.Append($il.Create((Get-PCSOpCode -Name 'Ldnull')))
        $il.Append($il.Create((Get-PCSOpCode -Name 'Call'), $processMethod))
        $il.Append($il.Create((Get-PCSOpCode -Name 'Ret')))
        $SessionType.Methods.Add($updateMethod)
    }

    $hasProcessCall = @($updateMethod.Body.Instructions | Where-Object {
            ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and $_.Operand.FullName -eq $processMethod.FullName
        }).Count -gt 0
    if (-not $hasProcessCall) {
        $il = $updateMethod.Body.GetILProcessor()
        $il.InsertBefore($updateMethod.Body.Instructions[0], $il.Create((Get-PCSOpCode -Name 'Call'), $processMethod))
        $il.InsertBefore($updateMethod.Body.Instructions[0], $il.Create((Get-PCSOpCode -Name 'Ldnull')))
    }

    $processMethod
}

function Ensure-PCSNewSaveRequestHook {
    param(
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.ModuleDefinition]$Module,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$GameConfigType,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$IntroType,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.MethodReference]$PersistentDataPathOverrideMethod,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.MethodReference]$SaveSlotNameMethod
    )

    $coreLibrary = $Module.TypeSystem.CoreLibrary
    $pathTypeReference = [Mono.Cecil.TypeReference]::new('System.IO', 'Path', $Module, $coreLibrary)
    $fileTypeReference = [Mono.Cecil.TypeReference]::new('System.IO', 'File', $Module, $coreLibrary)
    $saveFilesCreateNewType = Find-PCSTypeDefinition -Module $Module -FullName 'SpaceCraft.SaveFilesCreateNew'
    $jsonableGameStateType = Find-PCSTypeDefinition -Module $Module -FullName 'SpaceCraft.JsonableGameState'
    $planetListType = Find-PCSTypeDefinition -Module $Module -FullName 'SpaceCraft.PlanetList'
    $planetDataType = Find-PCSTypeDefinition -Module $Module -FullName 'SpaceCraft.PlanetData'
    $gameSettingsUiType = Find-PCSTypeDefinition -Module $Module -FullName 'SpaceCraft.GameSettingsUi'
    $saveFilesSelectorType = Find-PCSTypeDefinition -Module $Module -FullName 'SpaceCraft.SaveFilesSelector'
    $jsonExportType = Find-PCSTypeDefinition -Module $Module -FullName 'SpaceCraft.JSONExport'
    $managersType = Find-PCSTypeDefinition -Module $Module -FullName 'SpaceCraft.Managers'
    $staticDataHandlerType = Find-PCSTypeDefinition -Module $Module -FullName 'SpaceCraft.StaticDataHandler'
    $objectTypeReference = Find-PCSTypeReference -Module $Module -FullName 'UnityEngine.Object'
    $tmpInputFieldTypeReference = Find-PCSTypeReference -Module $Module -FullName 'TMPro.TMP_InputField'
    $objectType = $objectTypeReference.Resolve()

    $combineMethodReference = [Mono.Cecil.MethodReference]::new('Combine', $Module.TypeSystem.String, $pathTypeReference)
    $combineMethodReference.HasThis = $false
    $null = $combineMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path1', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $null = $combineMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path2', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $combineMethod = $Module.ImportReference($combineMethodReference)

    $existsMethodReference = [Mono.Cecil.MethodReference]::new('Exists', $Module.TypeSystem.Boolean, $fileTypeReference)
    $existsMethodReference.HasThis = $false
    $null = $existsMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $existsMethod = $Module.ImportReference($existsMethodReference)

    $deleteMethodReference = [Mono.Cecil.MethodReference]::new('Delete', $Module.TypeSystem.Void, $fileTypeReference)
    $deleteMethodReference.HasThis = $false
    $null = $deleteMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $deleteMethod = $Module.ImportReference($deleteMethodReference)

    $readAllLinesMethodReference = [Mono.Cecil.MethodReference]::new('ReadAllLines', [Mono.Cecil.ArrayType]::new($Module.TypeSystem.String), $fileTypeReference)
    $readAllLinesMethodReference.HasThis = $false
    $null = $readAllLinesMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $readAllLinesMethod = $Module.ImportReference($readAllLinesMethodReference)

    $isNullOrWhiteSpaceMethodReference = [Mono.Cecil.MethodReference]::new('IsNullOrWhiteSpace', $Module.TypeSystem.Boolean, $Module.TypeSystem.String)
    $isNullOrWhiteSpaceMethodReference.HasThis = $false
    $null = $isNullOrWhiteSpaceMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('value', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $isNullOrWhiteSpaceMethod = $Module.ImportReference($isNullOrWhiteSpaceMethodReference)

    $booleanParseMethodReference = [Mono.Cecil.MethodReference]::new('Parse', $Module.TypeSystem.Boolean, $Module.TypeSystem.Boolean)
    $booleanParseMethodReference.HasThis = $false
    $null = $booleanParseMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('value', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $booleanParseMethod = $Module.ImportReference($booleanParseMethodReference)

    $doubleParseMethodReference = [Mono.Cecil.MethodReference]::new('Parse', $Module.TypeSystem.Double, $Module.TypeSystem.Double)
    $doubleParseMethodReference.HasThis = $false
    $null = $doubleParseMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('value', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $doubleParseMethod = $Module.ImportReference($doubleParseMethodReference)

    $uint32ParseMethodReference = [Mono.Cecil.MethodReference]::new('Parse', $Module.TypeSystem.UInt32, $Module.TypeSystem.UInt32)
    $uint32ParseMethodReference.HasThis = $false
    $null = $uint32ParseMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('value', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $uint32ParseMethod = $Module.ImportReference($uint32ParseMethodReference)

    $findSaveFilesSelectorMethodDefinition = $objectType.Methods | Where-Object {
        $_.Name -eq 'FindObjectOfType' -and $_.IsStatic -and $_.GenericParameters.Count -eq 1 -and $_.Parameters.Count -eq 0
    } | Select-Object -First 1
    if (-not $findSaveFilesSelectorMethodDefinition) {
        throw "Generic UnityEngine.Object::FindObjectOfType<T>() was not found."
    }
    $findSaveFilesSelectorMethod = [Mono.Cecil.GenericInstanceMethod]::new($Module.ImportReference($findSaveFilesSelectorMethodDefinition))
    $null = $findSaveFilesSelectorMethod.GenericArguments.Add($Module.ImportReference($saveFilesSelectorType))
    $findSaveFilesSelectorMethod = $Module.ImportReference($findSaveFilesSelectorMethod)

    $findObjectMethodDefinition = $objectType.Methods | Where-Object {
        $_.Name -eq 'FindObjectOfType' -and $_.IsStatic -and $_.GenericParameters.Count -eq 1 -and $_.Parameters.Count -eq 1 -and $_.Parameters[0].ParameterType.FullName -eq 'System.Boolean'
    } | Select-Object -First 1
    if (-not $findObjectMethodDefinition) {
        throw "Generic UnityEngine.Object::FindObjectOfType<T>(bool) was not found."
    }
    $findSaveFilesCreateNewMethod = [Mono.Cecil.GenericInstanceMethod]::new($Module.ImportReference($findObjectMethodDefinition))
    $null = $findSaveFilesCreateNewMethod.GenericArguments.Add($Module.ImportReference($saveFilesCreateNewType))
    $findSaveFilesCreateNewMethod = $Module.ImportReference($findSaveFilesCreateNewMethod)

    $instantiateMethodDefinition = $objectType.Methods | Where-Object {
        $_.Name -eq 'Instantiate' -and $_.IsStatic -and $_.GenericParameters.Count -eq 1 -and $_.Parameters.Count -eq 1
    } | Select-Object -First 1
    if (-not $instantiateMethodDefinition) {
        throw "Generic UnityEngine.Object::Instantiate<T>(T) was not found."
    }
    $instantiateJsonableGameStateMethod = [Mono.Cecil.GenericInstanceMethod]::new($Module.ImportReference($instantiateMethodDefinition))
    $null = $instantiateJsonableGameStateMethod.GenericArguments.Add($Module.ImportReference($jsonableGameStateType))
    $instantiateJsonableGameStateMethod = $Module.ImportReference($instantiateJsonableGameStateMethod)

    $getManagerMethodDefinition = $managersType.Methods | Where-Object {
        $_.Name -eq 'GetManager' -and $_.IsStatic -and $_.GenericParameters.Count -eq 1 -and $_.Parameters.Count -eq 0
    } | Select-Object -First 1
    if (-not $getManagerMethodDefinition) {
        throw "Generic SpaceCraft.Managers::GetManager<T>() was not found."
    }
    $getStaticDataHandlerMethod = [Mono.Cecil.GenericInstanceMethod]::new($Module.ImportReference($getManagerMethodDefinition))
    $null = $getStaticDataHandlerMethod.GenericArguments.Add($Module.ImportReference($staticDataHandlerType))
    $getStaticDataHandlerMethod = $Module.ImportReference($getStaticDataHandlerMethod)

    $loadStaticDataMethod = $Module.ImportReference((Get-PCSNamedMethod -Type $staticDataHandlerType -Name 'LoadStaticData' -ParameterCount 0))
    $getPlanetFromIdMethod = $Module.ImportReference((Get-PCSNamedMethod -Type $planetListType -Name 'GetPlanetFromId' -ParameterCount 1))
    $getDefaultPlanetMethod = $Module.ImportReference((Get-PCSNamedMethod -Type $planetListType -Name 'GetDefaultPlanet' -ParameterCount 0))
    $getPlanetIdMethod = $Module.ImportReference((Get-PCSNamedMethod -Type $planetDataType -Name 'GetPlanetId' -ParameterCount 0))
    $createNewSaveFileMethod = $Module.ImportReference((Get-PCSNamedMethod -Type $jsonExportType -Name 'CreateNewSaveFile' -ParameterCount 3))
    $createNewFileMethod = $Module.ImportReference((Get-PCSNamedMethod -Type $saveFilesCreateNewType -Name 'CreateNewFile' -ParameterCount 0))
    $selectedSaveFileMethod = $Module.ImportReference((Get-PCSNamedMethod -Type $saveFilesSelectorType -Name 'SelectedSaveFile' -ParameterCount 1))
    $openNewFileMethod = $Module.ImportReference((Get-PCSNamedMethod -Type $saveFilesSelectorType -Name 'OpenNewFile' -ParameterCount 0))
    $convertStringsToEnumMethod = $Module.ImportReference((Get-PCSNamedMethod -Type $jsonableGameStateType -Name 'ConvertStringsToEnum' -ParameterCount 0))
    $randomizeWorldSeedMethod = $Module.ImportReference((Get-PCSNamedMethod -Type $jsonableGameStateType -Name 'RandomizeWorldSeed' -ParameterCount 0))
    $setTextMethodReference = [Mono.Cecil.MethodReference]::new('set_text', $Module.TypeSystem.Void, $tmpInputFieldTypeReference)
    $setTextMethodReference.HasThis = $true
    $null = $setTextMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('value', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.String))
    $setTextMethod = $Module.ImportReference($setTextMethodReference)

    $standardGameSettingPresetField = $Module.ImportReference(($saveFilesCreateNewType.Fields | Where-Object { $_.Name -eq 'standardGameSettingPreset' } | Select-Object -First 1))
    $planetsField = $Module.ImportReference(($saveFilesCreateNewType.Fields | Where-Object { $_.Name -eq 'planets' } | Select-Object -First 1))
    $saveFilesSelectorField = $Module.ImportReference(($saveFilesCreateNewType.Fields | Where-Object { $_.Name -eq 'saveFilesSelector' } | Select-Object -First 1))
    $jsonableGameSettingsField = $Module.ImportReference(($saveFilesCreateNewType.Fields | Where-Object { $_.Name -eq '_jsonableGameSettings' } | Select-Object -First 1))
    $fileNameField = $Module.ImportReference(($saveFilesCreateNewType.Fields | Where-Object { $_.Name -eq '_fileName' } | Select-Object -First 1))
    $newNameInputField = $Module.ImportReference(($saveFilesCreateNewType.Fields | Where-Object { $_.Name -eq 'newNameInput' } | Select-Object -First 1))

    $gameStateFields = @{}
    foreach ($fieldName in @(
            'saveDisplayName',
            'planetId',
            'mode',
            'dyingConsequencesLabel',
            'startLocationLabel',
            'gameStartLocation',
            'freeCraft',
            'unlockedEverything',
            'unlockedAutocrafter',
            'unlockedDrones',
            'unlockedOreExtrators',
            'unlockedSpaceTrading',
            'unlockedTeleporters',
            'randomizeMineables',
            'modifierTerraformationPace',
            'modifierPowerConsumption',
            'modifierGaugeDrain',
            'modifierMeteoOccurence',
            'modifierMultiplayerTerraformationFactor',
            'hasPlayedIntro',
            'worldSeed'
        )) {
        $field = $jsonableGameStateType.Fields | Where-Object { $_.Name -eq $fieldName } | Select-Object -First 1
        if (-not $field) {
            throw "Field '$($jsonableGameStateType.FullName)::$fieldName' was not found."
        }
        $gameStateFields[$fieldName] = $Module.ImportReference($field)
    }

    $processMethod = $GameConfigType.Methods | Where-Object {
        $_.Name -eq $script:NewSaveRequestMethodName -and $_.Parameters.Count -eq 1
    } | Select-Object -First 1
    if (-not $processMethod) {
        $publicStaticAttributes = [Mono.Cecil.MethodAttributes]::Public -bor [Mono.Cecil.MethodAttributes]::Static -bor [Mono.Cecil.MethodAttributes]::HideBySig
        $processMethod = [Mono.Cecil.MethodDefinition]::new($script:NewSaveRequestMethodName, $publicStaticAttributes, $Module.TypeSystem.Void)
        $null = $processMethod.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('state', [System.Reflection.ParameterAttributes]::None, $Module.TypeSystem.Object))
        $GameConfigType.Methods.Add($processMethod)
    }
    $processMethod.Body.InitLocals = $true
    $processMethod.Body.Instructions.Clear()
    $processMethod.Body.ExceptionHandlers.Clear()
    $processMethod.Body.Variables.Clear()
    $null = $processMethod.Body.Variables.Add([Mono.Cecil.Cil.VariableDefinition]::new($Module.TypeSystem.String))
    $null = $processMethod.Body.Variables.Add([Mono.Cecil.Cil.VariableDefinition]::new([Mono.Cecil.ArrayType]::new($Module.TypeSystem.String)))
    $null = $processMethod.Body.Variables.Add([Mono.Cecil.Cil.VariableDefinition]::new($Module.ImportReference($saveFilesCreateNewType)))
    $null = $processMethod.Body.Variables.Add([Mono.Cecil.Cil.VariableDefinition]::new($Module.ImportReference($jsonableGameStateType)))
    $null = $processMethod.Body.Variables.Add([Mono.Cecil.Cil.VariableDefinition]::new($Module.ImportReference($planetDataType)))
    $null = $processMethod.Body.Variables.Add([Mono.Cecil.Cil.VariableDefinition]::new($Module.TypeSystem.String))

    $il = $processMethod.Body.GetILProcessor()
    $returnInstruction = $il.Create((Get-PCSOpCode -Name 'Ret'))
    $planetResolvedInstruction = $il.Create((Get-PCSOpCode -Name 'Nop'))
    $loadWorldSeedInstruction = $il.Create((Get-PCSOpCode -Name 'Ldloc_3'))
    $afterWorldSeedInstruction = $il.Create((Get-PCSOpCode -Name 'Ldloc_3'))
    $requestMissingBranch = $il.Create((Get-PCSOpCode -Name 'Brfalse'), $planetResolvedInstruction)
    $requestMissingBranch.Operand = $returnInstruction
    $newSaveUiMissingBranch = $il.Create((Get-PCSOpCode -Name 'Brfalse'), $planetResolvedInstruction)
    $newSaveUiMissingBranch.Operand = $returnInstruction
    $skipOpenNewFileInstruction = $il.Create((Get-PCSOpCode -Name 'Pop'))
    $afterOpenNewFileInstruction = $il.Create((Get-PCSOpCode -Name 'Nop'))

    foreach ($instruction in @(
            $il.Create((Get-PCSOpCode -Name 'Call'), $PersistentDataPathOverrideMethod),
            $il.Create((Get-PCSOpCode -Name 'Ldstr'), $script:NewSaveRequestFileName),
            $il.Create((Get-PCSOpCode -Name 'Call'), $combineMethod),
            $il.Create((Get-PCSOpCode -Name 'Stloc_0')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_0')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $existsMethod),
            $requestMissingBranch,
            $il.Create((Get-PCSOpCode -Name 'Call'), $findSaveFilesSelectorMethod),
            $il.Create((Get-PCSOpCode -Name 'Dup')),
            $il.Create((Get-PCSOpCode -Name 'Brfalse'), $skipOpenNewFileInstruction),
            $il.Create((Get-PCSOpCode -Name 'Callvirt'), $openNewFileMethod),
            $il.Create((Get-PCSOpCode -Name 'Br'), $afterOpenNewFileInstruction),
            $skipOpenNewFileInstruction,
            $afterOpenNewFileInstruction,
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_1')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $findSaveFilesCreateNewMethod),
            $il.Create((Get-PCSOpCode -Name 'Stloc_2')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_2')),
            $newSaveUiMissingBranch,
            $il.Create((Get-PCSOpCode -Name 'Ldloc_0')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $readAllLinesMethod),
            $il.Create((Get-PCSOpCode -Name 'Stloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldlen')),
            $il.Create((Get-PCSOpCode -Name 'Conv_I4')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_S'), [sbyte]20),
            $il.Create((Get-PCSOpCode -Name 'Blt'), $returnInstruction),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_2')),
            $il.Create((Get-PCSOpCode -Name 'Ldfld'), $standardGameSettingPresetField),
            $il.Create((Get-PCSOpCode -Name 'Call'), $instantiateJsonableGameStateMethod),
            $il.Create((Get-PCSOpCode -Name 'Stloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_0')),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['saveDisplayName']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_2')),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['mode']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_4')),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['dyingConsequencesLabel']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['gameStartLocation']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_5')),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $booleanParseMethod),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['freeCraft']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_6')),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $booleanParseMethod),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['unlockedEverything']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_7')),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $booleanParseMethod),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['unlockedAutocrafter']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_8')),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $booleanParseMethod),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['unlockedDrones']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_S'), [sbyte]9),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $booleanParseMethod),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['unlockedOreExtrators']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_S'), [sbyte]10),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $booleanParseMethod),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['unlockedSpaceTrading']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_S'), [sbyte]11),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $booleanParseMethod),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['unlockedTeleporters']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_S'), [sbyte]12),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $booleanParseMethod),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['randomizeMineables']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_S'), [sbyte]13),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $doubleParseMethod),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['modifierTerraformationPace']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_S'), [sbyte]14),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $doubleParseMethod),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['modifierPowerConsumption']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_S'), [sbyte]15),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $doubleParseMethod),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['modifierGaugeDrain']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_S'), [sbyte]16),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $doubleParseMethod),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['modifierMeteoOccurence']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_S'), [sbyte]17),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $doubleParseMethod),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['modifierMultiplayerTerraformationFactor']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_S'), [sbyte]18),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Call'), $booleanParseMethod),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['hasPlayedIntro']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_S'), [sbyte]19),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Stloc_S'), $processMethod.Body.Variables[5]),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['planetId']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_1')),
            $il.Create((Get-PCSOpCode -Name 'Ldc_I4_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldelem_Ref')),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['gameStartLocation']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Ldfld'), $gameStateFields['gameStartLocation']),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['startLocationLabel']),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_S'), $processMethod.Body.Variables[5]),
            $il.Create((Get-PCSOpCode -Name 'Call'), $isNullOrWhiteSpaceMethod),
            $il.Create((Get-PCSOpCode -Name 'Brfalse'), $loadWorldSeedInstruction),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
            $il.Create((Get-PCSOpCode -Name 'Callvirt'), $randomizeWorldSeedMethod),
            $il.Create((Get-PCSOpCode -Name 'Br'), $afterWorldSeedInstruction),
            $loadWorldSeedInstruction,
            $il.Create((Get-PCSOpCode -Name 'Ldloc_S'), $processMethod.Body.Variables[5]),
            $il.Create((Get-PCSOpCode -Name 'Call'), $uint32ParseMethod),
            $il.Create((Get-PCSOpCode -Name 'Stfld'), $gameStateFields['worldSeed']),
            $afterWorldSeedInstruction,
            $il.Create((Get-PCSOpCode -Name 'Callvirt'), $convertStringsToEnumMethod),
        $il.Create((Get-PCSOpCode -Name 'Ldloc_2')),
        $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
        $il.Create((Get-PCSOpCode -Name 'Stfld'), $jsonableGameSettingsField),
        $il.Create((Get-PCSOpCode -Name 'Ldloc_2')),
        $il.Create((Get-PCSOpCode -Name 'Call'), $SaveSlotNameMethod),
        $il.Create((Get-PCSOpCode -Name 'Stfld'), $fileNameField),
            $il.Create((Get-PCSOpCode -Name 'Ldloc_2')),
        $il.Create((Get-PCSOpCode -Name 'Ldfld'), $newNameInputField),
        $il.Create((Get-PCSOpCode -Name 'Ldloc_3')),
        $il.Create((Get-PCSOpCode -Name 'Ldfld'), $gameStateFields['saveDisplayName']),
        $il.Create((Get-PCSOpCode -Name 'Callvirt'), $setTextMethod),
        $il.Create((Get-PCSOpCode -Name 'Ldloc_2')),
        $il.Create((Get-PCSOpCode -Name 'Callvirt'), $createNewFileMethod),
        $il.Create((Get-PCSOpCode -Name 'Ldloc_0')),
        $il.Create((Get-PCSOpCode -Name 'Call'), $deleteMethod),
        $returnInstruction
    )) {
        $il.Append($instruction)
    }

    $processMethod = $Module.ImportReference($processMethod)
    $updateMethod = $IntroType.Methods | Where-Object {
        $_.Name -eq 'Update' -and $_.Parameters.Count -eq 0
    } | Select-Object -First 1
    if (-not $updateMethod) {
        $privateAttributes = [Mono.Cecil.MethodAttributes]::Private -bor [Mono.Cecil.MethodAttributes]::HideBySig
        $updateMethod = [Mono.Cecil.MethodDefinition]::new('Update', $privateAttributes, $Module.TypeSystem.Void)
        $il = $updateMethod.Body.GetILProcessor()
        $il.Append($il.Create((Get-PCSOpCode -Name 'Ldnull')))
        $il.Append($il.Create((Get-PCSOpCode -Name 'Call'), $processMethod))
        $il.Append($il.Create((Get-PCSOpCode -Name 'Ret')))
        $SessionType.Methods.Add($updateMethod)
    }

    $hasProcessCall = @($updateMethod.Body.Instructions | Where-Object {
            ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and $_.Operand.FullName -eq $processMethod.FullName
        }).Count -gt 0
    if (-not $hasProcessCall) {
        $il = $updateMethod.Body.GetILProcessor()
        $il.InsertBefore($updateMethod.Body.Instructions[0], $il.Create((Get-PCSOpCode -Name 'Call'), $processMethod))
        $il.InsertBefore($updateMethod.Body.Instructions[0], $il.Create((Get-PCSOpCode -Name 'Ldnull')))
    }

    $processMethod
}

function Test-PCSIntroSkipRequestPatched {
    param(
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$GameConfigType,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$SessionType,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$IntroVideoPlayerType
    )

    $introSkipMethod = $IntroVideoPlayerType.Methods | Where-Object {
        $_.Name -eq $script:IntroSkipMethodName -and $_.Parameters.Count -eq 0
    } | Select-Object -First 1
    $processMethod = $GameConfigType.Methods | Where-Object {
        $_.Name -eq $script:IntroSkipRequestMethodName -and $_.Parameters.Count -eq 1
    } | Select-Object -First 1
    $updateMethod = $SessionType.Methods | Where-Object {
        $_.Name -eq 'Update' -and $_.Parameters.Count -eq 0
    } | Select-Object -First 1
    if (-not $introSkipMethod -or -not $processMethod -or -not $updateMethod) {
        return $false
    }

    $introSkipCallsEndReached = @($introSkipMethod.Body.Instructions | Where-Object {
            ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and $_.Operand.Name -eq 'EndReached'
        }).Count -gt 0
    $processCallsIntroSkip = @($processMethod.Body.Instructions | Where-Object {
            ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and $_.Operand.FullName -eq $introSkipMethod.FullName
        }).Count -gt 0
    $processChecksMarker = @($processMethod.Body.Instructions | Where-Object {
            $_.OpCode.Name -eq 'ldstr' -and $_.Operand -eq $script:IntroSkipRequestFileName
        }).Count -gt 0
    $processFindsIntro = @($processMethod.Body.Instructions | Where-Object {
            ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and $_.Operand.Name -eq 'FindObjectOfType'
        }).Count -gt 0
    $processDeletesMarker = @($processMethod.Body.Instructions | Where-Object {
            ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and $_.Operand.Name -eq 'Delete'
        }).Count -gt 0
    $updateCallsProcess = @($updateMethod.Body.Instructions | Where-Object {
            ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and $_.Operand.FullName -eq $processMethod.FullName
        }).Count -gt 0

    return ($introSkipCallsEndReached -and $processCallsIntroSkip -and $processChecksMarker -and $processFindsIntro -and $processDeletesMarker -and $updateCallsProcess)
}

function Test-PCSNewSaveRequestPatched {
    param(
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$GameConfigType,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$IntroType
    )

    $processMethod = $GameConfigType.Methods | Where-Object {
        $_.Name -eq $script:NewSaveRequestMethodName -and $_.Parameters.Count -eq 1
    } | Select-Object -First 1
    $updateMethod = $IntroType.Methods | Where-Object {
        $_.Name -eq 'Update' -and $_.Parameters.Count -eq 0
    } | Select-Object -First 1
    if (-not $processMethod -or -not $updateMethod) {
        return $false
    }

    $processChecksMarker = @($processMethod.Body.Instructions | Where-Object {
            $_.OpCode.Name -eq 'ldstr' -and $_.Operand -eq $script:NewSaveRequestFileName
        }).Count -gt 0
    $processCallsNewSave = @($processMethod.Body.Instructions | Where-Object {
            ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and ($_.Operand.Name -eq 'CreateNewSaveFile' -or $_.Operand.Name -eq 'CreateNewFile')
        }).Count -gt 0
    $processReadsRequest = @($processMethod.Body.Instructions | Where-Object {
            ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and $_.Operand.Name -eq 'ReadAllLines'
        }).Count -gt 0
    $processDeletesMarker = @($processMethod.Body.Instructions | Where-Object {
            ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and $_.Operand.Name -eq 'Delete'
        }).Count -gt 0
    $updateCallsProcess = @($updateMethod.Body.Instructions | Where-Object {
            ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and $_.Operand.FullName -eq $processMethod.FullName
        }).Count -gt 0

    return ($processChecksMarker -and $processCallsNewSave -and $processReadsRequest -and $processDeletesMarker -and $updateCallsProcess)
}

function Test-PCSPersistentDataPathRedirectPatched {
    param(
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.ModuleDefinition]$Module,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.TypeDefinition]$GameConfigType,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.MethodReference]$GetPersistentDataPathMethod
    )

    $overrideMethod = $GameConfigType.Methods | Where-Object {
        $_.Name -eq $script:PersistentDataPathOverrideMethodName -and $_.Parameters.Count -eq 0
    } | Select-Object -First 1
    if (-not $overrideMethod) {
        return $false
    }

    $redirectedCallCount = 0
    foreach ($type in Get-PCSAllTypeDefinitions -Module $Module) {
        foreach ($method in $type.Methods) {
            if (-not $method.HasBody) {
                continue
            }

            foreach ($instruction in $method.Body.Instructions) {
                if ($instruction.OpCode.Name -ne 'call' -and $instruction.OpCode.Name -ne 'callvirt') {
                    continue
                }

                if (-not $instruction.Operand) {
                    continue
                }

                if ($instruction.Operand.FullName -eq $overrideMethod.FullName) {
                    $redirectedCallCount++
                    continue
                }

                if ($method.FullName -ne $overrideMethod.FullName -and $instruction.Operand.FullName -eq $GetPersistentDataPathMethod.FullName) {
                    return $false
                }
            }
        }
    }

    return ($redirectedCallCount -gt 0)
}

function Set-PCSPersistentDataPathCallSites {
    param(
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.ModuleDefinition]$Module,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.MethodReference]$GetPersistentDataPathMethod,
        [Parameter(Mandatory = $true)]
        [Mono.Cecil.MethodReference]$OverrideMethod
    )

    $updatedCallCount = 0
    foreach ($type in Get-PCSAllTypeDefinitions -Module $Module) {
        foreach ($method in $type.Methods) {
            if (-not $method.HasBody -or $method.FullName -eq $OverrideMethod.FullName) {
                continue
            }

            foreach ($instruction in $method.Body.Instructions) {
                if (($instruction.OpCode.Name -eq 'call' -or $instruction.OpCode.Name -eq 'callvirt') -and $instruction.Operand -and $instruction.Operand.FullName -eq $GetPersistentDataPathMethod.FullName) {
                    $instruction.OpCode = Get-PCSOpCode -Name 'Call'
                    $instruction.Operand = $OverrideMethod
                    $updatedCallCount++
                }
            }
        }
    }

    return $updatedCallCount
}

function Get-PCSAssemblyPatchState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AssemblyPath
    )

    Import-PCSMonoCecil

    $resolvedAssemblyPath = Resolve-PCSPath -Path $AssemblyPath
    $resolver = [Mono.Cecil.DefaultAssemblyResolver]::new()
    $resolver.AddSearchDirectory((Split-Path -Parent $resolvedAssemblyPath))

    $readerParameters = [Mono.Cecil.ReaderParameters]::new()
    $readerParameters.AssemblyResolver = $resolver
    $readerParameters.InMemory = $true

    $assemblyBytes = [System.IO.File]::ReadAllBytes($resolvedAssemblyPath)
    $assemblyStream = [System.IO.MemoryStream]::new($assemblyBytes, $false)
    try {
        $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($assemblyStream, $readerParameters)
        $module = $assembly.MainModule

        $introType = Find-PCSTypeDefinition -Module $module -FullName 'SpaceCraft.Intro'
        $chatType = Find-PCSTypeDefinition -Module $module -FullName 'SpaceCraft.UiWindowChat'
        $sessionType = Find-PCSTypeDefinition -Module $module -FullName 'SpaceCraft.SessionController'
        $gameConfigType = Find-PCSTypeDefinition -Module $module -FullName 'SpaceCraft.GameConfig'
        $introVideoPlayerType = Find-PCSTypeDefinition -Module $module -FullName 'SpaceCraft.IntroVideoPlayer'
        $saveFilesSelectorType = Find-PCSTypeDefinition -Module $module -FullName 'SpaceCraft.SaveFilesSelector'
        $applicationTypeReference = Find-PCSTypeReference -Module $module -FullName 'UnityEngine.Application'

        $introStart = Get-PCSNamedMethod -Type $introType -Name 'Start' -ParameterCount 0
        $introUpdate = Get-PCSNamedMethod -Type $introType -Name 'Update' -ParameterCount 0
        $chatMethod = Get-PCSNamedMethod -Type $chatType -Name 'OnTextReceived' -ParameterCount 2
        $autosaveMethod = Get-PCSNamedMethod -Type $sessionType -Name 'StartHiddenAutoSave' -ParameterCount 0
        $getPersistentDataPathMethodReference = [Mono.Cecil.MethodReference]::new('get_persistentDataPath', $module.TypeSystem.String, $applicationTypeReference)
        $getPersistentDataPathMethodReference.HasThis = $false
        $getPersistentDataPathMethod = $module.ImportReference($getPersistentDataPathMethodReference)
        $saveWorldDataMethod = $module.ImportReference((Get-PCSNamedMethod -Type (Find-PCSTypeDefinition -Module $module -FullName 'SpaceCraft.SavedDataHandler') -Name 'SaveWorldData' -ParameterCount 1))
        $selectedSaveFileMethod = $module.ImportReference((Get-PCSNamedMethod -Type $saveFilesSelectorType -Name 'SelectedSaveFile' -ParameterCount 1))
        $saveSlotNameMethod = $gameConfigType.Methods | Where-Object {
            $_.Name -eq $script:SaveSlotNameOverrideMethodName -and $_.Parameters.Count -eq 0
        } | Select-Object -First 1
        $saveSlotFilePathMethod = $gameConfigType.Methods | Where-Object {
            $_.Name -eq $script:SaveSlotFilePathOverrideMethodName -and $_.Parameters.Count -eq 0
        } | Select-Object -First 1

        $introUsesConfiguredSavePath = @($introStart.Body.Instructions | Where-Object {
                ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and (
                    ($saveSlotFilePathMethod -and $_.Operand.FullName -eq $saveSlotFilePathMethod.FullName) -or
                    $_.Operand.FullName -eq $selectedSaveFileMethod.FullName
                )
            }).Count -ge 2
        $introUsesLegacySaveStrings = @($introStart.Body.Instructions | Where-Object {
                $_.OpCode.Name -eq 'ldstr' -and ($_.Operand -eq 'Server-1.json' -or $_.Operand -eq 'Server-1')
            }).Count -ge 2
        $introPatched = ($introUsesConfiguredSavePath -or $introUsesLegacySaveStrings)

        $chatUsesConfiguredSaveSlot = @($chatMethod.Body.Instructions | Where-Object {
                ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and $saveSlotNameMethod -and $_.Operand.FullName -eq $saveSlotNameMethod.FullName
            }).Count -gt 0
        $chatUsesLegacySaveSlot = @($chatMethod.Body.Instructions | Where-Object {
                $_.OpCode.Name -eq 'ldstr' -and $_.Operand -eq 'Server-1'
            }).Count -gt 0
        $chatCallsSave = @($chatMethod.Body.Instructions | Where-Object {
                ($_.OpCode.Name -eq 'call' -or $_.OpCode.Name -eq 'callvirt') -and $_.Operand -and $_.Operand.FullName -eq $saveWorldDataMethod.FullName
            }).Count -gt 0
        $chatPatched = $chatCallsSave -and ($chatUsesConfiguredSaveSlot -or $chatUsesLegacySaveSlot)

        $autosavePatched = $false
        for ($i = 0; $i -lt $autosaveMethod.Body.Instructions.Count; $i++) {
            $instruction = $autosaveMethod.Body.Instructions[$i]
            if ($instruction.OpCode.Name -eq 'ldc.r4' -and [Math]::Abs([single]$instruction.Operand - 60.0) -lt 0.001) {
                $autosavePatched = $true
                break
            }
        }

        $persistentDataPathRedirectPatched = Test-PCSPersistentDataPathRedirectPatched -Module $module -GameConfigType $gameConfigType -GetPersistentDataPathMethod $getPersistentDataPathMethod
        $saveRequestPatched = Test-PCSSaveRequestPatched -GameConfigType $gameConfigType -SessionType $sessionType -SaveWorldDataMethod $saveWorldDataMethod
        $introSkipRequestPatched = Test-PCSIntroSkipRequestPatched -GameConfigType $gameConfigType -SessionType $sessionType -IntroVideoPlayerType $introVideoPlayerType
        $newSaveRequestPatched = Test-PCSNewSaveRequestPatched -GameConfigType $gameConfigType -IntroType $introType

        [ordered]@{
            PersistentDataPathRedirectPatched = $persistentDataPathRedirectPatched
            SaveRequestPatched                 = $saveRequestPatched
            IntroSkipRequestPatched             = $introSkipRequestPatched
            NewSaveRequestPatched             = $newSaveRequestPatched
            IntroAutoLoadPatched              = $introPatched
            ChatSavePatched                   = $chatPatched
            HiddenAutosavePatched             = $autosavePatched
            FullyPatched                      = ($persistentDataPathRedirectPatched -and $saveRequestPatched -and $introSkipRequestPatched -and $newSaveRequestPatched -and $introPatched -and $chatPatched -and $autosavePatched)
        }
    }
    finally {
        if ($assembly -is [System.IDisposable]) {
            $assembly.Dispose()
        }
        $assemblyStream.Dispose()
    }
}

function Invoke-PCSPatchAssembly {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AssemblyPath,
        [string]$OutputPath
    )

    $resolvedAssemblyPath = Resolve-PCSPath -Path $AssemblyPath
    if (-not $PSBoundParameters.ContainsKey('OutputPath')) {
        $powerShellHostPath = Get-PCSPowerShellHostPath

        $moduleManifestPath = Join-Path $PSScriptRoot 'PlanetCrafterServer.psd1'
        $backupPath = $resolvedAssemblyPath + '.PlanetCrafterServer.orig'
        $patchSourcePath = if (Test-Path -LiteralPath $backupPath) { $backupPath } else { $resolvedAssemblyPath }
        $patchedOutputPath = Join-Path $env:TEMP ('PlanetCrafterServer-childpatch-{0}.dll' -f ([guid]::NewGuid().ToString('N')))
        $childScriptPath = Join-Path $env:TEMP ('PlanetCrafterServer-childpatch-{0}.ps1' -f ([guid]::NewGuid().ToString('N')))

        try {
            @"
Import-Module '$moduleManifestPath' -Force
& (Get-Module PlanetCrafterServer) {
    param([string]`$AssemblyPath, [string]`$OutputPath)
    Invoke-PCSPatchAssembly -AssemblyPath `$AssemblyPath -OutputPath `$OutputPath | Out-Null
} '$patchSourcePath' '$patchedOutputPath'
"@ | Set-Content -LiteralPath $childScriptPath -Encoding UTF8

            $childOutput = & $powerShellHostPath -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childScriptPath 2>&1 | Out-String -Width 500
            if ($LASTEXITCODE -ne 0) {
                throw "Out-of-process Planet Crafter patching failed. Output:`n$childOutput"
            }

            if (-not (Test-Path -LiteralPath $patchedOutputPath)) {
                throw 'Out-of-process Planet Crafter patching did not produce a patched assembly file.'
            }

            if (-not (Test-Path -LiteralPath $backupPath)) {
                Copy-Item -LiteralPath $resolvedAssemblyPath -Destination $backupPath -Force
            }

            try {
                Copy-PCSFileWithRetry -SourcePath $patchedOutputPath -DestinationPath $resolvedAssemblyPath
            }
            catch {
                throw "Planet Crafter assembly replacement failed for '$resolvedAssemblyPath'. Stop any process or tool using that install path, close Explorer previews, wait for antivirus scanning to finish, or rerun Install-PlanetCrafterServer with -SkipHeadlessPatch and patch later. Details: $($_.Exception.Message)"
            }
            return Get-PCSAssemblyPatchState -AssemblyPath $resolvedAssemblyPath
        }
        finally {
            Remove-Item -LiteralPath $patchedOutputPath, $childScriptPath -Force -ErrorAction SilentlyContinue
        }
    }

    Import-PCSMonoCecil

    $resolvedOutputPath = Resolve-PCSPath -Path $OutputPath
    $outputDirectory = Split-Path -Parent $resolvedOutputPath
    if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
        New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
    }

    $resolver = [Mono.Cecil.DefaultAssemblyResolver]::new()
    $resolver.AddSearchDirectory((Split-Path -Parent $resolvedAssemblyPath))

    $readerParameters = [Mono.Cecil.ReaderParameters]::new()
    $readerParameters.AssemblyResolver = $resolver
    $readerParameters.InMemory = $true

    $assemblyBytes = [System.IO.File]::ReadAllBytes($resolvedAssemblyPath)
    $assemblyStream = [System.IO.MemoryStream]::new($assemblyBytes, $false)
    try {
        $assembly = [Mono.Cecil.AssemblyDefinition]::ReadAssembly($assemblyStream, $readerParameters)
        $module = $assembly.MainModule

        $introType = Find-PCSTypeDefinition -Module $module -FullName 'SpaceCraft.Intro'
        $chatType = Find-PCSTypeDefinition -Module $module -FullName 'SpaceCraft.UiWindowChat'
        $sessionType = Find-PCSTypeDefinition -Module $module -FullName 'SpaceCraft.SessionController'
        $savedDataHandlerType = Find-PCSTypeDefinition -Module $module -FullName 'SpaceCraft.SavedDataHandler'
        $gameConfigType = Find-PCSTypeDefinition -Module $module -FullName 'SpaceCraft.GameConfig'
        $introVideoPlayerType = Find-PCSTypeDefinition -Module $module -FullName 'SpaceCraft.IntroVideoPlayer'
        $saveFilesSelectorType = Find-PCSTypeDefinition -Module $module -FullName 'SpaceCraft.SaveFilesSelector'
        $monoBehaviourTypeReference = Find-PCSTypeReference -Module $module -FullName 'UnityEngine.MonoBehaviour'
        $applicationTypeReference = Find-PCSTypeReference -Module $module -FullName 'UnityEngine.Application'
        $coroutineTypeReference = Find-PCSTypeReference -Module $module -FullName 'UnityEngine.Coroutine'
        $enumeratorTypeReference = Find-PCSTypeReference -Module $module -FullName 'System.Collections.IEnumerator'

        $selectedSaveFileMethod = $module.ImportReference((Get-PCSNamedMethod -Type $saveFilesSelectorType -Name 'SelectedSaveFile' -ParameterCount 1))
        $saveWorldDataMethod = $module.ImportReference((Get-PCSNamedMethod -Type $savedDataHandlerType -Name 'SaveWorldData' -ParameterCount 1))
        $autoSaveMethod = $module.ImportReference((Get-PCSNamedMethod -Type $sessionType -Name 'AutoSave' -ParameterCount 2))
        $startCoroutineMethodReference = [Mono.Cecil.MethodReference]::new('StartCoroutine', $coroutineTypeReference, $monoBehaviourTypeReference)
        $startCoroutineMethodReference.HasThis = $true
        $null = $startCoroutineMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('routine', [System.Reflection.ParameterAttributes]::None, $enumeratorTypeReference))
        $startCoroutineMethod = $module.ImportReference($startCoroutineMethodReference)
        $getPersistentDataPathMethodReference = [Mono.Cecil.MethodReference]::new('get_persistentDataPath', $module.TypeSystem.String, $applicationTypeReference)
        $getPersistentDataPathMethodReference.HasThis = $false
        $getPersistentDataPath = $module.ImportReference($getPersistentDataPathMethodReference)
        $introSaveField = $module.ImportReference(($introType.Fields | Where-Object { $_.Name -eq 'saveFileSelector' } | Select-Object -First 1))
        $savedDataInstanceField = $module.ImportReference(($savedDataHandlerType.Fields | Where-Object { $_.Name -eq 'Instance' } | Select-Object -First 1))
        $saveHiddenIdentifierField = $module.ImportReference(($gameConfigType.Fields | Where-Object { $_.Name -eq 'saveHiddenIdentifier' } | Select-Object -First 1))
        $persistentDataPathOverrideMethod = Ensure-PCSPersistentDataPathOverrideMethod -Module $module -GameConfigType $gameConfigType -GetPersistentDataPathMethod $getPersistentDataPath
        $saveSlotMethods = Ensure-PCSSaveSlotOverrideMethods -Module $module -GameConfigType $gameConfigType -PersistentDataPathOverrideMethod $persistentDataPathOverrideMethod
        $saveRequestMethod = Ensure-PCSSaveRequestHook -Module $module -GameConfigType $gameConfigType -SessionType $sessionType -PersistentDataPathOverrideMethod $persistentDataPathOverrideMethod -SaveSlotNameMethod $saveSlotMethods.SlotNameMethod -SaveWorldDataMethod $saveWorldDataMethod -SavedDataInstanceField $savedDataInstanceField
        $introSkipRequestMethod = Ensure-PCSIntroSkipHook -Module $module -GameConfigType $gameConfigType -SessionType $sessionType -IntroVideoPlayerType $introVideoPlayerType -PersistentDataPathOverrideMethod $persistentDataPathOverrideMethod
        $newSaveRequestMethod = Ensure-PCSNewSaveRequestHook -Module $module -GameConfigType $gameConfigType -IntroType $introType -PersistentDataPathOverrideMethod $persistentDataPathOverrideMethod -SaveSlotNameMethod $saveSlotMethods.SlotNameMethod

        $coreLibrary = $module.TypeSystem.CoreLibrary
        $pathTypeReference = [Mono.Cecil.TypeReference]::new('System.IO', 'Path', $module, $coreLibrary)
        $fileTypeReference = [Mono.Cecil.TypeReference]::new('System.IO', 'File', $module, $coreLibrary)

        $combineMethodReference = [Mono.Cecil.MethodReference]::new('Combine', $module.TypeSystem.String, $pathTypeReference)
        $combineMethodReference.HasThis = $false
        $null = $combineMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path1', [System.Reflection.ParameterAttributes]::None, $module.TypeSystem.String))
        $null = $combineMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path2', [System.Reflection.ParameterAttributes]::None, $module.TypeSystem.String))
        $combineMethod = $module.ImportReference($combineMethodReference)

        $existsMethodReference = [Mono.Cecil.MethodReference]::new('Exists', $module.TypeSystem.Boolean, $fileTypeReference)
        $existsMethodReference.HasThis = $false
        $null = $existsMethodReference.Parameters.Add([Mono.Cecil.ParameterDefinition]::new('path', [System.Reflection.ParameterAttributes]::None, $module.TypeSystem.String))
        $existsMethod = $module.ImportReference($existsMethodReference)

        Set-PCSPersistentDataPathCallSites -Module $module -GetPersistentDataPathMethod $getPersistentDataPath -OverrideMethod $persistentDataPathOverrideMethod | Out-Null

        $introStart = Get-PCSNamedMethod -Type $introType -Name 'Start' -ParameterCount 0
        $introPatched = $false
        foreach ($instruction in $introStart.Body.Instructions) {
            if ($instruction.OpCode.Name -eq 'ldstr' -and $instruction.Operand -eq 'Server-1.json') {
                $introPatched = $true
                break
            }
        }

        if (-not $introPatched) {
            $returnInstruction = $introStart.Body.Instructions[-1]
            $il = $introStart.Body.GetILProcessor()
            foreach ($instruction in @(
                    $il.Create((Get-PCSOpCode -Name 'Call'), $saveSlotMethods.SlotFilePathMethod),
                    $il.Create((Get-PCSOpCode -Name 'Call'), $existsMethod),
                    $il.Create((Get-PCSOpCode -Name 'Brfalse_S'), $returnInstruction),
                    $il.Create((Get-PCSOpCode -Name 'Ldarg_0')),
                    $il.Create((Get-PCSOpCode -Name 'Ldfld'), $introSaveField),
                    $il.Create((Get-PCSOpCode -Name 'Call'), $saveSlotMethods.SlotNameMethod),
                    $il.Create((Get-PCSOpCode -Name 'Callvirt'), $selectedSaveFileMethod)
                )) {
                $il.InsertBefore($returnInstruction, $instruction)
            }
        }

        $chatMethod = Get-PCSNamedMethod -Type $chatType -Name 'OnTextReceived' -ParameterCount 2
        $chatPatched = $false
        for ($i = 0; $i -lt $chatMethod.Body.Instructions.Count; $i++) {
            $instruction = $chatMethod.Body.Instructions[$i]
            if ($instruction.OpCode.Name -eq 'ldstr' -and $instruction.Operand -eq 'Server-1') {
                if (($i + 1) -lt $chatMethod.Body.Instructions.Count) {
                    $next = $chatMethod.Body.Instructions[$i + 1]
                    if ($next.OpCode.Name -eq 'callvirt' -and $next.Operand -and $next.Operand.ToString() -like '*SavedDataHandler::SaveWorldData(System.String)*') {
                        $chatPatched = $true
                        break
                    }
                }
            }
        }

        if (-not $chatPatched) {
            $firstInstruction = $chatMethod.Body.Instructions[0]
            $il = $chatMethod.Body.GetILProcessor()
            foreach ($instruction in @(
                    $il.Create((Get-PCSOpCode -Name 'Ldsfld'), $savedDataInstanceField),
                    $il.Create((Get-PCSOpCode -Name 'Call'), $saveSlotMethods.SlotNameMethod),
                    $il.Create((Get-PCSOpCode -Name 'Callvirt'), $saveWorldDataMethod)
                )) {
                $il.InsertBefore($firstInstruction, $instruction)
            }
        }

        $autosaveMethod = Get-PCSNamedMethod -Type $sessionType -Name 'StartHiddenAutoSave' -ParameterCount 0
        $autosavePatched = $false
        foreach ($instruction in $autosaveMethod.Body.Instructions) {
            if ($instruction.OpCode.Name -eq 'ldc.r4' -and [Math]::Abs([single]$instruction.Operand - 60.0) -lt 0.001) {
                $autosavePatched = $true
                break
            }
        }

        if (-not $autosavePatched) {
            $autosaveMethod.Body.Instructions.Clear()
            $autosaveMethod.Body.ExceptionHandlers.Clear()
            $autosaveMethod.Body.Variables.Clear()
            $il = $autosaveMethod.Body.GetILProcessor()
            foreach ($instruction in @(
                    $il.Create((Get-PCSOpCode -Name 'Ldarg_0')),
                    $il.Create((Get-PCSOpCode -Name 'Ldarg_0')),
                    $il.Create((Get-PCSOpCode -Name 'Ldc_R4'), [single]60.0),
                    $il.Create((Get-PCSOpCode -Name 'Ldsfld'), $saveHiddenIdentifierField),
                    $il.Create((Get-PCSOpCode -Name 'Call'), $autoSaveMethod),
                    $il.Create((Get-PCSOpCode -Name 'Call'), $startCoroutineMethod),
                    $il.Create((Get-PCSOpCode -Name 'Pop')),
                    $il.Create((Get-PCSOpCode -Name 'Ret'))
                )) {
                $il.Append($instruction)
            }
        }

        $writerParameters = [Mono.Cecil.WriterParameters]::new()
        $writerParameters.WriteSymbols = $false
        $temporaryPatchedAssembly = Join-Path $env:TEMP ('PlanetCrafterServer-patched-{0}.dll' -f ([guid]::NewGuid().ToString('N')))
        try {
            $assembly.Write($temporaryPatchedAssembly, $writerParameters)
            Copy-PCSFileWithRetry -SourcePath $temporaryPatchedAssembly -DestinationPath $resolvedOutputPath
        }
        finally {
            Remove-Item -LiteralPath $temporaryPatchedAssembly -Force -ErrorAction SilentlyContinue
        }

        Get-PCSAssemblyPatchState -AssemblyPath $resolvedOutputPath
    }
    finally {
        if ($assembly -is [System.IDisposable]) {
            $assembly.Dispose()
        }
        $assemblyStream.Dispose()
    }
}

function Convert-PCSSectionToList {
    param([string]$Section)

    $trimmed = ($Section | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return @()
    }

    $items = @()
    if ($trimmed -like '*|*') {
        foreach ($part in ($trimmed -split '\|')) {
            $entry = $part.Trim()
            if ([string]::IsNullOrWhiteSpace($entry)) {
                continue
            }
            try {
                $items += ,($entry | ConvertFrom-Json)
            }
            catch {
            }
        }
    }
    else {
        try {
            $items += ,($trimmed | ConvertFrom-Json)
        }
        catch {
        }
    }

    return @($items)
}

function Read-PCSSaveData {
    param([System.Collections.IDictionary]$Instance)

    $path = Get-PCSRuntimeSavePath -Instance $Instance
    if (-not (Test-Path -LiteralPath $path)) {
        return [ordered]@{
            Path             = $path
            Exists           = $false
            GameSettings     = $null
            PlanetState      = $null
            Players          = @()
            Messages         = @()
            StoryEvents      = @()
            TerrainLayers    = @()
            SaveStats        = $null
        }
    }

    $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    $sections = $raw -split '@', 0, 'SimpleMatch'
    if ($sections.Count -lt 9) {
        throw "Save file '$path' is not in the expected Planet Crafter format."
    }

    $gameSettings = $null
    try {
        $gameSettings = $sections[8].Trim() | ConvertFrom-Json
    }
    catch {
    }

    $planetState = $null
    try {
        if ($sections.Count -gt 1 -and -not [string]::IsNullOrWhiteSpace($sections[1].Trim())) {
            $planetState = $sections[1].Trim() | ConvertFrom-Json
        }
    }
    catch {
    }

    $saveStats = $null
    try {
        $saveStats = $sections[5].Trim() | ConvertFrom-Json
    }
    catch {
    }

    [ordered]@{
        Path          = $path
        Exists        = $true
        GameSettings  = $gameSettings
        PlanetState   = $planetState
        Players       = Convert-PCSSectionToList -Section $sections[2]
        Messages      = Convert-PCSSectionToList -Section $sections[6]
        StoryEvents   = Convert-PCSSectionToList -Section $sections[7]
        TerrainLayers = if ($sections.Count -gt 9) { Convert-PCSSectionToList -Section $sections[9] } else { @() }
        SaveStats     = $saveStats
    }
}

function Test-PCSIsPublicIPv4Address {
    param(
        [Parameter(Mandatory = $true)]
        [string]$IPAddress
    )

    $parsedAddress = $null
    if (-not [System.Net.IPAddress]::TryParse($IPAddress, [ref]$parsedAddress)) {
        return $false
    }

    if ($parsedAddress.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return $false
    }

    $bytes = $parsedAddress.GetAddressBytes()
    $first = [int]$bytes[0]
    $second = [int]$bytes[1]

    if ($first -eq 10) { return $false }
    if ($first -eq 127) { return $false }
    if ($first -eq 0) { return $false }
    if ($first -eq 169 -and $second -eq 254) { return $false }
    if ($first -eq 172 -and $second -ge 16 -and $second -le 31) { return $false }
    if ($first -eq 192 -and $second -eq 168) { return $false }
    if ($first -eq 100 -and $second -ge 64 -and $second -le 127) { return $false }
    if ($first -eq 198 -and ($second -eq 18 -or $second -eq 19)) { return $false }
    if ($first -ge 224) { return $false }

    return $true
}

function Get-PCSLocalIPv4Addresses {
    $addresses = @()

    foreach ($config in @(Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
        if (-not $config.NetAdapter -or $config.NetAdapter.Status -ne 'Up') {
            continue
        }

        foreach ($ip in @($config.IPv4Address)) {
            if ($null -eq $ip -or [string]::IsNullOrWhiteSpace($ip.IPAddress)) {
                continue
            }

            if ($ip.IPAddress -eq '127.0.0.1' -or $ip.IPAddress -like '169.254.*') {
                continue
            }

            $addresses += $ip.IPAddress
        }
    }

    if (@($addresses).Count -eq 0) {
        foreach ($ip in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($ip.IPAddress)) {
                continue
            }

            if ($ip.IPAddress -eq '127.0.0.1' -or $ip.IPAddress -like '169.254.*') {
                continue
            }

            $addresses += $ip.IPAddress
        }
    }

    @($addresses | Select-Object -Unique)
}

function Get-PCSAddressSummary {
    param(
        [object[]]$UdpEndpoints
    )

    $listenerAddresses = @()
    foreach ($endpoint in @($UdpEndpoints)) {
        if ($null -eq $endpoint) {
            continue
        }

        $address = [string]$endpoint.LocalAddress
        if ([string]::IsNullOrWhiteSpace($address)) {
            continue
        }

        if ($address -ne '0.0.0.0' -and $address -ne '::' -and $address -ne '::0') {
            $listenerAddresses += $address
        }
    }

    if (@($listenerAddresses).Count -eq 0) {
        $listenerAddresses = @(Get-PCSLocalIPv4Addresses)
    }
    else {
        $listenerAddresses = @($listenerAddresses | Select-Object -Unique)
    }

    $publicAddresses = @()
    foreach ($address in @($listenerAddresses)) {
        if (Test-PCSIsPublicIPv4Address -IPAddress $address) {
            $publicAddresses += $address
        }
    }

    [ordered]@{
        IPAddress       = if (@($listenerAddresses).Count -gt 0) { (@($listenerAddresses) -join ', ') } else { $null }
        PublicIPAddress = if (@($publicAddresses).Count -gt 0) { (@($publicAddresses | Select-Object -Unique) -join ', ') } else { $null }
    }
}

function Get-PCSPublicIPAddress {
    param(
        [int]$CacheSeconds = 300
    )

    if ($script:PublicIpCacheValue -and (Get-Date) -lt $script:PublicIpCacheExpiresAt) {
        return $script:PublicIpCacheValue
    }

    $script:PublicIpCacheError = $null
    $providers = @(
        @{
            Uri = 'https://api.ipify.org?format=json'
            Mode = 'json'
        },
        @{
            Uri = 'https://checkip.amazonaws.com/'
            Mode = 'text'
        },
        @{
            Uri = 'https://ifconfig.me/ip'
            Mode = 'text'
        }
    )

    foreach ($provider in $providers) {
        try {
            if ($PSVersionTable.PSEdition -eq 'Desktop') {
                $response = Invoke-WebRequest -Uri $provider.Uri -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            }
            else {
                $response = Invoke-WebRequest -Uri $provider.Uri -TimeoutSec 5 -ErrorAction Stop
            }
            $candidate = $null
            if ($provider.Mode -eq 'json') {
                $parsed = $response.Content | ConvertFrom-Json
                $candidate = [string]$parsed.ip
            }
            else {
                $candidate = [string]$response.Content
            }

            if ($candidate) {
                $candidate = $candidate.Trim()
            }

            $parsedAddress = $null
            if ($candidate -and [System.Net.IPAddress]::TryParse($candidate, [ref]$parsedAddress) -and $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
                $script:PublicIpCacheValue = $candidate
                $script:PublicIpCacheExpiresAt = (Get-Date).AddSeconds($CacheSeconds)
                $script:PublicIpCacheError = $null
                return $candidate
            }
        }
        catch {
            $script:PublicIpCacheError = $_.Exception.Message
        }
    }

    $script:PublicIpCacheValue = $null
    $script:PublicIpCacheExpiresAt = (Get-Date).AddSeconds(30)
    return $null
}

function Import-PCSPlanetCrafterRuntimeAssemblies {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Instance
    )

    $managedPath = Join-Path $Instance.InstallPath 'Planet Crafter_Data\Managed'
    $assemblies = @(
        @{ Name = 'UnityEngine'; Path = (Join-Path $managedPath 'UnityEngine.dll') },
        @{ Name = 'UnityEngine.CoreModule'; Path = (Join-Path $managedPath 'UnityEngine.CoreModule.dll') },
        @{ Name = 'Assembly-CSharp'; Path = (Join-Path $managedPath 'Assembly-CSharp.dll') }
    )

    foreach ($assemblyInfo in $assemblies) {
        if (-not (Get-PCSLoadedAssemblyByName -Name $assemblyInfo.Name)) {
            if (-not (Test-Path -LiteralPath $assemblyInfo.Path)) {
                throw "Required Planet Crafter assembly '$($assemblyInfo.Path)' was not found."
            }

            Add-Type -Path $assemblyInfo.Path
        }
    }
}

function Get-PCSSaveProgressData {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Instance,
        $PlanetState
    )

    if ($null -eq $PlanetState) {
        return [ordered]@{
            Progress = $null
            TerraformationValue = $null
        }
    }

    $terraformationValue =
        [double]$PlanetState.unitOxygenLevel +
        [double]$PlanetState.unitHeatLevel +
        [double]$PlanetState.unitPressureLevel +
        [double]$PlanetState.unitPlantsLevel +
        [double]$PlanetState.unitInsectsLevel +
        [double]$PlanetState.unitAnimalsLevel +
        [Math]::Max([double]$PlanetState.unitPurificationLevel, 0.0)

    try {
        Import-PCSPlanetCrafterRuntimeAssemblies -Instance $Instance
        $handlerType = [Type]::GetType('SpaceCraft.WorldUnitsHandler, Assembly-CSharp', $true)
        $worldUnitType = [Type]::GetType('SpaceCraft.WorldUnit, Assembly-CSharp', $true)
        $units = $handlerType.GetField('UnitsTerraformation').GetValue($null)
        $displayMethod = $worldUnitType.GetMethods() | Where-Object {
            $_.Name -eq 'GetDisplayStringForValue' -and $_.IsStatic -and $_.GetParameters().Count -eq 5
        } | Select-Object -First 1

        $progress = $null
        if ($displayMethod -and $units) {
            $progress = [string]$displayMethod.Invoke($null, @($units, [double]$terraformationValue, $true, -1, $false))
        }

        [ordered]@{
            Progress = $progress
            TerraformationValue = $terraformationValue
        }
    }
    catch {
        [ordered]@{
            Progress = $null
            TerraformationValue = $terraformationValue
        }
    }
}

function Get-PCSServerConfiguration {
    param([System.Collections.IDictionary]$Instance)

    $path = Get-PCSServerConfigPath -Instance $Instance
    $config = [ordered]@{
        Exists         = $false
        Path           = $path
        hostPort       = [uint16]$Instance.HostPort
        hostPlayerName = $Instance.HostPlayerName
        FileHostPort   = $null
        FileHostPlayerName = $null
    }

    if (Test-Path -LiteralPath $path) {
        try {
            $loaded = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($loaded.PSObject.Properties['hostPort']) {
                $config.FileHostPort = [uint16]$loaded.hostPort
            }
            if ($loaded.PSObject.Properties['hostPlayerName']) {
                $config.FileHostPlayerName = [string]$loaded.hostPlayerName
            }
            $config.Exists = $true
        }
        catch {
            throw "Failed to parse Planet Crafter server config '$path'. $($_.Exception.Message)"
        }
    }

    $config
}

function Write-PCSServerConfiguration {
    param([System.Collections.IDictionary]$Instance)

    $path = Get-PCSServerConfigPath -Instance $Instance
    $directory = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $data = [ordered]@{
        hostPort       = [uint16]$Instance.HostPort
        hostPlayerName = $Instance.HostPlayerName
    }

    New-PCSBackupFile -Instance $Instance -Path $path | Out-Null
    $data | ConvertTo-Json -Compress | Set-Content -LiteralPath $path -Encoding ASCII
    $path
}

function Copy-PCSSelectedSaveToRuntime {
    param(
        [System.Collections.IDictionary]$Instance,
        [string]$SourceSavePath
    )

    if (-not $SourceSavePath) {
        if ($Instance.SelectedSavePath) {
            $SourceSavePath = $Instance.SelectedSavePath
        }
        else {
            throw 'No selected save path was provided or stored for this instance.'
        }
    }

    $resolvedSource = Resolve-PCSPath -Path $SourceSavePath
    if (-not (Test-Path -LiteralPath $resolvedSource)) {
        throw "Selected save '$resolvedSource' was not found."
    }

    $runtimePath = Get-PCSRuntimeSavePath -Instance $Instance
    $runtimeDirectory = Split-Path -Parent $runtimePath
    if (-not (Test-Path -LiteralPath $runtimeDirectory)) {
        New-Item -Path $runtimeDirectory -ItemType Directory -Force | Out-Null
    }

    if ([string]::Compare($resolvedSource, $runtimePath, $true) -ne 0) {
        New-PCSBackupFile -Instance $Instance -Path $runtimePath | Out-Null
        Copy-Item -LiteralPath $resolvedSource -Destination $runtimePath -Force
    }

    $runtimePath
}

function Get-PCSProcessObjects {
    param([System.Collections.IDictionary]$Instance)

    $exePath = Get-PCSExecutablePath -Instance $Instance
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -eq $exePath })
}

function Wait-PCSStopped {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Instance,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (@(Get-PCSProcessObjects -Instance $Instance).Count -eq 0) {
            return $true
        }

        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Stop-PCSInstanceProcessesInternal {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Instance,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $taskKillPath = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    $cmdPath = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $diagnosticLines = New-Object System.Collections.Generic.List[string]

    do {
        $processes = @(Get-PCSProcessObjects -Instance $Instance)
        if ($processes.Count -eq 0) {
            return [pscustomobject]@{
                Succeeded          = $true
                RemainingProcesses = @()
                Diagnostics        = @($diagnosticLines)
            }
        }

        foreach ($process in $processes) {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $process.ProcessId -Timeout 2 -ErrorAction SilentlyContinue

            $remainingProcess = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $process.ProcessId) -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $remainingProcess) {
                continue
            }

            if (Test-Path -LiteralPath $taskKillPath) {
                if (Test-Path -LiteralPath $cmdPath) {
                    $taskKillCommandLine = '"{0}" /PID {1} /T /F 2>&1' -f $taskKillPath, $process.ProcessId
                    $taskKillOutput = & $cmdPath /d /c $taskKillCommandLine | Out-String -Width 300
                }
                else {
                    $taskKillOutput = & $taskKillPath /PID $process.ProcessId /T /F 2>&1 | Out-String -Width 300
                }

                Wait-Process -Id $process.ProcessId -Timeout 2 -ErrorAction SilentlyContinue

                foreach ($line in @($taskKillOutput -split "(`r`n|`n|`r)")) {
                    if ([string]::IsNullOrWhiteSpace($line)) {
                        continue
                    }

                    if ($line -match 'SUCCESS:|ERROR:|INFO:') {
                        $diagnosticLines.Add($line.Trim()) | Out-Null
                    }
                }
            }
        }

        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    $remaining = @(
        @(Get-PCSProcessObjects -Instance $Instance) | ForEach-Object {
            '{0}({1})' -f $_.Name, $_.ProcessId
        }
    )

    return [pscustomobject]@{
        Succeeded          = ($remaining.Count -eq 0)
        RemainingProcesses = $remaining
        Diagnostics        = @($diagnosticLines)
    }
}

function Get-PCSPortConflictObjects {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Instance
    )

    $targetPort = [int]$Instance.HostPort
    $targetName = [string]$Instance.Name
    $registeredInstances = @(Get-PCSRegisteredInstances)
    $conflicts = @()
    $seenProcessIds = New-Object System.Collections.Generic.HashSet[int]

    foreach ($otherInstance in $registeredInstances) {
        if ($otherInstance.Name -eq $targetName) {
            continue
        }

        if ([int]$otherInstance.HostPort -ne $targetPort) {
            continue
        }

        foreach ($process in @(Get-PCSProcessObjects -Instance $otherInstance)) {
            $null = $seenProcessIds.Add([int]$process.ProcessId)
            $conflicts += [pscustomobject]@{
                Source        = 'RegisteredInstance'
                InstanceName  = $otherInstance.Name
                ProcessId     = [int]$process.ProcessId
                ProcessName   = [string]$process.Name
                ExecutablePath = [string]$process.ExecutablePath
                Port          = $targetPort
                Protocol      = 'UDP/TCP'
            }
        }
    }

    $udpEndpoints = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq $targetPort })
    $tcpEndpoints = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq $targetPort })

    foreach ($endpoint in @($udpEndpoints + $tcpEndpoints)) {
        $pid = [int]$endpoint.OwningProcess
        if ($pid -le 0) {
            continue
        }

        if ($seenProcessIds.Contains($pid)) {
            continue
        }

        $null = $seenProcessIds.Add($pid)
        $process = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $pid) -ErrorAction SilentlyContinue | Select-Object -First 1
        $conflicts += [pscustomobject]@{
            Source        = 'SystemPortUse'
            InstanceName  = $null
            ProcessId     = $pid
            ProcessName   = if ($process) { [string]$process.Name } else { $null }
            ExecutablePath = if ($process) { [string]$process.ExecutablePath } else { $null }
            Port          = $targetPort
            Protocol      = if ($endpoint.PSObject.Properties['RemoteAddress']) { 'TCP' } else { 'UDP' }
        }
    }

    return @($conflicts)
}

function Assert-PCSPortAvailableForStart {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Instance
    )

    $conflicts = @(Get-PCSPortConflictObjects -Instance $Instance)
    if ($conflicts.Count -eq 0) {
        return
    }

    $detailLines = foreach ($conflict in $conflicts) {
        if ($conflict.Source -eq 'RegisteredInstance') {
            "{0} is already running on port {1} (PID {2})." -f $conflict.InstanceName, $conflict.Port, $conflict.ProcessId
        }
        elseif ($conflict.ProcessName -or $conflict.ExecutablePath) {
            "{0} port {1} is in use by process {2} (PID {3}) at {4}." -f $conflict.Protocol, $conflict.Port, $conflict.ProcessName, $conflict.ProcessId, $conflict.ExecutablePath
        }
        else {
            "{0} port {1} is already in use by PID {2}." -f $conflict.Protocol, $conflict.Port, $conflict.ProcessId
        }
    }

    throw "Cannot start Planet Crafter server '$($Instance.Name)' because port $($Instance.HostPort) is already in use.`n$($detailLines -join [Environment]::NewLine)"
}

function Wait-PCSReady {
    param(
        [System.Collections.IDictionary]$Instance,
        [int]$TimeoutSeconds
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $exePath = Get-PCSExecutablePath -Instance $Instance
    do {
        $proc = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -eq $exePath } | Select-Object -First 1
        if ($proc) {
            $udp = @(Get-NetUDPEndpoint -OwningProcess $proc.ProcessId -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq [int]$Instance.HostPort })
            if ($udp.Count -gt 0) {
                return $true
            }
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Get-PCSSteamCmdOutputSummary {
    param(
        [AllowEmptyString()]
        [string]$Output
    )

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return 'No SteamCMD output was produced.'
    }

    $relevantLines = @($Output -split "(`r`n|`n|`r)" | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and (
                $_ -match 'Steam Guard' -or
                $_ -match 'set_steam_guard_code' -or
                $_ -match 'Account Logon Denied' -or
                $_ -match 'Logging in ' -or
                $_ -match 'Please check your email' -or
                $_ -match 'verify your login' -or
                $_ -match 'Invalid Password' -or
                $_ -match 'Login Failure' -or
                $_ -match 'Waiting for user info' -or
                $_ -match 'FAILED' -or
                $_ -match 'ERROR'
            )
        })

    if ($relevantLines.Count -gt 0) {
        return ($relevantLines | Select-Object -First 20) -join [Environment]::NewLine
    }

    ($Output -split "(`r`n|`n|`r)" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 20) -join [Environment]::NewLine
}

function Test-PCSSteamCmdRequiresSteamGuard {
    param(
        [AllowEmptyString()]
        [string]$Output
    )

    if ([string]::IsNullOrWhiteSpace($Output)) {
        return $false
    }

    return (
        $Output -match 'authenticated for your account using Steam Guard' -or
        $Output -match 'set_steam_guard_code' -or
        $Output -match 'Account Logon Denied'
    )
}

function Read-PCSSteamGuardCode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserName,
        [Parameter(Mandatory = $true)]
        [string]$OutputSummary
    )

    try {
        $code = Read-Host -Prompt ("Steam Guard code required for {0}. Enter the current code from Steam" -f $UserName)
    }
    catch {
        throw "SteamCMD requires Steam Guard for account '$UserName'. This session could not prompt for the code interactively. Rerun Install-PlanetCrafterServer with -SteamGuardCode <code>. SteamCMD output summary:`n$OutputSummary"
    }

    if ([string]::IsNullOrWhiteSpace($code)) {
        throw "SteamCMD requires Steam Guard for account '$UserName', but no code was entered. Rerun Install-PlanetCrafterServer with -SteamGuardCode <code> or enter a code when prompted."
    }

    return $code.Trim()
}

function Invoke-PCSSteamCmdScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SteamCmdPath,
        [Parameter(Mandatory = $true)]
        [string[]]$ScriptLines
    )

    $tempScript = Join-Path $env:TEMP ('PlanetCrafterServer-steamcmd-{0}.txt' -f ([guid]::NewGuid().ToString('N')))

    try {
        Set-Content -LiteralPath $tempScript -Value $ScriptLines -Encoding ASCII
        $output = & $SteamCmdPath +runscript $tempScript 2>&1 | Out-String -Width 500
        [pscustomobject]@{
            ExitCode          = $LASTEXITCODE
            Output            = $output
            OutputSummary     = Get-PCSSteamCmdOutputSummary -Output $output
            RequiresSteamGuard = (Test-PCSSteamCmdRequiresSteamGuard -Output $output)
            ScriptPath        = $tempScript
        }
    }
    finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PCSSteamCmdLogin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SteamCmdPath,
        [Parameter(Mandatory = $true)]
        [pscredential]$SteamCredential,
        [string]$SteamGuardCode
    )

    $plainPassword = Get-PCSPlainTextFromCredential -Credential $SteamCredential
    $scriptLines = @(
        '@ShutdownOnFailedCommand 1',
        '@NoPromptForPassword 1'
    )

    if (-not [string]::IsNullOrWhiteSpace($SteamGuardCode)) {
        $scriptLines += ('set_steam_guard_code {0}' -f $SteamGuardCode.Trim())
    }

    $scriptLines += ('login {0} {1}' -f $SteamCredential.UserName, $plainPassword)
    $scriptLines += 'quit'

    Invoke-PCSSteamCmdScript -SteamCmdPath $SteamCmdPath -ScriptLines $scriptLines
}

function Invoke-PCSSteamCmdInstall {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallPath,
        [Parameter(Mandatory = $true)]
        [pscredential]$SteamCredential,
        [string]$SteamCmdPath,
        [string]$SteamGuardCode
    )

    $steamCmdCommand = Get-Command steamcmd.exe -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' } | Select-Object -ExpandProperty Source -First 1
    $candidates = @(
        $SteamCmdPath,
        $steamCmdCommand,
        $(if ($env:SystemDrive) { Join-Path $env:SystemDrive 'SteamCMD\steamcmd.exe' } else { $null }),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Steam\steamcmd.exe' } else { $null }),
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Steam\steamcmd.exe' } else { $null })
    ) | Where-Object { $_ }

    $resolvedSteamCmdPath = $null
    foreach ($candidate in $candidates) {
        $resolvedCandidate = Resolve-PCSPath -Path $candidate
        if (Test-Path -LiteralPath $resolvedCandidate) {
            $resolvedSteamCmdPath = $resolvedCandidate
            break
        }
    }

    if (-not $resolvedSteamCmdPath) {
        throw 'SteamCMD executable was not found. Use -SteamCmdPath or install SteamCMD first.'
    }

    $normalizedSteamGuardCode = $null
    if (-not [string]::IsNullOrWhiteSpace($SteamGuardCode)) {
        $normalizedSteamGuardCode = $SteamGuardCode.Trim()
    }

    $loginResult = Invoke-PCSSteamCmdLogin -SteamCmdPath $resolvedSteamCmdPath -SteamCredential $SteamCredential -SteamGuardCode $normalizedSteamGuardCode
    if ($loginResult.RequiresSteamGuard -and -not $normalizedSteamGuardCode) {
        $normalizedSteamGuardCode = Read-PCSSteamGuardCode -UserName $SteamCredential.UserName -OutputSummary $loginResult.OutputSummary
        $loginResult = Invoke-PCSSteamCmdLogin -SteamCmdPath $resolvedSteamCmdPath -SteamCredential $SteamCredential -SteamGuardCode $normalizedSteamGuardCode
    }

    if ($loginResult.RequiresSteamGuard) {
        if ($normalizedSteamGuardCode) {
            throw "SteamCMD rejected the supplied Steam Guard code. Request a fresh code from Steam and rerun Install-PlanetCrafterServer with -SteamGuardCode <code>. SteamCMD output summary:`n$($loginResult.OutputSummary)"
        }

        throw "SteamCMD requires Steam Guard for account '$($SteamCredential.UserName)'. Request the code from Steam and rerun Install-PlanetCrafterServer with -SteamGuardCode <code>. SteamCMD output summary:`n$($loginResult.OutputSummary)"
    }

    if ($loginResult.ExitCode -ne 0) {
        throw "SteamCMD login preflight failed with exit code $($loginResult.ExitCode). Output summary:`n$($loginResult.OutputSummary)"
    }

    $plainPassword = Get-PCSPlainTextFromCredential -Credential $SteamCredential
    $installScriptLines = @(
        '@ShutdownOnFailedCommand 1',
        '@NoPromptForPassword 1',
        ('force_install_dir "{0}"' -f $InstallPath)
    )

    if ($normalizedSteamGuardCode) {
        $installScriptLines += ('set_steam_guard_code {0}' -f $normalizedSteamGuardCode)
    }

    $installScriptLines += ('login {0} {1}' -f $SteamCredential.UserName, $plainPassword)
    $installScriptLines += ('app_update {0} validate' -f $script:GameAppId)
    $installScriptLines += 'quit'

    $installResult = Invoke-PCSSteamCmdScript -SteamCmdPath $resolvedSteamCmdPath -ScriptLines $installScriptLines
    if ($installResult.RequiresSteamGuard -and -not $normalizedSteamGuardCode) {
        $normalizedSteamGuardCode = Read-PCSSteamGuardCode -UserName $SteamCredential.UserName -OutputSummary $installResult.OutputSummary
        $installScriptLines = @(
            '@ShutdownOnFailedCommand 1',
            '@NoPromptForPassword 1',
            ('force_install_dir "{0}"' -f $InstallPath),
            ('set_steam_guard_code {0}' -f $normalizedSteamGuardCode),
            ('login {0} {1}' -f $SteamCredential.UserName, $plainPassword),
            ('app_update {0} validate' -f $script:GameAppId),
            'quit'
        )
        $installResult = Invoke-PCSSteamCmdScript -SteamCmdPath $resolvedSteamCmdPath -ScriptLines $installScriptLines
    }

    if ($installResult.RequiresSteamGuard) {
        throw "SteamCMD rejected the supplied Steam Guard code during install. Request a fresh code from Steam and rerun Install-PlanetCrafterServer with -SteamGuardCode <code>. SteamCMD output summary:`n$($installResult.OutputSummary)"
    }

    if ($installResult.ExitCode -ne 0) {
        throw "SteamCMD failed with exit code $($installResult.ExitCode). Output summary:`n$($installResult.OutputSummary)"
    }

    $installResult.Output
}

function Get-PCSInstanceInfo {
    param(
        [System.Collections.IDictionary]$Instance,
        [switch]$IncludeLogTail,
        [int]$TailLines = 40
    )

    $saveInfo = Read-PCSSaveData -Instance $Instance
    $serverConfig = Get-PCSServerConfiguration -Instance $Instance
    $patchState = Get-PCSAssemblyPatchState -AssemblyPath (Get-PCSAssemblyPath -Instance $Instance)
    $processes = @(Get-PCSProcessObjects -Instance $Instance)
    $process = $null
    $udpEndpoints = @()
    $tcpConnections = @()
    $processInfo = $null
    if ($processes.Count -gt 0) {
        $process = $processes[0]
        $liveProcess = Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
        if ($liveProcess) {
            $processInfo = [pscustomobject]@{
                ProcessId       = $process.ProcessId
                CommandLine     = $process.CommandLine
                WorkingSetMB    = [math]::Round($liveProcess.WorkingSet64 / 1MB, 2)
                PrivateMemoryMB = [math]::Round($liveProcess.PrivateMemorySize64 / 1MB, 2)
                CPUSeconds      = [math]::Round($liveProcess.CPU, 2)
                StartTime       = $liveProcess.StartTime
            }
        }
        $udpEndpoints = @(Get-NetUDPEndpoint -OwningProcess $process.ProcessId -ErrorAction SilentlyContinue | Select-Object LocalAddress, LocalPort, OwningProcess)
        $tcpConnections = @(Get-NetTCPConnection -OwningProcess $process.ProcessId -ErrorAction SilentlyContinue | Select-Object State, LocalAddress, LocalPort, RemoteAddress, RemotePort, OwningProcess)
    }

    $joinedClients = @()
    foreach ($player in $saveInfo.Players) {
        $isHost = $false
        if ($player.PSObject.Properties['host']) {
            $isHost = [bool]$player.host
        }

        if (-not $isHost) {
            $joinedClients += [pscustomobject]@{
                Id        = if ($player.PSObject.Properties['id']) { $player.id } else { $null }
                Name      = if ($player.PSObject.Properties['name']) { $player.name } else { $null }
                PlanetId  = if ($player.PSObject.Properties['planetId']) { $player.planetId } else { $null }
                InventoryId = if ($player.PSObject.Properties['inventoryId']) { $player.inventoryId } else { $null }
            }
        }
    }

    $logPath = Get-PCSLogPath -Instance $Instance
    $logTail = $null
    if ($IncludeLogTail -and (Test-Path -LiteralPath $logPath)) {
        $logTail = @(Get-Content -LiteralPath $logPath -Tail $TailLines)
    }

    $addressSummary = Get-PCSAddressSummary -UdpEndpoints $udpEndpoints
    $publicIPAddress = Get-PCSPublicIPAddress
    if ([string]::IsNullOrWhiteSpace($publicIPAddress)) {
        $publicIPAddress = $addressSummary.PublicIPAddress
    }
    $progressData = Get-PCSSaveProgressData -Instance $Instance -PlanetState $saveInfo.PlanetState

    [pscustomobject]@{
        PSTypeName          = 'PlanetCrafterServer.Info'
        Name                = $Instance.Name
        SaveDisplayName     = if ($saveInfo.GameSettings) { $saveInfo.GameSettings.saveDisplayName } else { $null }
        Progress            = $progressData.Progress
        TerraformationValue = $progressData.TerraformationValue
        InstallPath         = $Instance.InstallPath
        SaveRootPath        = $Instance.SaveRootPath
        RuntimeSaveFileName = $Instance.RuntimeSaveFileName
        RuntimeSavePath     = Get-PCSRuntimeSavePath -Instance $Instance
        SelectedSavePath    = $Instance.SelectedSavePath
        ServerConfigPath    = Get-PCSServerConfigPath -Instance $Instance
        Port                = [uint16]$serverConfig.hostPort
        HostPlayerName      = [string]$serverConfig.hostPlayerName
        ExperimentalHeadless = [bool]$Instance.ExperimentalHeadless
        InstallMethod       = $Instance.InstallMethod
        AppId               = $Instance.AppId
        PatchedAssembly     = [bool]$patchState.FullyPatched
        PatchDetails        = [pscustomobject]$patchState
        Status              = if ($process) { 'Running' } else { 'Stopped' }
        IPAddress           = $addressSummary.IPAddress
        PublicIPAddress     = $publicIPAddress
        ProcessID           = if ($processInfo) { $processInfo.ProcessId } else { $null }
        Process             = $processInfo
        UdpEndpoints        = $udpEndpoints
        TcpConnections      = $tcpConnections
        SaveMode            = if ($saveInfo.GameSettings) { $saveInfo.GameSettings.mode } else { $null }
        SaveVersion         = if ($saveInfo.GameSettings) { $saveInfo.GameSettings.version } else { $null }
        PlanetId            = if ($saveInfo.GameSettings) { $saveInfo.GameSettings.planetId } else { $null }
        StartLocation       = if ($saveInfo.GameSettings) { $saveInfo.GameSettings.gameStartLocation } else { $null }
        WorldSeed           = if ($saveInfo.GameSettings) { $saveInfo.GameSettings.worldSeed } else { $null }
        HasPlayedIntro      = if ($saveInfo.GameSettings) { $saveInfo.GameSettings.hasPlayedIntro } else { $null }
        PlayerCount         = @($saveInfo.Players).Count
        JoinedClientCount   = @($joinedClients).Count
        JoinedClients       = $joinedClients
        GameSettings        = $saveInfo.GameSettings
        SaveStats           = $saveInfo.SaveStats
        LogPath             = $logPath
        LogTail             = $logTail
        CreatedAt           = $Instance.CreatedAt
        UpdatedAt           = $Instance.UpdatedAt
    }
}

function Update-PCSInstanceValue {
    param(
        [System.Collections.IDictionary]$Instance,
        [string]$Key,
        $Value
    )

    $Instance[$Key] = $Value
}

function Ensure-PCSInstanceReadyForStart {
    param(
        [System.Collections.IDictionary]$Instance,
        [switch]$RefreshSelectedSave
    )

    $exePath = Get-PCSExecutablePath -Instance $Instance
    if (-not (Test-Path -LiteralPath $exePath)) {
        throw "Planet Crafter server executable was not found at '$exePath'."
    }

    $assemblyPath = Get-PCSAssemblyPath -Instance $Instance
    if (-not (Test-Path -LiteralPath $assemblyPath)) {
        throw "Planet Crafter server assembly was not found at '$assemblyPath'."
    }

    $runtimeSavePath = Get-PCSRuntimeSavePath -Instance $Instance
    $runtimeSaveExists = Test-Path -LiteralPath $runtimeSavePath
    $pendingNewSaveRequest = Test-PCSNewSaveRequestPending -Instance $Instance
    if ($Instance.SelectedSavePath -and ($RefreshSelectedSave -or -not $runtimeSaveExists)) {
        $resolvedSelectedSavePath = Resolve-PCSPath -Path $Instance.SelectedSavePath
        $selectedSaveMatchesRuntimePath = [string]::Compare($resolvedSelectedSavePath, $runtimeSavePath, $true) -eq 0
        if (Test-Path -LiteralPath $resolvedSelectedSavePath) {
            Copy-PCSSelectedSaveToRuntime -Instance $Instance -SourceSavePath $resolvedSelectedSavePath | Out-Null
            $runtimeSaveExists = Test-Path -LiteralPath $runtimeSavePath
        }
        elseif (-not ($pendingNewSaveRequest -and $selectedSaveMatchesRuntimePath)) {
            throw "Selected save '$resolvedSelectedSavePath' was not found."
        }
    }

    if (-not $runtimeSaveExists -and -not $pendingNewSaveRequest) {
        throw "Runtime server save '$runtimeSavePath' was not found. Use Set-PlanetCrafterServer -SelectedSavePath to stage a save."
    }

    if ($runtimeSaveExists -and $Instance.HostPlayerName) {
        Set-PCSHostPlayerNameInSave -SavePath $runtimeSavePath -HostPlayerName $Instance.HostPlayerName -Instance $Instance | Out-Null
    }

    $logDirectory = Split-Path -Parent (Get-PCSLogPath -Instance $Instance)
    if (-not (Test-Path -LiteralPath $logDirectory)) {
        New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $Instance.SaveRootPath)) {
        New-Item -Path $Instance.SaveRootPath -ItemType Directory -Force | Out-Null
    }
}

<#
.SYNOPSIS
Installs or adopts an experimental Planet Crafter headless server instance.

.DESCRIPTION
Install-PlanetCrafterServer creates module-managed metadata for a Planet Crafter server instance and
optionally stages the server files, runtime save, firewall rules, Server.conf, and the unsupported
headless assembly patch used by this environment.

Use -UseExistingFiles to adopt an already prepared installation, -SourcePath to copy an existing
Planet Crafter client folder into a new install path, or -SteamCredential to attempt a SteamCMD-based
install. The SteamCMD path is best-effort because Planet Crafter does not ship an official dedicated
server package. Unless -SaveFileName is supplied, the runtime save file is named after -Name with a .json
extension. Use -NewSaveRequestAfterInstall to stage a native new-save request for the next
startup; use -StartAfterInstall to consume that request immediately.

.PARAMETER Name
Logical instance name used by the module to track this Planet Crafter server.

.PARAMETER InstallPath
Installation target. If the path ends with a backslash or slash, -Name is appended as a new
server subfolder, such as -Name SaveTest1 -InstallPath (Join-Path $env:SystemDrive 'GameServers\')
resolving to a child folder named SaveTest1. Without a trailing separator, the path is used as the
exact target directory. When -Name is omitted, the name is derived from the final directory name
only in the exact-target form.

.PARAMETER UseExistingFiles
Adopts an existing installation at -InstallPath without copying files first.

.PARAMETER SourcePath
Copies Planet Crafter files from an existing source folder into -InstallPath before registering the instance.

.PARAMETER SteamCredential
Steam login credential used when attempting a SteamCMD-based install of the client files. The module now performs a login preflight before app_update work begins.

.PARAMETER SteamCmdPath
Optional explicit path to steamcmd.exe. If omitted, common Windows SteamCMD locations are searched.

.PARAMETER SteamGuardCode
Optional Steam Guard code to pass during the SteamCMD login flow. If omitted and Steam Guard is required, the cmdlet prompts interactively with Read-Host when the host supports prompting. Use this parameter for noninteractive automation or when retrying with a fresh code.

.PARAMETER SaveRootPath
Folder that stores Planet Crafter save files and Server.conf for this instance. When the
headless patch is applied, each started process receives this path through a per-process
override so multiple servers can run concurrently under the same Windows user.

.PARAMETER SaveFileName
Save file name loaded by the patched headless server. If omitted, defaults to the server name with
a .json extension, such as PlanetCrafter_Server.json. An existing .json suffix in -Name is not
duplicated.

.PARAMETER SelectedSavePath
Source save to copy into the runtime save slot during install and later starts. When
-NewSaveRequestAfterInstall is used and -SelectedSavePath is omitted, the selected save
defaults to the instance runtime save path so the generated save becomes the active save
for later starts.

.PARAMETER NewSaveDisplayName
Display name to use when creating a fresh save request during install or the next start. If omitted,
the base name of SaveFileName is used.

.PARAMETER NewSavePlanetId
Planet identifier to use for a generated fresh save, such as Prime, Humble, Selenea, or Toxicity.

.PARAMETER NewSaveGameMode
Game mode to use for the generated fresh save, such as Standard, Chill, Intense, or Creative.

.PARAMETER NewSaveStartLocation
Planet spawn location id for the generated fresh save. Friendly labels such as 'Sand Falls',
'Grand Rift', and 'Spaceship arrival' are normalized to the game's internal spawn ids.

.PARAMETER NewSaveDyingConsequences
Dying consequences preset to use for the generated fresh save.

.PARAMETER NewSaveWorldSeed
Optional world seed to use when generating a fresh save request.

.PARAMETER NewSaveRequestAfterInstall
Stages a native new-save request in the instance save root. Supplying any -NewSave* option implies
this switch. The patched game consumes the request
on its next main-menu startup; with -StartAfterInstall, that startup happens as part of the same
install command. When -SelectedSavePath is omitted, the instance defaults it to the runtime save
path for the generated save. When combined with -StartAfterInstall, install performs the
save-generation start, stops the temporary pre-host process, restarts into the generated save,
and issues a follow-up save so the runtime slot is ready for later starts. The request remains
pending if the server is not started. This option cannot be combined with an explicit
-SelectedSavePath.

.PARAMETER Port
UDP/TCP port written to Server.conf and used for firewall rules.

.PARAMETER HostPlayerName
Host player name stored in Server.conf. The game defaults to Convict-1 for headless hosts.

.PARAMETER SkipHeadlessPatch
Skips the unsupported Mono.Cecil patching step. Use this only if the target DLL is already patched.

.PARAMETER CleanInstall
Deletes the target install directory before continuing with a SourcePath or SteamCmd installation. When the target
directory already exists, the cmdlet prompts for confirmation before deleting it.

.PARAMETER SkipFirewallRuleUpdate
Skips Windows Firewall rule creation and update. Use this when you are not running an elevated PowerShell session or when firewall rules are managed separately.

.PARAMETER StartAfterInstall
Starts the server after registration completes. When combined with
NewSaveRequestAfterInstall, install creates the requested save first and then restarts into the
generated runtime save.

.PARAMETER Force
Overwrites an existing module registration for the same name or install path.

.EXAMPLE
$saveRoot = Join-Path $env:USERPROFILE 'AppData\LocalLow\MijuGames\Planet Crafter'
Install-PlanetCrafterServer -Name PlanetCrafter_Server -InstallPath (Join-Path $env:SystemDrive 'GameServers\PlanetCrafter_Server') -UseExistingFiles -SaveRootPath $saveRoot -SelectedSavePath (Join-Path $saveRoot 'Standard-1.json')

Adopts an already prepared Planet Crafter server copy and binds it to a specific selected save.

.EXAMPLE
Install-PlanetCrafterServer -Name PlanetCrafter_Test -InstallPath (Join-Path $env:SystemDrive 'GameServers\PlanetCrafter_Test') -SourcePath (Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\common\The Planet Crafter') -Port 7778 -StartAfterInstall

Copies client files from an existing installation, applies the headless patch, registers the new instance, and starts it.

.EXAMPLE
Install-PlanetCrafterServer -Name SaveTest1 -InstallPath (Join-Path $env:SystemDrive 'GameServers\') -SourcePath (Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\common\The Planet Crafter')

Creates or adopts the install in a child folder named SaveTest1 because the target path ends with a separator.

.EXAMPLE
Install-PlanetCrafterServer -Name PlanetCrafter_SteamCmd -InstallPath (Join-Path $env:SystemDrive 'GameServers\PlanetCrafter_SteamCmd') -SteamCredential (Get-Credential) -SteamCmdPath (Join-Path $env:SystemDrive 'SteamCMD\steamcmd.exe')

Attempts a SteamCMD-based install using supplied Steam credentials. If Steam Guard is required, the cmdlet prompts for the code before it proceeds to app_update.

.EXAMPLE
Install-PlanetCrafterServer -Name PlanetCrafter_SteamCmd -InstallPath (Join-Path $env:SystemDrive 'GameServers\PlanetCrafter_SteamCmd') -SteamCredential (Get-Credential) -SteamCmdPath (Join-Path $env:SystemDrive 'SteamCMD\steamcmd.exe') -SteamGuardCode 'ABCD3'

Retries a SteamCMD-based install using a fresh Steam Guard code after Steam has challenged the login.

.EXAMPLE
Install-PlanetCrafterServer -Name PlanetCrafter_Test -InstallPath (Join-Path $env:SystemDrive 'GameServers\PlanetCrafter_Test') -SteamCredential (Get-Credential) -SteamCmdPath (Join-Path $env:SystemDrive 'SteamCMD\steamcmd.exe') -SkipFirewallRuleUpdate

Installs the server files without attempting firewall rule creation. This is useful in non-elevated sessions or when firewall rules are managed elsewhere.

.EXAMPLE
Install-PlanetCrafterServer -Name PlanetCrafter_Test -InstallPath (Join-Path $env:SystemDrive 'GameServers\PlanetCrafter_Test') -SourcePath (Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\common\The Planet Crafter') -CleanInstall

Prompts before wiping the target install directory, then recopies the source files into a clean folder.

.OUTPUTS
PlanetCrafterServer.Info

.NOTES
This module manages an unsupported experimental headless setup. Planet Crafter has no official dedicated server package.
#>
function Install-PlanetCrafterServer {
    [CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'UseExistingFiles')]
    param(
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$InstallPath,

        [Parameter(ParameterSetName = 'UseExistingFiles', Mandatory = $true)]
        [switch]$UseExistingFiles,

        [Parameter(ParameterSetName = 'CopyFiles', Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(ParameterSetName = 'SteamCmd', Mandatory = $true)]
        [pscredential]$SteamCredential,

        [Parameter(ParameterSetName = 'SteamCmd')]
        [string]$SteamCmdPath,

        [Parameter(ParameterSetName = 'SteamCmd')]
        [string]$SteamGuardCode,

        [string]$SaveRootPath = (Get-PCSDefaultSaveRoot),
        [ValidateNotNullOrEmpty()]
        [string]$SaveFileName,
        [string]$SelectedSavePath,
        [string]$NewSaveDisplayName,
        [string]$NewSavePlanetId = 'Prime',
        [string]$NewSaveGameMode = 'Standard',
        [string]$NewSaveStartLocation = 'Standard',
        [string]$NewSaveDyingConsequences = 'NoConsequences',
        [int64]$NewSaveWorldSeed,
        [uint16]$Port = $script:DefaultHostPort,
        [string]$HostPlayerName = $script:DefaultHostPlayerName,
        [switch]$SkipHeadlessPatch,
        [switch]$CleanInstall,
        [switch]$SkipFirewallRuleUpdate,
        [switch]$StartAfterInstall,
        [switch]$NewSaveRequestAfterInstall,
        [switch]$Force
    )

    Initialize-PCSStorage

    $resolvedInstallPath = Resolve-PCSInstallPath -InstallPath $InstallPath -Name $Name
    $resolvedSaveRoot = Resolve-PCSPath -Path $SaveRootPath
    $hasExplicitSelectedSavePath = $PSBoundParameters.ContainsKey('SelectedSavePath') -and -not [string]::IsNullOrWhiteSpace($SelectedSavePath)
    $resolvedSelectedSavePath = $null
    if ($hasExplicitSelectedSavePath) {
        $resolvedSelectedSavePath = Resolve-PCSPath -Path $SelectedSavePath
    }

    $hasNewSaveOptions = @(
        'NewSaveDisplayName',
        'NewSavePlanetId',
        'NewSaveGameMode',
        'NewSaveStartLocation',
        'NewSaveDyingConsequences',
        'NewSaveWorldSeed'
    ) | Where-Object { $PSBoundParameters.ContainsKey($_) } | Select-Object -First 1
    $createNewSave = [bool]$NewSaveRequestAfterInstall -or [bool]$hasNewSaveOptions

    if ($hasExplicitSelectedSavePath -and $createNewSave) {
        throw "Use either -SelectedSavePath or the new-save options, not both. The new-save request and selected-save copy paths are mutually exclusive for install-time setup."
    }

    if (-not $Name) {
        $Name = Split-Path -Leaf $resolvedInstallPath
    }

    if (-not $PSBoundParameters.ContainsKey('SaveFileName')) {
        $SaveFileName = if ($Name.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase)) {
            $Name
        }
        else {
            $Name + '.json'
        }
    }

    if (-not $PSBoundParameters.ContainsKey('NewSaveDisplayName')) {
        $NewSaveDisplayName = Get-PCSNewSaveDisplayName -SaveFileName $SaveFileName
    }

    if ($createNewSave -and -not $hasExplicitSelectedSavePath) {
        $resolvedSelectedSavePath = Resolve-PCSPath -Path (Join-Path $resolvedSaveRoot $SaveFileName)
    }

    if ($StartAfterInstall -and -not $createNewSave -and -not $hasExplicitSelectedSavePath) {
        $existingRuntimeSavePath = Join-Path $resolvedSaveRoot $SaveFileName
        if (-not (Test-Path -LiteralPath $existingRuntimeSavePath)) {
            throw "-StartAfterInstall needs a world to load, but no runtime save exists at '$existingRuntimeSavePath'. Add -NewSaveRequestAfterInstall (or any -NewSave* option) to generate one, or pass -SelectedSavePath to stage an existing save."
        }
    }

    $conflict = @()
    foreach ($instance in Get-PCSRegisteredInstances) {
        if ($instance.Name -eq $Name -or [string]::Compare($instance.InstallPath, $resolvedInstallPath, $true) -eq 0) {
            $conflict += ,$instance
        }
    }

    if (@($conflict).Count -gt 0 -and -not $Force) {
        throw "A Planet Crafter server instance named '$Name' or install path '$resolvedInstallPath' is already registered. Use -Force to update it."
    }

    if (-not $SkipFirewallRuleUpdate) {
        Assert-PCSAdministrator -ActionDescription 'create or update Planet Crafter firewall rules during install'
    }

    if (-not $PSCmdlet.ShouldProcess($resolvedInstallPath, "Install Planet Crafter server instance '$Name'")) {
        return
    }

    if ($CleanInstall) {
        if ($PSCmdlet.ParameterSetName -eq 'UseExistingFiles') {
            throw "CleanInstall cannot be used with -UseExistingFiles because the install directory would be deleted before the cmdlet adopts it. Use -SourcePath or -SteamCredential based installs instead."
        }

        if (Test-Path -LiteralPath $resolvedInstallPath) {
            $pathProcesses = @(Get-PCSProcessesUnderPath -Path $resolvedInstallPath)
            if ($pathProcesses.Count -gt 0) {
                $processSummary = ($pathProcesses | Select-Object -First 5 | ForEach-Object {
                        '{0}({1})' -f $_.Name, $_.ProcessId
                    }) -join ', '
                throw "Cannot perform a clean install because processes are running from '$resolvedInstallPath': $processSummary. Stop them first and retry."
            }

            $shouldDelete = $PSCmdlet.ShouldContinue(
                "CleanInstall will permanently delete '$resolvedInstallPath' and all contents beneath it before installation continues.",
                "Confirm clean install for '$Name'"
            )

            if (-not $shouldDelete) {
                throw 'Clean install cancelled by user.'
            }

            Remove-Item -LiteralPath $resolvedInstallPath -Recurse -Force -ErrorAction Stop
        }

        if (-not (Test-Path -LiteralPath $resolvedInstallPath)) {
            New-Item -Path $resolvedInstallPath -ItemType Directory -Force | Out-Null
        }
    }

    switch ($PSCmdlet.ParameterSetName) {
        'UseExistingFiles' {
            if (-not (Test-Path -LiteralPath $resolvedInstallPath)) {
                throw "Install path '$resolvedInstallPath' does not exist for -UseExistingFiles."
            }
        }
        'CopyFiles' {
            $resolvedSourcePath = Resolve-PCSPath -Path $SourcePath
            if (-not (Test-Path -LiteralPath $resolvedSourcePath)) {
                throw "Source path '$resolvedSourcePath' was not found."
            }

            if (-not (Test-Path -LiteralPath $resolvedInstallPath)) {
                New-Item -Path $resolvedInstallPath -ItemType Directory -Force | Out-Null
            }

            Invoke-PCSRobocopy -Source $resolvedSourcePath -Destination $resolvedInstallPath
        }
        'SteamCmd' {
            if (-not (Test-Path -LiteralPath $resolvedInstallPath)) {
                New-Item -Path $resolvedInstallPath -ItemType Directory -Force | Out-Null
            }
            Invoke-PCSSteamCmdInstall -InstallPath $resolvedInstallPath -SteamCredential $SteamCredential -SteamCmdPath $SteamCmdPath -SteamGuardCode $SteamGuardCode | Out-Null
        }
    }

    $instanceRecord = New-PCSInstanceRecord -Name $Name -InstallPath $resolvedInstallPath -SaveRootPath $resolvedSaveRoot -RuntimeSaveFileName $SaveFileName -SelectedSavePath $resolvedSelectedSavePath -Port $Port -HostPlayerName $HostPlayerName -InstallMethod $PSCmdlet.ParameterSetName

    if (-not $SkipHeadlessPatch) {
        Invoke-PCSPatchAssembly -AssemblyPath (Get-PCSAssemblyPath -Instance $instanceRecord) | Out-Null
    }

    if ($hasExplicitSelectedSavePath) {
        Copy-PCSSelectedSaveToRuntime -Instance $instanceRecord -SourceSavePath $resolvedSelectedSavePath | Out-Null
    }

    Write-PCSServerConfiguration -Instance $instanceRecord | Out-Null
    if (-not $SkipFirewallRuleUpdate) {
        Set-PCSFirewallRules -Instance $instanceRecord
    }
    Save-PCSInstanceRecord -Instance $instanceRecord

    if ($createNewSave) {
        $newSaveSettings = @{
            SaveDisplayName = $NewSaveDisplayName
            PlanetId = if ($NewSavePlanetId) { $NewSavePlanetId } else { 'Prime' }
            GameMode = if ($NewSaveGameMode) { $NewSaveGameMode } else { 'Standard' }
            StartLocation = if ($NewSaveStartLocation) { $NewSaveStartLocation } else { 'Standard' }
            DyingConsequences = if ($NewSaveDyingConsequences) { $NewSaveDyingConsequences } else { 'NoConsequences' }
        }
        if ($PSBoundParameters.ContainsKey('NewSaveWorldSeed')) {
            $newSaveSettings.WorldSeed = [int64]$NewSaveWorldSeed
        }
        Write-PCSNewSaveRequest -Instance $instanceRecord @newSaveSettings | Out-Null
    }

    if ($StartAfterInstall) {
        if ($createNewSave) {
            Assert-PCSPortAvailableForStart -Instance $instanceRecord
            Ensure-PCSInstanceReadyForStart -Instance $instanceRecord
            Write-PCSServerConfiguration -Instance $instanceRecord | Out-Null

            $generationPhaseStarted = $false
            try {
                Start-PCSProcess -Instance $instanceRecord | Out-Null
                $generationPhaseStarted = $true
                $prepared = Wait-PCSNewSavePrepared -Instance $instanceRecord -TimeoutSeconds $script:DefaultReadyTimeoutSeconds
                if (-not $prepared) {
                    throw "Planet Crafter server '$($instanceRecord.Name)' did not finish creating the requested new save '$($instanceRecord.RuntimeSaveFileName)' within $script:DefaultReadyTimeoutSeconds seconds."
                }
            }
            finally {
                if ($generationPhaseStarted -and @(Get-PCSProcessObjects -Instance $instanceRecord).Count -gt 0) {
                    Stop-PCSInstanceProcessesInternal -Instance $instanceRecord -TimeoutSeconds 30 | Out-Null
                }
            }

            Start-PlanetCrafterServer -Name $Name | Out-Null
            Save-PlanetCrafterServer -Name $Name -TimeoutSeconds 30 -Confirm:$false | Out-Null
        }
        else {
            Start-PlanetCrafterServer -Name $Name | Out-Null
        }
    }

    Get-PlanetCrafterServer -Name $Name
}

<#
.SYNOPSIS
Updates configuration for a registered Planet Crafter server instance.

.DESCRIPTION
Set-PlanetCrafterServer changes module-managed settings such as the host port, host player name,
save root, runtime save file name, selected save source, and optionally reapplies the experimental
headless patch. When a selected save is changed, the runtime save slot is refreshed immediately. When
the host player name is changed, the module rewrites the host player record in the current runtime save
if that save already exists, and also reapplies the configured host name again on future starts.

.PARAMETER Name
Logical instance name of the server to update. This parameter is mandatory so changes are always scoped to one specific server registration.

.PARAMETER InstallPath
Install path of the server to update. Use this when the instance name is not known or when you want path-based selection.

.PARAMETER Port
New host port to write to Server.conf and use for firewall rules.

.PARAMETER HostPlayerName
New host player name to write to Server.conf and apply to the host player record in the runtime save on server start.

.PARAMETER SaveRootPath
New save root folder for runtime save and Server.conf files. When the headless patch is
applied, later starts use this folder through a per-process save-root override.

.PARAMETER RuntimeSaveFileName
New runtime save file name for the headless server, such as Server-1.json.

.PARAMETER SelectedSavePath
Save file to copy into the runtime slot and use on later starts.

.PARAMETER ReapplyHeadlessPatch
Reapplies the unsupported headless patch to the managed Assembly-CSharp.dll.

.PARAMETER SkipFirewallRuleUpdate
Skips Windows Firewall rule creation and update. Use this when firewall rules are managed separately or when you are not running an elevated PowerShell session.

.PARAMETER RestartIfRunning
Restarts the server after applying configuration changes if the instance is currently running.

.EXAMPLE
Set-PlanetCrafterServer -Name PlanetCrafter_Server -Port 7778 -RestartIfRunning

Changes the server port and restarts the instance if it is currently running.

.EXAMPLE
$saveRoot = Join-Path $env:USERPROFILE 'AppData\LocalLow\MijuGames\Planet Crafter'
Set-PlanetCrafterServer -Name PlanetCrafter_Server -SelectedSavePath (Join-Path $saveRoot 'Standard-1.json')

Updates the selected save and immediately stages it into the runtime save slot.

.EXAMPLE
Set-PlanetCrafterServer -Name PlanetCrafter_Server -Port 7778 -SkipFirewallRuleUpdate

Changes the configured host port without attempting to rewrite firewall rules in the current session.

.OUTPUTS
PlanetCrafterServer.Info
#>
function Set-PlanetCrafterServer {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,
        [string]$InstallPath,
        [uint16]$Port,
        [string]$HostPlayerName,
        [string]$SaveRootPath,
        [string]$RuntimeSaveFileName,
        [string]$SelectedSavePath,
        [switch]$ReapplyHeadlessPatch,
        [switch]$SkipFirewallRuleUpdate,
        [switch]$RestartIfRunning
    )

    $instance = Resolve-PCSInstance -Name $Name -InstallPath $InstallPath
    $wasRunning = @(Get-PCSProcessObjects -Instance $instance).Count -gt 0
    $oldRuntimePath = Get-PCSRuntimeSavePath -Instance $instance
    $updated = $false
    $shouldWriteServerConfigurationNow = $wasRunning

    if (-not $SkipFirewallRuleUpdate) {
        Assert-PCSAdministrator -ActionDescription 'create or update Planet Crafter firewall rules'
    }

    if (-not $PSCmdlet.ShouldProcess($instance.Name, 'Update Planet Crafter server configuration')) {
        return
    }

    if ($PSBoundParameters.ContainsKey('Port')) {
        Update-PCSInstanceValue -Instance $instance -Key 'HostPort' -Value ([uint16]$Port)
        $updated = $true
    }

    if ($PSBoundParameters.ContainsKey('HostPlayerName')) {
        Update-PCSInstanceValue -Instance $instance -Key 'HostPlayerName' -Value $HostPlayerName
        $updated = $true
    }

    if ($PSBoundParameters.ContainsKey('SaveRootPath')) {
        Update-PCSInstanceValue -Instance $instance -Key 'SaveRootPath' -Value (Resolve-PCSPath -Path $SaveRootPath)
        $updated = $true
    }

    if ($PSBoundParameters.ContainsKey('RuntimeSaveFileName')) {
        Update-PCSInstanceValue -Instance $instance -Key 'RuntimeSaveFileName' -Value $RuntimeSaveFileName
        $updated = $true
    }

    if ($PSBoundParameters.ContainsKey('SelectedSavePath')) {
        Update-PCSInstanceValue -Instance $instance -Key 'SelectedSavePath' -Value (Resolve-PCSPath -Path $SelectedSavePath)
        Copy-PCSSelectedSaveToRuntime -Instance $instance -SourceSavePath $instance.SelectedSavePath | Out-Null
        $updated = $true
    }

    $newRuntimePath = Get-PCSRuntimeSavePath -Instance $instance
    if ([string]::Compare($oldRuntimePath, $newRuntimePath, $true) -ne 0 -and (Test-Path -LiteralPath $oldRuntimePath) -and -not (Test-Path -LiteralPath $newRuntimePath)) {
        $newRuntimeDirectory = Split-Path -Parent $newRuntimePath
        if (-not (Test-Path -LiteralPath $newRuntimeDirectory)) {
            New-Item -Path $newRuntimeDirectory -ItemType Directory -Force | Out-Null
        }
        Copy-Item -LiteralPath $oldRuntimePath -Destination $newRuntimePath -Force
    }

    if ($ReapplyHeadlessPatch) {
        Invoke-PCSPatchAssembly -AssemblyPath (Get-PCSAssemblyPath -Instance $instance) | Out-Null
        $updated = $true
    }

    if ($PSBoundParameters.ContainsKey('HostPlayerName')) {
        $runtimeSavePath = Get-PCSRuntimeSavePath -Instance $instance
        if (Test-Path -LiteralPath $runtimeSavePath) {
            Set-PCSHostPlayerNameInSave -SavePath $runtimeSavePath -HostPlayerName $instance.HostPlayerName -Instance $instance | Out-Null
        }
    }

    if ($updated) {
        if ($shouldWriteServerConfigurationNow) {
            Write-PCSServerConfiguration -Instance $instance | Out-Null
        }
        if (-not $SkipFirewallRuleUpdate) {
            Set-PCSFirewallRules -Instance $instance
        }
        Save-PCSInstanceRecord -Instance $instance
    }

    if ($RestartIfRunning -and $wasRunning) {
        Restart-PlanetCrafterServer -Name $instance.Name | Out-Null
    }

    Get-PlanetCrafterServer -Name $instance.Name
}

function Start-PCSProcess {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Instance
    )

    $logPath = Get-PCSLogPath -Instance $Instance
    $exePath = Get-PCSExecutablePath -Instance $Instance
    $argumentList = @()
    foreach ($arg in $Instance.LaunchArguments) {
        $argumentList += $arg
    }
    $argumentList += '-logFile'
    $argumentList += $logPath

    $previousSaveRoot = [System.Environment]::GetEnvironmentVariable($script:SaveRootEnvironmentVariableName, 'Process')
    $previousSaveSlotName = [System.Environment]::GetEnvironmentVariable($script:SaveSlotNameEnvironmentVariableName, 'Process')
    try {
        [System.Environment]::SetEnvironmentVariable($script:SaveRootEnvironmentVariableName, $Instance.SaveRootPath, 'Process')
        [System.Environment]::SetEnvironmentVariable($script:SaveSlotNameEnvironmentVariableName, (Get-PCSSaveSlotBaseName -Instance $Instance), 'Process')
        Start-Process -FilePath $exePath -WorkingDirectory $Instance.InstallPath -ArgumentList $argumentList -WindowStyle Hidden -PassThru
    }
    finally {
        [System.Environment]::SetEnvironmentVariable($script:SaveRootEnvironmentVariableName, $previousSaveRoot, 'Process')
        [System.Environment]::SetEnvironmentVariable($script:SaveSlotNameEnvironmentVariableName, $previousSaveSlotName, 'Process')
    }
}

function Wait-PCSNewSavePrepared {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Instance,
        [int]$TimeoutSeconds = 90
    )

    $runtimeSavePath = Get-PCSRuntimeSavePath -Instance $Instance
    $requestPath = Join-Path $Instance.SaveRootPath $script:NewSaveRequestFileName
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if ((Test-Path -LiteralPath $runtimeSavePath) -and -not (Test-Path -LiteralPath $requestPath)) {
            return $true
        }

        if (@(Get-PCSProcessObjects -Instance $Instance).Count -eq 0) {
            return $false
        }

        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return $false
}

<#
.SYNOPSIS
Starts a registered Planet Crafter headless server instance.

.DESCRIPTION
Start-PlanetCrafterServer verifies the executable, patched assembly, runtime save, and save root,
rewrites Server.conf, refreshes the runtime save if requested, starts the Planet Crafter process in
headless mode with a per-instance save-root override, and waits for the configured UDP listener to bind.

.PARAMETER Name
Logical instance name of the server to start.

.PARAMETER InstallPath
Install path of the server to start.

.PARAMETER ReadyTimeoutSeconds
Maximum time to wait for the headless server to bind its UDP port.

.PARAMETER RefreshSelectedSave
Copies the configured selected save into the runtime save slot before starting.

.EXAMPLE
Start-PlanetCrafterServer -Name PlanetCrafter_Server

Starts the registered server if it is not already running.

.EXAMPLE
Start-PlanetCrafterServer -Name PlanetCrafter_Server -RefreshSelectedSave -ReadyTimeoutSeconds 120

Starts the server, refreshes the runtime save, and waits up to two minutes for the UDP listener.

.NOTES
This cmdlet refuses to start a server when another running server or process is already using the configured port. If the process starts but never binds its UDP port before the readiness timeout, the cmdlet terminates that failed start so it is not left behind as a half-started process.

.OUTPUTS
PlanetCrafterServer.Info
#>
function Start-PlanetCrafterServer {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Name,
        [string]$InstallPath,
        [int]$ReadyTimeoutSeconds = $script:DefaultReadyTimeoutSeconds,
        [switch]$RefreshSelectedSave
    )

    $instance = Resolve-PCSInstance -Name $Name -InstallPath $InstallPath
    $running = @(Get-PCSProcessObjects -Instance $instance)

    if ($running.Count -gt 0) {
        return Get-PlanetCrafterServer -Name $instance.Name
    }

    if (-not $PSCmdlet.ShouldProcess($instance.Name, 'Start Planet Crafter server')) {
        return
    }

    Assert-PCSPortAvailableForStart -Instance $instance
    Ensure-PCSInstanceReadyForStart -Instance $instance -RefreshSelectedSave:$RefreshSelectedSave
    Write-PCSServerConfiguration -Instance $instance | Out-Null

    $startedProcess = Start-PCSProcess -Instance $instance

    $ready = Wait-PCSReady -Instance $instance -TimeoutSeconds $ReadyTimeoutSeconds
    if (-not $ready) {
        $cleanupAttempted = $false
        $cleanupSucceeded = $false
        $cleanupDetails = $null

        try {
            $cleanupAttempted = $true
            $cleanupResult = Stop-PCSInstanceProcessesInternal -Instance $instance -TimeoutSeconds 15
            $cleanupSucceeded = [bool]$cleanupResult.Succeeded
            if (-not $cleanupSucceeded) {
                if (@($cleanupResult.RemainingProcesses).Count -gt 0) {
                    $cleanupDetails = ' Remaining processes: ' + (@($cleanupResult.RemainingProcesses) -join ', ')
                }
                elseif (@($cleanupResult.Diagnostics).Count -gt 0) {
                    $cleanupDetails = ' Diagnostics: ' + (@($cleanupResult.Diagnostics | Select-Object -Last 5) -join ' | ')
                }
            }
        }
        catch {
            $cleanupDetails = $_.Exception.Message
        }

        $message = "Planet Crafter server '$($instance.Name)' did not bind UDP port $($instance.HostPort) within $ReadyTimeoutSeconds seconds."
        if ($cleanupAttempted) {
            if ($cleanupSucceeded) {
                $message += ' The failed start was terminated automatically.'
            }
            elseif ($cleanupDetails) {
                $message += ' Cleanup was attempted but did not fully succeed.' + $cleanupDetails
            }
            else {
                $message += ' Cleanup was attempted but completion could not be confirmed.'
            }
        }
        elseif ($startedProcess) {
            $message += " The started process id was $($startedProcess.Id)."
        }

        throw $message
    }

    Get-PlanetCrafterServer -Name $instance.Name
}

<#
.SYNOPSIS
Restarts a registered Planet Crafter headless server instance.

.DESCRIPTION
Restart-PlanetCrafterServer stops the instance if it is running and then starts it again, waiting for
the configured UDP listener to bind. It also works for an instance that is currently stopped.

.PARAMETER Name
Logical instance name of the server to restart.

.PARAMETER InstallPath
Install path of the server to restart.

.PARAMETER ReadyTimeoutSeconds
Maximum time to wait for the headless server to bind its UDP port.

.PARAMETER RefreshSelectedSave
Copies the configured selected save into the runtime save slot before starting.

.EXAMPLE
Restart-PlanetCrafterServer -Name PlanetCrafter_Server

Stops the running server and starts it again.

.EXAMPLE
Restart-PlanetCrafterServer -Name PlanetCrafter_Server -RefreshSelectedSave -ReadyTimeoutSeconds 120

Restarts the server, refreshes the runtime save, and waits up to two minutes for the UDP listener.

.OUTPUTS
PlanetCrafterServer.Info
#>
function Restart-PlanetCrafterServer {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Name,
        [string]$InstallPath,
        [int]$ReadyTimeoutSeconds = $script:DefaultReadyTimeoutSeconds,
        [switch]$RefreshSelectedSave
    )

    $instance = Resolve-PCSInstance -Name $Name -InstallPath $InstallPath

    if (-not $PSCmdlet.ShouldProcess($instance.Name, 'Restart Planet Crafter server')) {
        return
    }

    if (@(Get-PCSProcessObjects -Instance $instance).Count -gt 0) {
        Stop-PlanetCrafterServer -Name $instance.Name | Out-Null
    }

    Start-PlanetCrafterServer -Name $instance.Name -ReadyTimeoutSeconds $ReadyTimeoutSeconds -RefreshSelectedSave:$RefreshSelectedSave
}

function Get-PCSNewSaveDisplayName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SaveFileName
    )

    $fileName = [System.IO.Path]::GetFileName($SaveFileName)
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        return 'Planet Crafter Server'
    }

    $displayName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        return $fileName
    }

    $displayName
}

function Resolve-PCSNewSaveStartLocationValue {
    param(
        [string]$PlanetId,
        [string]$StartLocation
    )

    if ([string]::IsNullOrWhiteSpace($StartLocation)) {
        return 'Standard'
    }

    # Keys are lowercased with whitespace removed; values are the exact spawn ids the game stores.
    $startLocationIdMap = @{
        'standard'         = 'Standard'
        'random'           = 'Anywhere'
        'anywhere'         = 'Anywhere'
        'crater'           = 'Crater'
        'meteorcrater'     = 'Crater'
        'grandrift'        = 'GrandRift'
        'sandfalls'        = 'SandFalls'
        'iceplains'        = 'Iceplains'
        'icyplains'        = 'Iceplains'
        'waterfall'        = 'Waterfall'
        'dam'              = 'ToxicityPrison'
        'toxicityprison'   = 'ToxicityPrison'
        'spaceshiparrival' = 'HumbleLanding'
        'humblelanding'    = 'HumbleLanding'
    }

    $lookup = ($StartLocation -replace '\s', '').ToLowerInvariant()
    $resolvedId = if ($startLocationIdMap.ContainsKey($lookup)) { $startLocationIdMap[$lookup] } else { 'Standard' }

    # Fall back to Standard when the id is not a spawn point on the chosen planet, mirroring the game UI.
    $planetSpawnIds = @(
        Get-PCSNewSaveStartLocationCandidates -PlanetId $PlanetId | ForEach-Object {
            $candidateLookup = ($_.Value -replace '\s', '').ToLowerInvariant()
            if ($startLocationIdMap.ContainsKey($candidateLookup)) { $startLocationIdMap[$candidateLookup] }
        }
    )
    if ($planetSpawnIds -notcontains $resolvedId) {
        return 'Standard'
    }

    return $resolvedId
}

function Write-PCSNewSaveRequest {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Instance,
        [ValidateNotNullOrEmpty()]
        [string]$SaveDisplayName = 'Planet Crafter Server',
        [ValidateNotNullOrEmpty()]
        [string]$PlanetId = 'Prime',
        [string]$GameMode = 'Standard',
        [string]$StartLocation = 'Standard',
        [string]$DyingConsequences = 'NoConsequences',
        [int64]$WorldSeed,
        [switch]$FreeCraft,
        [switch]$UnlockedEverything,
        [switch]$UnlockedAutocrafter,
        [switch]$UnlockedDrones,
        [switch]$UnlockedOreExtrators,
        [switch]$UnlockedSpaceTrading,
        [switch]$UnlockedTeleporters,
        [switch]$RandomizeMineables,
        [double]$ModifierTerraformationPace = 1.0,
        [double]$ModifierPowerConsumption = 1.0,
        [double]$ModifierGaugeDrain = 1.0,
        [double]$ModifierMeteoOccurrence = 1.0,
        [double]$ModifierMultiplayerTerraformationFactor = 1.0
    )

    if (-not (Test-Path -LiteralPath $Instance.SaveRootPath)) {
        New-Item -Path $Instance.SaveRootPath -ItemType Directory -Force | Out-Null
    }

    $requestPath = Join-Path $Instance.SaveRootPath $script:NewSaveRequestFileName
    $resolvedStartLocation = Resolve-PCSNewSaveStartLocationValue -PlanetId $PlanetId -StartLocation $StartLocation
    $requestLines = @(
        ([string]$SaveDisplayName -replace '[\r\n]+', ' ').Trim(),
        ([string]$PlanetId).Trim(),
        ([string]$GameMode).Trim(),
        $resolvedStartLocation,
        ([string]$DyingConsequences).Trim(),
        ([bool]$FreeCraft).ToString(),
        ([bool]$UnlockedEverything).ToString(),
        ([bool]$UnlockedAutocrafter).ToString(),
        ([bool]$UnlockedDrones).ToString(),
        ([bool]$UnlockedOreExtrators).ToString(),
        ([bool]$UnlockedSpaceTrading).ToString(),
        ([bool]$UnlockedTeleporters).ToString(),
        ([bool]$RandomizeMineables).ToString(),
        ([double]$ModifierTerraformationPace).ToString(),
        ([double]$ModifierPowerConsumption).ToString(),
        ([double]$ModifierGaugeDrain).ToString(),
        ([double]$ModifierMeteoOccurrence).ToString(),
        ([double]$ModifierMultiplayerTerraformationFactor).ToString(),
        $true.ToString(),
        $(if ($PSBoundParameters.ContainsKey('WorldSeed')) { [string]([uint32]$WorldSeed) } else { '' })
    )

    Set-Content -LiteralPath $requestPath -Value $requestLines -Encoding UTF8
    return $requestPath
}

<#
.SYNOPSIS
Creates a fresh Planet Crafter save request for a running headless server.

.DESCRIPTION
New-PlanetCrafterServerSave asks a running patched headless game to create a fresh save
using the game's native new-save flow on the main thread. The request uses the configured
per-instance save root and is acknowledged when the game consumes and deletes the request.
Use -SaveAfter to issue a follow-up save after the new file is created. For a stopped server,
use Install-PlanetCrafterServer -NewSaveRequestAfterInstall to stage the request for its next
startup instead.

.PARAMETER Name
Logical instance name of the server to update.

.PARAMETER InstallPath
Install path of the server to update.

.PARAMETER SaveDisplayName
Displayed save name for the new save file. If omitted, the base name of the configured runtime
save filename is used.

.PARAMETER PlanetId
Planet id to generate a new save on, such as 'Prime', 'Humble', 'Selenea', or 'Toxicity'.

.PARAMETER GameMode
Game mode for the generated save, such as 'Chill', 'Standard', 'Intense', or 'Creative'.

.PARAMETER StartLocation
Planet spawn location id or friendly label to use for the fresh save. Labels such as
'Sand Falls' are normalized to the game's internal spawn ids automatically.

.PARAMETER DyingConsequences
Dying consequences preset, such as 'NoConsequences' or 'DropSomeItems'.

.PARAMETER WorldSeed
Optional world seed to use for a fresh save.

.PARAMETER TimeoutSeconds
Maximum time to wait for the request to be acknowledged.

.PARAMETER SaveAfter
Requests an immediate post-creation save after the game has processed the new-save request.
This switch is off by default. The generated request marks the new game as intro-complete;
use Complete-PlanetCrafterServerIntro separately if the running game still presents an intro.

.EXAMPLE
New-PlanetCrafterServerSave -Name PlanetCrafter_Server -SaveDisplayName 'FreshWorld' -PlanetId Prime -GameMode Standard -StartLocation 'Sand Falls' -SaveAfter

Creates a fresh Prime save for the running server at the Sand Falls spawn and issues a follow-up save.

.EXAMPLE
Install-PlanetCrafterServer -Name PlanetCrafter_Test -InstallPath (Join-Path $env:SystemDrive 'GameServers\PlanetCrafter_Test') -UseExistingFiles -SaveRootPath (Join-Path $env:ProgramData 'PlanetCrafterServer\Saves\PlanetCrafter_Test') -NewSaveRequestAfterInstall -StartAfterInstall

Stages a fresh save using the default settings, creates it on the first startup, and then restarts into the generated runtime save.

.OUTPUTS
PlanetCrafterServer.NewSaveResult
#>
function New-PlanetCrafterServerSave {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Name,
        [string]$InstallPath,
        [string]$SaveDisplayName,
        [string]$PlanetId = 'Prime',
        [string]$GameMode = 'Standard',
        [string]$StartLocation = 'Standard',
        [string]$DyingConsequences = 'NoConsequences',
        [int64]$WorldSeed,
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 20,
        [switch]$SaveAfter
    )

    $instance = Resolve-PCSInstance -Name $Name -InstallPath $InstallPath
    if (-not $PSBoundParameters.ContainsKey('SaveDisplayName')) {
        $SaveDisplayName = Get-PCSNewSaveDisplayName -SaveFileName $instance.RuntimeSaveFileName
    }

    $processes = @(Get-PCSProcessObjects -Instance $instance)
    if ($processes.Count -eq 0) {
        throw "Planet Crafter server '$($instance.Name)' is not running. The new-save request can be consumed on the next start if the server is launched afterward."
    }

    $patchState = Get-PCSAssemblyPatchState -AssemblyPath (Get-PCSAssemblyPath -Instance $instance)
    if (-not [bool]$patchState.NewSaveRequestPatched) {
        throw "Planet Crafter server '$($instance.Name)' does not have the new-save request patch. Reapply the headless patch with Set-PlanetCrafterServer -Name '$($instance.Name)' -ReapplyHeadlessPatch, then start the server again."
    }

    if (-not $PSCmdlet.ShouldProcess($instance.Name, 'Create a new Planet Crafter save')) {
        return
    }

    if (-not (Test-Path -LiteralPath $instance.SaveRootPath)) {
        New-Item -Path $instance.SaveRootPath -ItemType Directory -Force | Out-Null
    }

    $requestPath = Join-Path $instance.SaveRootPath $script:NewSaveRequestFileName
    if (Test-Path -LiteralPath $requestPath) {
        throw "A new-save request is already pending for Planet Crafter server '$($instance.Name)'. Wait for it to complete or remove '$requestPath' after confirming the server is stopped."
    }

    Write-PCSNewSaveRequest -Instance $instance -SaveDisplayName $SaveDisplayName -PlanetId $PlanetId -GameMode $GameMode -StartLocation $StartLocation -DyingConsequences $DyingConsequences -WorldSeed $WorldSeed -FreeCraft:$false -UnlockedEverything:$false -UnlockedAutocrafter:$false -UnlockedDrones:$false -UnlockedOreExtrators:$false -UnlockedSpaceTrading:$false -UnlockedTeleporters:$false -RandomizeMineables:$false

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (-not (Test-Path -LiteralPath $requestPath)) {
            break
        }

        if (@(Get-PCSProcessObjects -Instance $instance).Count -eq 0) {
            throw "Planet Crafter server '$($instance.Name)' exited before acknowledging the new-save request."
        }

        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    if (Test-Path -LiteralPath $requestPath) {
        throw "Planet Crafter server '$($instance.Name)' did not acknowledge the new-save request within $TimeoutSeconds seconds. The request marker remains at '$requestPath'."
    }

    $saveResult = $null
    if ($SaveAfter) {
        $saveResult = Save-PlanetCrafterServer -Name $instance.Name -TimeoutSeconds $TimeoutSeconds -Confirm:$false
    }

    [pscustomobject]@{
        PSTypeName     = 'PlanetCrafterServer.NewSaveResult'
        Name           = $instance.Name
        SaveRootPath   = $instance.SaveRootPath
        RuntimeSavePath = Get-PCSRuntimeSavePath -Instance $instance
        ProcessID      = @($processes | Select-Object -First 1 | ForEach-Object { $_.ProcessId })
        PlanetId       = $PlanetId
        GameMode       = $GameMode
        StartLocation  = $StartLocation
        CreatedAt      = Get-Date
        SaveAfter      = [bool]$SaveAfter
        SaveResult     = $saveResult
    }
}

<#
.SYNOPSIS
Requests an immediate save from a running Planet Crafter headless server.

.DESCRIPTION
Save-PlanetCrafterServer asks the patched server process to call its native save
routine for the configured runtime save. The cmdlet writes a short-lived request
marker in the instance save root and waits for the server process to remove it
after the save completes.

.PARAMETER Name
Logical instance name of the server to save.

.PARAMETER InstallPath
Install path of the server to save.

.PARAMETER TimeoutSeconds
Maximum time to wait for the running server to acknowledge and complete the save request.

.EXAMPLE
Save-PlanetCrafterServer -Name PlanetCrafter_Server

Requests an immediate save from the running server.

.OUTPUTS
PlanetCrafterServer.SaveResult
#>
function Save-PlanetCrafterServer {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Name,
        [string]$InstallPath,
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 15
    )

    $instance = Resolve-PCSInstance -Name $Name -InstallPath $InstallPath
    $processes = @(Get-PCSProcessObjects -Instance $instance)
    if ($processes.Count -eq 0) {
        throw "Planet Crafter server '$($instance.Name)' is not running."
    }

    $patchState = Get-PCSAssemblyPatchState -AssemblyPath (Get-PCSAssemblyPath -Instance $instance)
    if (-not [bool]$patchState.SaveRequestPatched) {
        throw "Planet Crafter server '$($instance.Name)' does not have the save-request patch. Reapply the headless patch with Set-PlanetCrafterServer -Name '$($instance.Name)' -ReapplyHeadlessPatch, then start the server again."
    }

    if (-not $PSCmdlet.ShouldProcess($instance.Name, 'Save Planet Crafter server')) {
        return
    }

    if (-not (Test-Path -LiteralPath $instance.SaveRootPath)) {
        New-Item -Path $instance.SaveRootPath -ItemType Directory -Force | Out-Null
    }

    $requestPath = Join-Path $instance.SaveRootPath $script:SaveRequestFileName
    if (Test-Path -LiteralPath $requestPath) {
        throw "A save request is already pending for Planet Crafter server '$($instance.Name)'. Wait for it to complete or remove '$requestPath' after confirming the server is stopped."
    }

    $requestValue = [guid]::NewGuid().ToString('N')
    Set-Content -LiteralPath $requestPath -Value $requestValue -Encoding ASCII -NoNewline

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (-not (Test-Path -LiteralPath $requestPath)) {
            [pscustomobject]@{
                PSTypeName     = 'PlanetCrafterServer.SaveResult'
                Name           = $instance.Name
                SaveRootPath   = $instance.SaveRootPath
                RuntimeSavePath = Get-PCSRuntimeSavePath -Instance $instance
                ProcessID      = @($processes | Select-Object -First 1 | ForEach-Object { $_.ProcessId })
                SavedAt        = Get-Date
            }
            return
        }

        if (@(Get-PCSProcessObjects -Instance $instance).Count -eq 0) {
            throw "Planet Crafter server '$($instance.Name)' exited before acknowledging the save request."
        }

        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    throw "Planet Crafter server '$($instance.Name)' did not acknowledge the save request within $TimeoutSeconds seconds. The request marker remains at '$requestPath'."
}

<#
.SYNOPSIS
Skips the active Planet Crafter intro on the running headless server.

.DESCRIPTION
Complete-PlanetCrafterServerIntro asks the patched server process to locate its
active IntroVideoPlayer and execute the game's intro-completion path on the
Unity main thread. After the intro request is acknowledged, the cmdlet saves
the server by default so clients can join the post-intro world state.

.PARAMETER Name
Logical instance name of the server whose intro should be completed.

.PARAMETER InstallPath
Install path of the server whose intro should be completed.

.PARAMETER TimeoutSeconds
Maximum time to wait for the server to acknowledge the intro request and, by
default, the follow-up save request.

.PARAMETER SaveAfter
Controls whether the cmdlet saves after the intro skip. Saving is enabled by
default; use -SaveAfter:$false to skip the follow-up save.

.EXAMPLE
Complete-PlanetCrafterServerIntro -Name PlanetCrafter_Server

Completes the active intro and saves the resulting post-intro state.

.EXAMPLE
Complete-PlanetCrafterServerIntro -Name PlanetCrafter_Server -SaveAfter:$false

Completes the active intro without issuing the follow-up save request.

.OUTPUTS
PlanetCrafterServer.IntroResult
#>
function Complete-PlanetCrafterServerIntro {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Name,
        [string]$InstallPath,
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 15,
        [switch]$SaveAfter
    )

    $instance = Resolve-PCSInstance -Name $Name -InstallPath $InstallPath
    $processes = @(Get-PCSProcessObjects -Instance $instance)
    if ($processes.Count -eq 0) {
        throw "Planet Crafter server '$($instance.Name)' is not running."
    }

    $patchState = Get-PCSAssemblyPatchState -AssemblyPath (Get-PCSAssemblyPath -Instance $instance)
    if (-not [bool]$patchState.IntroSkipRequestPatched) {
        throw "Planet Crafter server '$($instance.Name)' does not have the intro-skip patch. Reapply the headless patch with Set-PlanetCrafterServer -Name '$($instance.Name)' -ReapplyHeadlessPatch, then start the server again."
    }

    if (-not $PSCmdlet.ShouldProcess($instance.Name, 'Complete Planet Crafter intro')) {
        return
    }

    if (-not (Test-Path -LiteralPath $instance.SaveRootPath)) {
        New-Item -Path $instance.SaveRootPath -ItemType Directory -Force | Out-Null
    }

    $requestPath = Join-Path $instance.SaveRootPath $script:IntroSkipRequestFileName
    if (Test-Path -LiteralPath $requestPath) {
        throw "An intro-skip request is already pending for Planet Crafter server '$($instance.Name)'. Wait for it to complete or remove '$requestPath' after confirming the server is stopped."
    }

    Set-Content -LiteralPath $requestPath -Value ([guid]::NewGuid().ToString('N')) -Encoding ASCII -NoNewline
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (-not (Test-Path -LiteralPath $requestPath)) {
            break
        }

        if (@(Get-PCSProcessObjects -Instance $instance).Count -eq 0) {
            throw "Planet Crafter server '$($instance.Name)' exited before acknowledging the intro-skip request."
        }

        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    if (Test-Path -LiteralPath $requestPath) {
        throw "Planet Crafter server '$($instance.Name)' did not acknowledge the intro-skip request within $TimeoutSeconds seconds. The request marker remains at '$requestPath'."
    }

    $introCompletedAt = Get-Date
    $saveAfterRequested = $true
    if ($PSBoundParameters.ContainsKey('SaveAfter')) {
        $saveAfterRequested = [bool]$SaveAfter
    }

    $saveResult = $null
    if ($saveAfterRequested) {
        $saveResult = Save-PlanetCrafterServer -Name $instance.Name -TimeoutSeconds $TimeoutSeconds -Confirm:$false
    }

    [pscustomobject]@{
        PSTypeName      = 'PlanetCrafterServer.IntroResult'
        Name            = $instance.Name
        SaveRootPath    = $instance.SaveRootPath
        RuntimeSavePath = Get-PCSRuntimeSavePath -Instance $instance
        ProcessID       = @($processes | Select-Object -First 1 | ForEach-Object { $_.ProcessId })
        SaveAfter       = $saveAfterRequested
        IntroCompletedAt = $introCompletedAt
        SaveResult      = $saveResult
    }
}

<#
.SYNOPSIS
Stops a running Planet Crafter headless server instance.

.DESCRIPTION
Stop-PlanetCrafterServer locates running Planet Crafter processes for the registered instance and
terminates them, then waits for the process to exit. If the initial stop does not clear the process
quickly, the cmdlet falls back to taskkill for stubborn process trees. If the server is already
stopped, the current server state is returned unchanged.

.PARAMETER Name
Logical instance name of the server to stop.

.PARAMETER InstallPath
Install path of the server to stop.

.PARAMETER StopTimeoutSeconds
Maximum time to wait for the server process to exit after it has been told to stop.

.EXAMPLE
Stop-PlanetCrafterServer -Name PlanetCrafter_Server

Stops the registered server instance if it is currently running.

.EXAMPLE
Stop-PlanetCrafterServer -Name PlanetCrafter_Server -StopTimeoutSeconds 60

Stops the server and waits up to one minute for the process to exit cleanly.

.OUTPUTS
PlanetCrafterServer.Info
#>
function Stop-PlanetCrafterServer {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Name,
        [string]$InstallPath,
        [int]$StopTimeoutSeconds = 30
    )

    $instance = Resolve-PCSInstance -Name $Name -InstallPath $InstallPath
    $processes = @(Get-PCSProcessObjects -Instance $instance)

    if ($processes.Count -eq 0) {
        return Get-PlanetCrafterServer -Name $instance.Name
    }

    if ($PSCmdlet.ShouldProcess($instance.Name, 'Stop Planet Crafter server')) {
        $stopResult = Stop-PCSInstanceProcessesInternal -Instance $instance -TimeoutSeconds $StopTimeoutSeconds
        if (-not [bool]$stopResult.Succeeded) {
            $message = "Planet Crafter server '$($instance.Name)' did not stop within $StopTimeoutSeconds seconds."
            if (@($stopResult.RemainingProcesses).Count -gt 0) {
                $message += ' Remaining processes: ' + (@($stopResult.RemainingProcesses) -join ', ')
            }
            elseif (@($stopResult.Diagnostics).Count -gt 0) {
                $message += ' Diagnostics: ' + (@($stopResult.Diagnostics | Select-Object -Last 5) -join ' | ')
            }
            throw $message
        }
    }

    Get-PlanetCrafterServer -Name $instance.Name
}

<#
.SYNOPSIS
Returns detailed status and configuration for registered Planet Crafter server instances.

.DESCRIPTION
Get-PlanetCrafterServer inspects the module registration, save metadata, headless patch state,
Server.conf values, live process information, UDP/TCP endpoint state, selected save information,
and optionally a tail of the current server log.

.PARAMETER Name
One or more logical instance names to return.

.PARAMETER InstallPath
Specific install path to match when selecting an instance.

.PARAMETER IncludeLogTail
Includes the last lines from the current server log in the returned object.

.PARAMETER TailLines
Number of log lines to include when -IncludeLogTail is used.

.EXAMPLE
Get-PlanetCrafterServer

Returns all registered Planet Crafter server instances.

.EXAMPLE
Get-PlanetCrafterServer -Name PlanetCrafter_Server -IncludeLogTail -TailLines 100

Returns a detailed view of a specific instance and includes the last 100 log lines.

.OUTPUTS
PlanetCrafterServer.Info
#>
function Get-PlanetCrafterServer {
    [CmdletBinding()]
    param(
        [string[]]$Name,
        [string]$InstallPath,
        [switch]$IncludeLogTail,
        [int]$TailLines = 40
    )

    $instances = @(Get-PCSRegisteredInstances -Name $Name -InstallPath $InstallPath)
    foreach ($instance in $instances) {
        Get-PCSInstanceInfo -Instance $instance -IncludeLogTail:$IncludeLogTail -TailLines $TailLines
    }
}

<#
.SYNOPSIS
Removes a registered Planet Crafter server instance and optionally its save data.

.DESCRIPTION
Uninstall-PlanetCrafterServer stops the server, removes module metadata, deletes firewall rules,
deletes the entire install folder, and optionally removes the save data. When the instance uses a
dedicated save folder, that whole folder is deleted as well; otherwise only the runtime save and
Server.conf files are removed. Use -WhatIf to preview the removal without changing the working server.

.PARAMETER Name
Logical instance name of the server to uninstall.

.PARAMETER InstallPath
Install path of the server to uninstall.

.PARAMETER KeepSaveData
Preserves the runtime save and Server.conf files while removing the installation and module metadata.

.EXAMPLE
Uninstall-PlanetCrafterServer -Name PlanetCrafter_Test

Stops and removes the test server instance, including its install directory and runtime save files.

.EXAMPLE
Uninstall-PlanetCrafterServer -Name PlanetCrafter_Server -KeepSaveData -WhatIf

Shows what would be removed while preserving save files if the command were executed for real.

.OUTPUTS
PlanetCrafterServer.UninstallResult
#>
function Uninstall-PlanetCrafterServer {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Name,
        [string]$InstallPath,
        [switch]$KeepSaveData
    )

    $instance = Resolve-PCSInstance -Name $Name -InstallPath $InstallPath

    if (-not $PSCmdlet.ShouldProcess($instance.Name, 'Uninstall Planet Crafter server')) {
        return
    }

    Stop-PlanetCrafterServer -Name $instance.Name | Out-Null

    $removedPaths = @()
    $runtimeSavePath = Get-PCSRuntimeSavePath -Instance $instance
    $serverConfigPath = Get-PCSServerConfigPath -Instance $instance
    $metadataPath = Get-PCSInstanceFilePath -Name $instance.Name
    $backupRoot = Get-PCSBackupRootForInstance -Instance $instance

    Remove-PCSFirewallRules -Instance $instance

    if (-not $KeepSaveData) {
        $instanceSaveRoot = Resolve-PCSPath -Path $instance.SaveRootPath
        $sharedSaveRoots = @(Resolve-PCSPath -Path (Get-PCSDefaultSaveRoot))
        foreach ($other in @(Get-PCSRegisteredInstances | Where-Object { $_.Name -ne $instance.Name })) {
            if ($other.SaveRootPath) {
                $sharedSaveRoots += ,(Resolve-PCSPath -Path $other.SaveRootPath)
            }
        }

        $saveRootIsDedicated = -not ($sharedSaveRoots | Where-Object { $_.TrimEnd('\') -eq $instanceSaveRoot.TrimEnd('\') })

        if ($saveRootIsDedicated -and (Test-Path -LiteralPath $instanceSaveRoot)) {
            Remove-PCSDirectoryTree -Path $instanceSaveRoot
            $removedPaths += ,$instanceSaveRoot
        }
        else {
            foreach ($path in @($runtimeSavePath, $serverConfigPath)) {
                if (Test-Path -LiteralPath $path) {
                    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                    $removedPaths += ,$path
                }
            }
        }
    }

    if (Test-Path -LiteralPath $instance.InstallPath) {
        Remove-PCSDirectoryTree -Path $instance.InstallPath
        $removedPaths += ,$instance.InstallPath
    }

    if (Test-Path -LiteralPath $metadataPath) {
        Remove-Item -LiteralPath $metadataPath -Force -ErrorAction SilentlyContinue
        $removedPaths += ,$metadataPath
    }

    if (Test-Path -LiteralPath $backupRoot) {
        Remove-PCSDirectoryTree -Path $backupRoot
        $removedPaths += ,$backupRoot
    }

    [pscustomobject]@{
        PSTypeName   = 'PlanetCrafterServer.UninstallResult'
        Name         = $instance.Name
        RemovedPaths = $removedPaths
        KeepSaveData = [bool]$KeepSaveData
    }
}

function ConvertTo-PCSCompletionText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    if ($Text -match '[\s'']') {
        return "'" + $Text.Replace("'", "''") + "'"
    }

    $Text
}

function Get-PCSCleanWordToComplete {
    param([string]$WordToComplete)

    if ($null -eq $WordToComplete) {
        return ''
    }

    $WordToComplete.Trim("'", '"')
}

function Test-PCSCompletionMatch {
    param(
        [string]$Candidate,
        [string]$WordToComplete
    )

    $cleanWord = Get-PCSCleanWordToComplete -WordToComplete $WordToComplete
    if ([string]::IsNullOrEmpty($cleanWord)) {
        return $true
    }

    $Candidate -like ($cleanWord + '*')
}

function Test-PCSCompletionAnyMatch {
    param(
        [string[]]$Candidates,
        [string]$WordToComplete
    )

    foreach ($candidate in $Candidates) {
        if (Test-PCSCompletionMatch -Candidate $candidate -WordToComplete $WordToComplete) {
            return $true
        }
    }

    return $false
}

function New-PCSCompletionResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CompletionValue,
        [string]$ListItemText,
        [string]$ToolTip
    )

    if (-not $ListItemText) {
        $ListItemText = $CompletionValue
    }

    if (-not $ToolTip) {
        $ToolTip = $CompletionValue
    }

    $completionText = ConvertTo-PCSCompletionText -Text $CompletionValue
    [System.Management.Automation.CompletionResult]::new($completionText, $ListItemText, 'ParameterValue', $ToolTip)
}

function Get-PCSCompletionCommonInstallCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($steamRoot in @(${env:ProgramFiles(x86)}, $env:ProgramFiles) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) {
        $candidates.Add((Join-Path $steamRoot 'Steam\steamapps\common\The Planet Crafter')) | Out-Null
    }

    foreach ($path in @(Get-PCSRegisteredInstances | ForEach-Object { $_.InstallPath })) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $candidates.Add($path) | Out-Null
        }
    }

    $candidates | Where-Object { $_ } | Select-Object -Unique
}

function Get-PCSCompletionCommonSteamCmdCandidates {
    $candidates = New-Object System.Collections.Generic.List[string]

    $steamCmdCommand = Get-Command steamcmd.exe -ErrorAction SilentlyContinue | Where-Object { $_.CommandType -eq 'Application' } | Select-Object -ExpandProperty Source -First 1
    if (-not [string]::IsNullOrWhiteSpace($steamCmdCommand)) {
        $candidates.Add($steamCmdCommand) | Out-Null
    }

    foreach ($path in @(
            $(if ($env:SystemDrive) { Join-Path $env:SystemDrive 'SteamCMD\steamcmd.exe' } else { $null }),
            $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Steam\steamcmd.exe' } else { $null }),
            $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Steam\steamcmd.exe' } else { $null })
        )) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $candidates.Add($path) | Out-Null
        }
    }

    $candidates | Where-Object { $_ } | Select-Object -Unique
}

function Get-PCSCompletionSaveRootsFromContext {
    param($FakeBoundParameters)

    $roots = New-Object System.Collections.Generic.List[string]
    $roots.Add((Get-PCSDefaultSaveRoot)) | Out-Null

    if (Test-PCSMapContains -Map $FakeBoundParameters -Key 'SaveRootPath') {
        try {
            $roots.Add((Resolve-PCSPath -Path $FakeBoundParameters['SaveRootPath'])) | Out-Null
        }
        catch {
        }
    }

    if ((Test-PCSMapContains -Map $FakeBoundParameters -Key 'Name') -or (Test-PCSMapContains -Map $FakeBoundParameters -Key 'InstallPath')) {
        try {
            $instance = Resolve-PCSInstance -Name $FakeBoundParameters['Name'] -InstallPath $FakeBoundParameters['InstallPath']
            if ($instance) {
                $roots.Add($instance.SaveRootPath) | Out-Null
            }
        }
        catch {
        }
    }

    @(($roots | Where-Object { $_ } | Select-Object -Unique))
}

function Complete-PCSInstanceName {
    param([string]$WordToComplete, $FakeBoundParameters)

    $instances = @(Get-PCSRegisteredInstances)
    $matched = @($instances | Where-Object { Test-PCSCompletionMatch -Candidate $_.Name -WordToComplete $WordToComplete })
    if ($matched.Count -eq 0) {
        $matched = $instances
    }

    foreach ($instance in $matched) {
        New-PCSCompletionResult -CompletionValue $instance.Name -ToolTip $instance.InstallPath
    }
}

function Complete-PCSRegisteredInstallPath {
    param([string]$WordToComplete, $FakeBoundParameters)

    $instances = @(Get-PCSRegisteredInstances)
    $matched = @($instances | Where-Object {
            Test-PCSCompletionAnyMatch -Candidates @($_.InstallPath, $_.Name) -WordToComplete $WordToComplete
        })
    if ($matched.Count -eq 0) {
        $matched = $instances
    }

    foreach ($instance in $matched) {
        if ($instance.InstallPath -and (Test-Path -LiteralPath $instance.InstallPath)) {
            New-PCSCompletionResult -CompletionValue $instance.InstallPath -ToolTip $instance.Name
        }
    }
}

function Complete-PCSInstallSourcePath {
    param([string]$WordToComplete, $FakeBoundParameters)

    foreach ($path in @(Get-PCSCompletionCommonInstallCandidates)) {
        if ((Test-Path -LiteralPath $path) -and (Test-PCSCompletionAnyMatch -Candidates @($path, (Split-Path -Leaf $path)) -WordToComplete $WordToComplete)) {
            New-PCSCompletionResult -CompletionValue $path -ToolTip 'Planet Crafter source path'
        }
    }
}

function Complete-PCSSteamCmdPath {
    param([string]$WordToComplete, $FakeBoundParameters)

    foreach ($path in @(Get-PCSCompletionCommonSteamCmdCandidates)) {
        if ((Test-Path -LiteralPath $path) -and (Test-PCSCompletionAnyMatch -Candidates @($path, (Split-Path -Leaf $path)) -WordToComplete $WordToComplete)) {
            New-PCSCompletionResult -CompletionValue $path -ToolTip 'steamcmd.exe'
        }
    }
}

function Complete-PCSSaveRootPath {
    param([string]$WordToComplete, $FakeBoundParameters)

    foreach ($path in @(Get-PCSCompletionSaveRootsFromContext -FakeBoundParameters $FakeBoundParameters)) {
        if ((Test-Path -LiteralPath $path) -and (Test-PCSCompletionAnyMatch -Candidates @($path, (Split-Path -Leaf $path)) -WordToComplete $WordToComplete)) {
            New-PCSCompletionResult -CompletionValue $path -ToolTip 'Planet Crafter save root'
        }
    }
}

function Complete-PCSRuntimeSaveFileName {
    param([string]$WordToComplete, $FakeBoundParameters)

    $names = New-Object System.Collections.Generic.List[string]
    $names.Add($script:DefaultRuntimeSaveFileName) | Out-Null
    $names.Add('Standard-1.json') | Out-Null

    foreach ($root in @(Get-PCSCompletionSaveRootsFromContext -FakeBoundParameters $FakeBoundParameters)) {
        if (Test-Path -LiteralPath $root) {
            foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue) {
                $names.Add($file.Name) | Out-Null
            }
        }
    }

    foreach ($name in @($names | Select-Object -Unique)) {
        if (Test-PCSCompletionMatch -Candidate $name -WordToComplete $WordToComplete) {
            New-PCSCompletionResult -CompletionValue $name
        }
    }
}

function Get-PCSNewSavePlanetCandidates {
    @(
        [pscustomobject]@{ Value = 'Prime'; Description = 'Prime planet' }
        [pscustomobject]@{ Value = 'Humble'; Description = 'Humble planet' }
        [pscustomobject]@{ Value = 'Selenea'; Description = 'Selenea planet' }
        [pscustomobject]@{ Value = 'Toxicity'; Description = 'Toxicity planet' }
    )
}

function Get-PCSNewSaveGameModeCandidates {
    @(
        [pscustomobject]@{ Value = 'Chill'; Description = 'Chill difficulty' }
        [pscustomobject]@{ Value = 'Standard'; Description = 'Standard difficulty' }
        [pscustomobject]@{ Value = 'Intense'; Description = 'Intense difficulty' }
        [pscustomobject]@{ Value = 'Hardcore'; Description = 'Hardcore difficulty' }
        [pscustomobject]@{ Value = 'Creative'; Description = 'Creative mode' }
        [pscustomobject]@{ Value = 'Custom'; Description = 'Custom settings' }
    )
}

function Get-PCSNewSaveDyingConsequencesCandidates {
    @(
        [pscustomobject]@{ Value = 'NoConsequences'; Description = 'Keep inventory on death' }
        [pscustomobject]@{ Value = 'DropSomeItems'; Description = 'Drop some items on death' }
        [pscustomobject]@{ Value = 'DropAllItems'; Description = 'Drop all items on death' }
        [pscustomobject]@{ Value = 'DeleteSaveFile'; Description = 'Delete the save on death' }
    )
}

function Get-PCSNewSaveStartLocationCandidates {
    param([string]$PlanetId)

    if ([string]::IsNullOrWhiteSpace($PlanetId)) {
        $PlanetId = 'Prime'
    }

    switch ($PlanetId.ToLowerInvariant()) {
        'prime' {
            @(
                [pscustomobject]@{ Value = 'Standard'; Description = 'Prime: standard spawn' }
                [pscustomobject]@{ Value = 'Grand Rift'; Description = 'Prime: Grand Rift' }
                [pscustomobject]@{ Value = 'Sand Falls'; Description = 'Prime: Sand Falls' }
                [pscustomobject]@{ Value = 'Meteor Crater'; Description = 'Prime: Meteor Crater' }
                [pscustomobject]@{ Value = 'Waterfall'; Description = 'Prime: Waterfall' }
                [pscustomobject]@{ Value = 'Ice plains'; Description = 'Prime: Ice plains' }
                [pscustomobject]@{ Value = 'Random'; Description = 'Prime: random spawn' }
            )
        }
        'humble' {
            @(
                [pscustomobject]@{ Value = 'Standard'; Description = 'Humble: standard spawn' }
                [pscustomobject]@{ Value = 'Spaceship arrival'; Description = 'Humble: Spaceship arrival' }
            )
        }
        'selenea' {
            @(
                [pscustomobject]@{ Value = 'Standard'; Description = 'Selenea: standard spawn' }
            )
        }
        'toxicity' {
            @(
                [pscustomobject]@{ Value = 'Standard'; Description = 'Toxicity: standard spawn' }
                [pscustomobject]@{ Value = 'Dam'; Description = 'Toxicity: Dam' }
            )
        }
        default {
            @(
                [pscustomobject]@{ Value = 'Standard'; Description = 'Standard spawn' }
            )
        }
    }
}

function Get-PCSNewSaveSettingsFromRoots {
    param([string[]]$Roots)

    foreach ($root in @($Roots | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            try {
                $sections = (Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop) -split '@', 0, 'SimpleMatch'
                if ($sections.Count -le 8 -or [string]::IsNullOrWhiteSpace($sections[8])) {
                    continue
                }

                $settings = $sections[8].Trim() | ConvertFrom-Json -ErrorAction Stop
                if ($settings) {
                    [pscustomobject]@{
                        FileName = $file.Name
                        Settings = $settings
                    }
                }
            }
            catch {
                continue
            }
        }
    }
}

function Complete-PCSNewSaveDisplayName {
    param([string]$WordToComplete, $FakeBoundParameters)

    $names = New-Object System.Collections.Generic.List[string]
    $names.Add('Planet Crafter Server') | Out-Null

    if (Test-PCSMapContains -Map $FakeBoundParameters -Key 'SaveFileName') {
        $saveFileName = [string]$FakeBoundParameters['SaveFileName']
        if (-not [string]::IsNullOrWhiteSpace($saveFileName)) {
            $names.Add((Get-PCSNewSaveDisplayName -SaveFileName $saveFileName)) | Out-Null
        }
    }

    if (Test-PCSMapContains -Map $FakeBoundParameters -Key 'Name') {
        $name = [string]$FakeBoundParameters['Name']
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $names.Add($name) | Out-Null
        }
    }

    if (-not (Test-PCSMapContains -Map $FakeBoundParameters -Key 'SaveFileName') -and
        (Test-PCSMapContains -Map $FakeBoundParameters -Key 'Name')) {
        try {
            $instance = Resolve-PCSInstance -Name $FakeBoundParameters['Name'] -InstallPath $FakeBoundParameters['InstallPath']
            if ($instance.RuntimeSaveFileName) {
                $names.Add((Get-PCSNewSaveDisplayName -SaveFileName $instance.RuntimeSaveFileName)) | Out-Null
            }
        }
        catch {
        }
    }

    foreach ($entry in @(Get-PCSNewSaveSettingsFromRoots -Roots (Get-PCSCompletionSaveRootsFromContext -FakeBoundParameters $FakeBoundParameters))) {
        if ($entry.Settings.PSObject.Properties['saveDisplayName'] -and -not [string]::IsNullOrWhiteSpace([string]$entry.Settings.saveDisplayName)) {
            $names.Add([string]$entry.Settings.saveDisplayName) | Out-Null
        }
    }

    foreach ($name in @($names | Select-Object -Unique)) {
        if (Test-PCSCompletionMatch -Candidate $name -WordToComplete $WordToComplete) {
            New-PCSCompletionResult -CompletionValue $name
        }
    }
}

function Complete-PCSNewSavePlanetId {
    param([string]$WordToComplete, $FakeBoundParameters)

    foreach ($candidate in Get-PCSNewSavePlanetCandidates) {
        if (Test-PCSCompletionMatch -Candidate $candidate.Value -WordToComplete $WordToComplete) {
            New-PCSCompletionResult -CompletionValue $candidate.Value -ToolTip $candidate.Description
        }
    }
}

function Complete-PCSNewSaveGameMode {
    param([string]$WordToComplete, $FakeBoundParameters)

    foreach ($candidate in Get-PCSNewSaveGameModeCandidates) {
        if (Test-PCSCompletionMatch -Candidate $candidate.Value -WordToComplete $WordToComplete) {
            New-PCSCompletionResult -CompletionValue $candidate.Value -ToolTip $candidate.Description
        }
    }
}

function Complete-PCSNewSaveStartLocation {
    param([string]$WordToComplete, $FakeBoundParameters)

    $planetId = 'Prime'
    if (Test-PCSMapContains -Map $FakeBoundParameters -Key 'NewSavePlanetId') {
        $planetId = [string]$FakeBoundParameters['NewSavePlanetId']
    }
    elseif (Test-PCSMapContains -Map $FakeBoundParameters -Key 'PlanetId') {
        $planetId = [string]$FakeBoundParameters['PlanetId']
    }

    foreach ($candidate in Get-PCSNewSaveStartLocationCandidates -PlanetId $planetId) {
        if (Test-PCSCompletionMatch -Candidate $candidate.Value -WordToComplete $WordToComplete) {
            New-PCSCompletionResult -CompletionValue $candidate.Value -ToolTip $candidate.Description
        }
    }
}

function Complete-PCSNewSaveDyingConsequences {
    param([string]$WordToComplete, $FakeBoundParameters)

    foreach ($candidate in Get-PCSNewSaveDyingConsequencesCandidates) {
        if (Test-PCSCompletionMatch -Candidate $candidate.Value -WordToComplete $WordToComplete) {
            New-PCSCompletionResult -CompletionValue $candidate.Value -ToolTip $candidate.Description
        }
    }
}

function Complete-PCSNewSaveWorldSeed {
    param([string]$WordToComplete, $FakeBoundParameters)

    $seeds = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(Get-PCSNewSaveSettingsFromRoots -Roots (Get-PCSCompletionSaveRootsFromContext -FakeBoundParameters $FakeBoundParameters))) {
        if ($entry.Settings.PSObject.Properties['worldSeed']) {
            $seed = [string]$entry.Settings.worldSeed
            if (-not [string]::IsNullOrWhiteSpace($seed)) {
                $seeds.Add($seed) | Out-Null
            }
        }
    }

    foreach ($seed in @($seeds | Select-Object -Unique)) {
        if (Test-PCSCompletionMatch -Candidate $seed -WordToComplete $WordToComplete) {
            New-PCSCompletionResult -CompletionValue $seed -ToolTip 'World seed from an existing save'
        }
    }
}

function Complete-PCSSavePath {
    param([string]$WordToComplete, $FakeBoundParameters)

    foreach ($root in @(Get-PCSCompletionSaveRootsFromContext -FakeBoundParameters $FakeBoundParameters)) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        foreach ($file in Get-ChildItem -LiteralPath $root -Filter '*.json' -File -ErrorAction SilentlyContinue) {
            if (Test-PCSCompletionAnyMatch -Candidates @($file.FullName, $file.Name, [System.IO.Path]::GetFileNameWithoutExtension($file.Name)) -WordToComplete $WordToComplete) {
                New-PCSCompletionResult -CompletionValue $file.FullName -ToolTip $file.Name
            }
        }
    }
}

function Complete-PCSHostPlayerName {
    param([string]$WordToComplete, $FakeBoundParameters)

    foreach ($name in @($script:DefaultHostPlayerName, 'Convict-1') | Select-Object -Unique) {
        if (Test-PCSCompletionMatch -Candidate $name -WordToComplete $WordToComplete) {
            New-PCSCompletionResult -CompletionValue $name
        }
    }
}

function Complete-PCSPort {
    param([string]$WordToComplete, $FakeBoundParameters)

    foreach ($port in @('7777', '7778', '7779', '27015')) {
        if (Test-PCSCompletionMatch -Candidate $port -WordToComplete $WordToComplete) {
            New-PCSCompletionResult -CompletionValue $port -ToolTip 'Common Planet Crafter / test port'
        }
    }
}

function Register-PCSCompleter {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$CommandName,
        [Parameter(Mandatory = $true)]
        [string]$ParameterName,
        [Parameter(Mandatory = $true)]
        [string]$ResolverFunction
    )

    $scriptBlock = {
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        $module = Get-Module PlanetCrafterServer
        if (-not $module) {
            return
        }

        & $module {
            param($resolverFunction, $wordToComplete, $fakeBoundParameters)
            & $resolverFunction -WordToComplete $wordToComplete -FakeBoundParameters $fakeBoundParameters
        } $ResolverFunction $wordToComplete $fakeBoundParameters
    }.GetNewClosure()

    Register-ArgumentCompleter -CommandName $CommandName -ParameterName $ParameterName -ScriptBlock $scriptBlock
}

function Initialize-PCSArgumentCompleters {
    Register-PCSCompleter -CommandName @(
        'Get-PlanetCrafterServer',
        'Start-PlanetCrafterServer',
        'Restart-PlanetCrafterServer',
        'New-PlanetCrafterServerSave',
        'Save-PlanetCrafterServer',
        'Complete-PlanetCrafterServerIntro',
        'Stop-PlanetCrafterServer',
        'Set-PlanetCrafterServer',
        'Install-PlanetCrafterServer',
        'Uninstall-PlanetCrafterServer'
    ) -ParameterName 'Name' -ResolverFunction 'Complete-PCSInstanceName'

    Register-PCSCompleter -CommandName @(
        'Get-PlanetCrafterServer',
        'Start-PlanetCrafterServer',
        'Restart-PlanetCrafterServer',
        'New-PlanetCrafterServerSave',
        'Save-PlanetCrafterServer',
        'Complete-PlanetCrafterServerIntro',
        'Stop-PlanetCrafterServer',
        'Set-PlanetCrafterServer',
        'Uninstall-PlanetCrafterServer'
    ) -ParameterName 'InstallPath' -ResolverFunction 'Complete-PCSRegisteredInstallPath'

    Register-PCSCompleter -CommandName 'Install-PlanetCrafterServer' -ParameterName 'SourcePath' -ResolverFunction 'Complete-PCSInstallSourcePath'
    Register-PCSCompleter -CommandName 'Install-PlanetCrafterServer' -ParameterName 'SteamCmdPath' -ResolverFunction 'Complete-PCSSteamCmdPath'
    Register-PCSCompleter -CommandName @('Install-PlanetCrafterServer', 'Set-PlanetCrafterServer') -ParameterName 'SaveRootPath' -ResolverFunction 'Complete-PCSSaveRootPath'
    Register-PCSCompleter -CommandName @('Install-PlanetCrafterServer', 'Set-PlanetCrafterServer') -ParameterName 'SelectedSavePath' -ResolverFunction 'Complete-PCSSavePath'
    Register-PCSCompleter -CommandName 'Install-PlanetCrafterServer' -ParameterName 'SaveFileName' -ResolverFunction 'Complete-PCSRuntimeSaveFileName'
    Register-PCSCompleter -CommandName 'Set-PlanetCrafterServer' -ParameterName 'RuntimeSaveFileName' -ResolverFunction 'Complete-PCSRuntimeSaveFileName'
    Register-PCSCompleter -CommandName 'Install-PlanetCrafterServer' -ParameterName 'NewSaveDisplayName' -ResolverFunction 'Complete-PCSNewSaveDisplayName'
    Register-PCSCompleter -CommandName 'New-PlanetCrafterServerSave' -ParameterName 'SaveDisplayName' -ResolverFunction 'Complete-PCSNewSaveDisplayName'
    Register-PCSCompleter -CommandName 'Install-PlanetCrafterServer' -ParameterName 'NewSavePlanetId' -ResolverFunction 'Complete-PCSNewSavePlanetId'
    Register-PCSCompleter -CommandName 'New-PlanetCrafterServerSave' -ParameterName 'PlanetId' -ResolverFunction 'Complete-PCSNewSavePlanetId'
    Register-PCSCompleter -CommandName @('Install-PlanetCrafterServer', 'New-PlanetCrafterServerSave') -ParameterName 'NewSaveGameMode' -ResolverFunction 'Complete-PCSNewSaveGameMode'
    Register-PCSCompleter -CommandName 'New-PlanetCrafterServerSave' -ParameterName 'GameMode' -ResolverFunction 'Complete-PCSNewSaveGameMode'
    Register-PCSCompleter -CommandName @('Install-PlanetCrafterServer', 'New-PlanetCrafterServerSave') -ParameterName 'NewSaveStartLocation' -ResolverFunction 'Complete-PCSNewSaveStartLocation'
    Register-PCSCompleter -CommandName 'New-PlanetCrafterServerSave' -ParameterName 'StartLocation' -ResolverFunction 'Complete-PCSNewSaveStartLocation'
    Register-PCSCompleter -CommandName @('Install-PlanetCrafterServer', 'New-PlanetCrafterServerSave') -ParameterName 'NewSaveDyingConsequences' -ResolverFunction 'Complete-PCSNewSaveDyingConsequences'
    Register-PCSCompleter -CommandName 'New-PlanetCrafterServerSave' -ParameterName 'DyingConsequences' -ResolverFunction 'Complete-PCSNewSaveDyingConsequences'
    Register-PCSCompleter -CommandName @('Install-PlanetCrafterServer', 'New-PlanetCrafterServerSave') -ParameterName 'NewSaveWorldSeed' -ResolverFunction 'Complete-PCSNewSaveWorldSeed'
    Register-PCSCompleter -CommandName 'New-PlanetCrafterServerSave' -ParameterName 'WorldSeed' -ResolverFunction 'Complete-PCSNewSaveWorldSeed'
    Register-PCSCompleter -CommandName @('Install-PlanetCrafterServer', 'Set-PlanetCrafterServer') -ParameterName 'HostPlayerName' -ResolverFunction 'Complete-PCSHostPlayerName'
    Register-PCSCompleter -CommandName @('Install-PlanetCrafterServer', 'Set-PlanetCrafterServer') -ParameterName 'Port' -ResolverFunction 'Complete-PCSPort'
}

Export-ModuleMember -Function @(
    'Get-PlanetCrafterServer',
    'Start-PlanetCrafterServer',
    'Restart-PlanetCrafterServer',
    'New-PlanetCrafterServerSave',
    'Save-PlanetCrafterServer',
    'Complete-PlanetCrafterServerIntro',
    'Stop-PlanetCrafterServer',
    'Set-PlanetCrafterServer',
    'Install-PlanetCrafterServer',
    'Uninstall-PlanetCrafterServer'
)

Initialize-PCSArgumentCompleters


