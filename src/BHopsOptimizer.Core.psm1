#requires -Version 5.1
Set-StrictMode -Version 2.0

$script:SchemaVersion = 1
$script:WirelessSubgroup = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
$script:WirelessSetting = '12bbebe6-58d6-4636-95bb-3217ef867c1a'
$script:OptionNames = @('Prefer5GHz', 'LowRoaming', 'DisablePowerSaving', 'MaximumTransmitPower', 'DisableUapsd', 'AcPerformance')
$script:PropertyKeywords = @{
    MediaTek = @{
        Prefer5GHz = @('PreferredBand')
        LowRoaming = @('RoamIndicateTh')
        DisablePowerSaving = @('LowPowerEnable')
        MaximumTransmitPower = @('TransmitPower', 'TxPowerLevel')
        DisableUapsd = @('UAPSDEnable', 'UapsdEnable')
    }
    Intel = @{
        Prefer5GHz = @('RoamingPreferredBand', 'PreferredBand')
        LowRoaming = @('RoamAggressiveness', 'RoamingAggressiveness')
        DisablePowerSaving = @('PowerSavingMode')
        MaximumTransmitPower = @('TransmitPower', '*TransmitPower')
        DisableUapsd = @('uAPSDSupport', 'UAPSDEnable', '*UAPSD')
    }
}

function Get-BhoField {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function ConvertTo-BhoAdapterId {
    param([string]$Value)
    $guid = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$guid) -or $guid -eq [guid]::Empty) {
        throw 'A valid network adapter GUID is required.'
    }
    return $guid.ToString('D')
}

function Get-BhoNativeAdapters {
    @(Get-NetAdapter -IncludeHidden -ErrorAction Stop)
}

function Resolve-BhoNativeAdapter {
    param([string]$AdapterId)
    $id = ConvertTo-BhoAdapterId $AdapterId
    $found = @(Get-BhoNativeAdapters | Where-Object {
        $value = Get-BhoField $_ 'InterfaceGuid' ''
        ([string]$value).Trim('{}') -ieq $id
    })
    if ($found.Count -ne 1) { throw 'The selected adapter GUID was not found uniquely. Refresh the adapter list.' }
    return $found[0]
}

function Get-BhoNativeIdentity {
    param($Adapter)
    $pnpId = [string](Get-BhoField $Adapter 'PnPDeviceID' '')
    $driver = [string](Get-BhoField $Adapter 'DriverVersion' '')
    if (-not $pnpId) {
        try {
            $guid = ([string](Get-BhoField $Adapter 'InterfaceGuid' '')).Trim('{}')
            $record = Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction Stop | Where-Object {
                ([string](Get-BhoField $_ 'GUID' '')).Trim('{}') -ieq $guid
            } | Select-Object -First 1
            $pnpId = [string](Get-BhoField $record 'PNPDeviceID' '')
        } catch { $pnpId = '' }
    }
    $hardwareIds = @()
    if ($pnpId) {
        try {
            $property = Get-PnpDeviceProperty -InstanceId $pnpId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction Stop
            $hardwareIds = @((Get-BhoField $property 'Data' @()) | ForEach-Object { [string]$_ })
        } catch { $hardwareIds = @() }
        if (-not $driver) {
            try {
                $signed = Get-CimInstance -ClassName Win32_PnPSignedDriver -ErrorAction Stop | Where-Object {
                    (Get-BhoField $_ 'DeviceID' '') -ieq $pnpId
                } | Select-Object -First 1
                $driver = [string](Get-BhoField $signed 'DriverVersion' '')
            } catch { $driver = '' }
        }
    }
    [pscustomobject]@{ PnpInstanceId = $pnpId; HardwareIds = @($hardwareIds); DriverVersion = $driver }
}

function Test-BhoNativeWifi {
    param($Adapter)
    # Wi-Fi Direct and hosted-network adapters also report an 802.11 medium.
    # An exposed hardware flag must positively identify a physical interface.
    $hardwareFlag = $Adapter.PSObject.Properties['HardwareInterface']
    if ($null -ne $hardwareFlag -and $hardwareFlag.Value -ne $true) { return $false }
    $virtualFlag = $Adapter.PSObject.Properties['Virtual']
    if ($null -ne $virtualFlag -and $virtualFlag.Value -eq $true) { return $false }
    $pnpId = [string](Get-BhoField $Adapter 'PnPDeviceID' '')
    $description = [string](Get-BhoField $Adapter 'InterfaceDescription' '')
    if ($pnpId -match '(?i)^(ROOT|SWD|VMS_MP|BTH|BTHENUM)\\' -or
        $description -match '(?i)\bvirtual\b|wi[ -]?fi direct|hosted network|\bloopback\b') { return $false }
    $medium = [string](Get-BhoField $Adapter 'NdisPhysicalMedium' '')
    $physical = [string](Get-BhoField $Adapter 'PhysicalMediaType' '')
    $interfaceType = [string](Get-BhoField $Adapter 'InterfaceType' '')
    return ($medium -in @('1', '9', 'WirelessLan', 'Native802_11', 'Native 802.11') -or
        $physical -match '802\.11|WirelessLan' -or $interfaceType -eq '71')
}

function Get-BhoAdapters {
    <# .SYNOPSIS Lists adapters without changing Windows settings. #>
    [CmdletBinding()]
    param()
    foreach ($adapter in (Get-BhoNativeAdapters)) {
        $identity = Get-BhoNativeIdentity $adapter
        [pscustomobject]@{
            Id = ConvertTo-BhoAdapterId ([string](Get-BhoField $adapter 'InterfaceGuid' ''))
            Name = [string](Get-BhoField $adapter 'Name' '')
            Description = [string](Get-BhoField $adapter 'InterfaceDescription' '')
            Status = [string](Get-BhoField $adapter 'Status' '')
            LinkSpeed = [string](Get-BhoField $adapter 'LinkSpeed' '')
            DriverVersion = $identity.DriverVersion
            IsWifi = Test-BhoNativeWifi $adapter
            PnpInstanceId = $identity.PnpInstanceId
            HardwareIds = @($identity.HardwareIds)
        }
    }
}

function Get-BhoNativeProperties {
    param($Adapter)
    $name = [System.Management.Automation.WildcardPattern]::Escape([string]$Adapter.Name)
    @(Get-NetAdapterAdvancedProperty -Name $name -AllProperties -ErrorAction Stop)
}

function Get-BhoNativeDevicePower {
    param([string]$PnpInstanceId)
    if (-not $PnpInstanceId) { return [pscustomobject]@{ Supported = $false; InstanceName = $null; Enabled = $null } }
    try {
        $records = @(Get-CimInstance -Namespace 'root/wmi' -ClassName MSPower_DeviceEnable -ErrorAction Stop | Where-Object {
            $instance = [string](Get-BhoField $_ 'InstanceName' '')
            $instance -ieq $PnpInstanceId -or $instance.StartsWith($PnpInstanceId + '_', [StringComparison]::OrdinalIgnoreCase)
        })
        if ($records.Count -eq 1) {
            return [pscustomobject]@{ Supported = $true; InstanceName = [string]$records[0].InstanceName; Enabled = [bool]$records[0].Enable }
        }
    } catch { }
    [pscustomobject]@{ Supported = $false; InstanceName = $null; Enabled = $null }
}

function Invoke-BhoPowerCfg {
    param([string[]]$Arguments)
    $lines = @(& powercfg.exe @Arguments 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $lines }
}

function Get-BhoAcPower {
    param([string]$SchemeId)
    try {
        if (-not $SchemeId) {
            $active = Invoke-BhoPowerCfg @('/getactivescheme')
            if ($active.ExitCode -ne 0) { throw 'Power scheme query failed.' }
            $matches = [regex]::Matches(($active.Lines -join "`n"), '(?i)[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}')
            if ($matches.Count -ne 1) { throw 'Ambiguous active power scheme.' }
            $SchemeId = $matches[0].Value.ToLowerInvariant()
        }
        $SchemeId = ConvertTo-BhoAdapterId $SchemeId
        $query = Invoke-BhoPowerCfg @('/query', $SchemeId, $script:WirelessSubgroup, $script:WirelessSetting)
        if ($query.ExitCode -ne 0) { throw 'Wireless power setting is unavailable.' }
        # powercfg emits the AC index followed by the DC index. Require exactly
        # two hexadecimal indexes rather than relying on localized labels.
        $indexes = [regex]::Matches(($query.Lines -join "`n"), '(?i)0x[0-9a-f]{8}\b')
        if ($indexes.Count -ne 2) { throw 'Wireless power setting cannot be parsed safely.' }
        $value = [Convert]::ToInt32($indexes[0].Value.Substring(2), 16)
        if ($value -lt 0 -or $value -gt 3) { throw 'Unexpected wireless power setting index.' }
        return [pscustomobject]@{ Supported = $true; SchemeId = $SchemeId; WirelessPowerSaveIndex = $value }
    } catch {
        return [pscustomobject]@{ Supported = $false; SchemeId = $SchemeId; WirelessPowerSaveIndex = $null }
    }
}

function Get-BhoNativeGateway {
    param($Adapter)
    try {
        $routes = @(Get-NetRoute -InterfaceIndex $Adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' } | Sort-Object RouteMetric)
        if ($routes.Count) { return [string]$routes[0].NextHop }
    } catch { }
    return $null
}

function Get-BhoNativeCounters {
    param($Adapter)
    try {
        $name = [System.Management.Automation.WildcardPattern]::Escape([string]$Adapter.Name)
        $stats = Get-NetAdapterStatistics -Name $name -ErrorAction Stop | Select-Object -First 1
        return [pscustomobject]@{
            ReceivedBytes = Get-BhoField $stats 'ReceivedBytes'
            SentBytes = Get-BhoField $stats 'SentBytes'
            ReceivedDiscardedPackets = Get-BhoField $stats 'ReceivedDiscardedPackets'
            OutboundDiscardedPackets = Get-BhoField $stats 'OutboundDiscardedPackets'
            ReceivedPacketErrors = Get-BhoField $stats 'ReceivedPacketErrors'
            OutboundPacketErrors = Get-BhoField $stats 'OutboundPacketErrors'
        }
    } catch { return [pscustomobject]@{ ReceivedBytes = $null; SentBytes = $null } }
}

function Get-BhoSnapshot {
    <# .SYNOPSIS Captures capabilities and exact current values for one adapter GUID. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AdapterId)
    $adapter = Resolve-BhoNativeAdapter $AdapterId
    $identity = Get-BhoNativeIdentity $adapter
    $properties = @()
    $warnings = @()
    try {
        $properties = @(Get-BhoNativeProperties $adapter | ForEach-Object {
            [pscustomobject]@{
                RegistryKeyword = [string](Get-BhoField $_ 'RegistryKeyword' '')
                RegistryValue = @((Get-BhoField $_ 'RegistryValue' @()) | ForEach-Object { [string]$_ })
                DisplayName = [string](Get-BhoField $_ 'DisplayName' '')
                DisplayValue = [string](Get-BhoField $_ 'DisplayValue' '')
                ValidRegistryValues = @((Get-BhoField $_ 'ValidRegistryValues' @()) | ForEach-Object { [string]$_ })
                ValidDisplayValues = @((Get-BhoField $_ 'ValidDisplayValues' @()) | ForEach-Object { [string]$_ })
            }
        })
    } catch { $warnings += 'Advanced property capabilities could not be read; advanced changes will be skipped.' }
    [pscustomobject]@{
        SchemaVersion = $script:SchemaVersion
        CapturedAt = [DateTimeOffset]::Now.ToString('o')
        AdapterId = ConvertTo-BhoAdapterId $AdapterId
        AdapterName = [string]$adapter.Name
        AdapterDescription = [string](Get-BhoField $adapter 'InterfaceDescription' '')
        IsWifi = Test-BhoNativeWifi $adapter
        DriverVersion = $identity.DriverVersion
        PnpInstanceId = $identity.PnpInstanceId
        HardwareIds = @($identity.HardwareIds)
        Properties = @($properties)
        DevicePower = Get-BhoNativeDevicePower $identity.PnpInstanceId
        AcPower = Get-BhoAcPower
        DefaultGateway = Get-BhoNativeGateway $adapter
        Counters = Get-BhoNativeCounters $adapter
        Warnings = @($warnings)
    }
}

function Get-BhoVendor {
    param($Snapshot)
    $ids = @((Get-BhoField $Snapshot 'HardwareIds' @())) -join ' '
    if ($ids -match '(?i)VEN_14C3|VID_0E8D') { return 'MediaTek' }
    if ($ids -match '(?i)VEN_8086|VID_8087') { return 'Intel' }
    # Identity is mandatory before mutation. Descriptions only aid read-only plans.
    $description = [string](Get-BhoField $Snapshot 'AdapterDescription' '')
    if ($description -match '(?i)MediaTek|\bMT79\d+') { return 'MediaTek' }
    if ($description -match '(?i)\bIntel\b') { return 'Intel' }
    return 'Unknown'
}

function Test-BhoEqual {
    param($Left, $Right)
    $a = @($Left | ForEach-Object { [string]$_ })
    $b = @($Right | ForEach-Object { [string]$_ })
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) { if ($a[$i] -cne $b[$i]) { return $false } }
    return $true
}

function Resolve-BhoPropertyValue {
    param($Property, [string]$Option)
    $values = @((Get-BhoField $Property 'ValidRegistryValues' @()))
    $labels = @((Get-BhoField $Property 'ValidDisplayValues' @()))
    if (-not $values.Count -or $values.Count -ne $labels.Count) { return $null }
    $current = @((Get-BhoField $Property 'RegistryValue' @()))
    if ($current.Count -ne 1 -or $values -cnotcontains [string]$current[0] -or @($values | Select-Object -Unique).Count -ne $values.Count) { return $null }
    $candidates = @()
    for ($i = 0; $i -lt $labels.Count; $i++) {
        $label = ([string]$labels[$i]).Trim() -replace '^\d+\s*[\.\)\:\-]\s*', ''
        $match = $false
        switch ($Option) {
            'Prefer5GHz' { $match = $label -match '^(?i)(prefer(?:red)?\s+)?5(?:\.0)?\s*g(?:hz)?(?:\s+band)?$' }
            'LowRoaming' { $match = $label -match '^(?i)lowest(?:\s*\([^)]*\))?$' }
            'DisablePowerSaving' { $match = $label -match '(?i)^(disabled|off)$' }
            'MaximumTransmitPower' { $match = $label -match '^(?i)(highest|maximum)(?:\s*\([^)]*\))?$' }
            'DisableUapsd' { $match = $label -match '(?i)^(disabled|off)$' }
        }
        if ($match) { $candidates += [pscustomobject]@{ Value = [string]$values[$i]; Label = [string]$labels[$i] } }
    }
    if ($candidates.Count -ne 1) { return $null }
    return $candidates[0]
}

function New-BhoPlanEntry {
    param([string]$Id, [string]$Label, [string]$Kind, [string]$Keyword, $Before, $After, [bool]$Supported, [string]$Reason, [string]$SchemeId)
    [pscustomobject]@{
        Id = $Id; Label = $Label; Kind = $Kind; Keyword = $Keyword
        Before = $Before; After = $After; Supported = $Supported
        Changed = ($Supported -and -not (Test-BhoEqual $Before $After))
        Reason = $Reason; SchemeId = $SchemeId
    }
}

function Get-BhoTuningPlan {
    <# .SYNOPSIS Builds a capability-aware plan without changing settings. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Snapshot,
        [ValidateSet('Prefer5GHz', 'LowRoaming', 'DisablePowerSaving', 'MaximumTransmitPower', 'DisableUapsd', 'AcPerformance')]
        [string[]]$Options = @('Prefer5GHz', 'LowRoaming', 'DisablePowerSaving')
    )
    $vendor = Get-BhoVendor $Snapshot
    $wifi = [bool](Get-BhoField $Snapshot 'IsWifi' $false)
    foreach ($option in @($Options | Select-Object -Unique)) {
        if ($option -eq 'AcPerformance') {
            $ac = Get-BhoField $Snapshot 'AcPower'
            $supported = $wifi -and [bool](Get-BhoField $ac 'Supported' ($null -ne (Get-BhoField $ac 'WirelessPowerSaveIndex')))
            New-BhoPlanEntry $option 'Wireless power on AC: maximum performance' 'AcPower' 'WirelessPowerSaveIndex' (Get-BhoField $ac 'WirelessPowerSaveIndex') 0 $supported 'Changes only the AC wireless setting in the recorded power scheme; battery settings are preserved.' (Get-BhoField $ac 'SchemeId')
            continue
        }
        $property = $null
        if ($wifi -and $script:PropertyKeywords.ContainsKey($vendor)) {
            foreach ($keyword in $script:PropertyKeywords[$vendor][$option]) {
                $matches = @((Get-BhoField $Snapshot 'Properties' @()) | Where-Object { $_.RegistryKeyword -ieq $keyword })
                if ($matches.Count -eq 1) { $property = $matches[0]; break }
            }
        }
        $value = $null
        if ($null -ne $property) { $value = Resolve-BhoPropertyValue $property $option }
        $supported = $null -ne $value
        $keyword = [string](Get-BhoField $property 'RegistryKeyword' '')
        $before = @((Get-BhoField $property 'RegistryValue' @()))
        $after = @()
        $reason = 'The driver does not expose an unambiguous supported value for this option; skipped.'
        if (-not $wifi) { $reason = 'The selected adapter is not a Wi-Fi adapter; skipped.' }
        if ($vendor -eq 'Unknown') { $reason = 'This vendor has no validated advanced-property mapping; skipped.' }
        if ($supported) {
            $after = @($value.Value)
            $reason = 'Resolved from the driver''s paired value and display-label capabilities: ' + $value.Label
        }
        $label = switch ($option) {
            'Prefer5GHz' { 'Prefer 5 GHz while retaining other bands' }
            'LowRoaming' { 'Lowest roaming aggressiveness for a stationary PC' }
            'DisablePowerSaving' { 'Disable adapter power saving' }
            'MaximumTransmitPower' { 'Highest available transmit power' }
            'DisableUapsd' { 'Disable U-APSD power saving' }
        }
        New-BhoPlanEntry ($option + '.Advanced') $label 'Advanced' $keyword $before $after $supported $reason ''
        if ($option -eq 'DisablePowerSaving') {
            $power = Get-BhoField $Snapshot 'DevicePower'
            $available = $wifi -and [bool](Get-BhoField $power 'Supported' $false)
            New-BhoPlanEntry ($option + '.DevicePower') 'Prevent Windows turning off this adapter to save power' 'DevicePower' 'Enabled' (Get-BhoField $power 'Enabled') $false $available 'Applied only when Windows exposes a unique device-power instance for this adapter.' ''
        }
    }
}

function Test-BhoAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-BhoSafePath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw 'An empty filesystem path is not allowed.' }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $volume = [IO.Path]::GetPathRoot($fullPath)
    # State and restore files must be ordinary local-drive paths. This also
    # excludes device paths, UNC shares and alternate data streams.
    if ($volume -notmatch '^[A-Za-z]:\\$' -or $fullPath.Substring($volume.Length).Contains(':')) {
        throw 'Only ordinary local-drive filesystem paths are supported.'
    }
    $candidate = $fullPath
    if ($candidate.Length -gt $volume.Length) { $candidate = $candidate.TrimEnd([char]'\', [char]'/') }
    while ($candidate) {
        $item = $null
        try { $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop }
        catch {
            if ($_.CategoryInfo.Category -ne [Management.Automation.ErrorCategory]::ObjectNotFound) {
                throw ('The filesystem path cannot be validated safely: ' + $candidate)
            }
        }
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw ('Symbolic-link, junction or other reparse-point paths are not allowed: ' + $candidate)
        }
        if ($candidate -ieq $volume) { break }
        $parent = [IO.Path]::GetDirectoryName($candidate)
        if (-not $parent -or $parent -eq $candidate) { break }
        $candidate = $parent
    }
    return $fullPath
}

function Assert-BhoStatePaths {
    param([string]$StateRoot)
    Assert-BhoSafePath $StateRoot | Out-Null
    foreach ($child in @('backups', 'operation.lock', 'operations.jsonl')) {
        Assert-BhoSafePath (Join-Path $StateRoot $child) | Out-Null
    }
}

function Get-BhoStateRoot {
    param([string]$StateRoot)
    if (-not $StateRoot) { $StateRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'BHopsOptimizer' }
    return Assert-BhoSafePath $StateRoot
}

function Write-BhoJson {
    param([string]$Path, $Value, [switch]$CreateNew)
    $Path = Assert-BhoSafePath $Path
    $json = $Value | ConvertTo-Json -Depth 15
    $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
    if ($CreateNew) {
        Assert-BhoSafePath $Path | Out-Null
        $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            Assert-BhoSafePath $Path | Out-Null
            $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
        } finally { $stream.Dispose() }
        return
    }
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $replaced = $Path + '.' + [guid]::NewGuid().ToString('N') + '.replaced.tmp'
    try {
        Write-BhoJson -Path $temporary -Value $Value -CreateNew
        foreach ($candidate in @($Path, $temporary, $replaced)) { Assert-BhoSafePath $candidate | Out-Null }
        # Windows PowerShell 5.1 can convert a null string argument to an empty
        # path here. Use an explicit temporary replacement path instead.
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, $replaced) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if ([IO.File]::Exists($temporary)) { Assert-BhoSafePath $temporary | Out-Null; [IO.File]::Delete($temporary) }
        if ([IO.File]::Exists($replaced)) { Assert-BhoSafePath $replaced | Out-Null; [IO.File]::Delete($replaced) }
    }
}

function New-BhoBackup {
    param($Snapshot, [object[]]$Changes, [string]$StateRoot, [string]$Operation = 'Apply')
    $directory = Join-Path $StateRoot 'backups'
    Assert-BhoSafePath $directory | Out-Null
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    Assert-BhoSafePath $directory | Out-Null
    $id = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N')
    $path = Join-Path $directory ($id + '.json')
    $backup = [pscustomobject]@{
        SchemaVersion = $script:SchemaVersion; ArtifactKind = 'BHopsOptimizerBackup'
        Id = $id; CreatedAt = [DateTimeOffset]::Now.ToString('o'); Operation = $Operation
        AdapterId = $Snapshot.AdapterId; AdapterName = $Snapshot.AdapterName
        Snapshot = $Snapshot; Changes = @($Changes)
    }
    Write-BhoJson -Path $path -Value $backup -CreateNew
    # Check the durable snapshot before the first setting write.
    Assert-BhoSafePath $path | Out-Null
    $readBack = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($readBack.Id -ne $id -or $readBack.Snapshot.AdapterId -ne $Snapshot.AdapterId) { throw 'The backup could not be verified. No settings were changed.' }
    [pscustomobject]@{ Id = $id; Path = $path; Backup = $backup }
}

function Set-BhoBackupStatus {
    param([string]$StateRoot, $Backup, [string]$Status, [string]$Message)
    $manifest = [pscustomobject]@{ Id = $Backup.Id; Status = $Status; UpdatedAt = [DateTimeOffset]::Now.ToString('o'); Message = $Message }
    Write-BhoJson -Path (Join-Path (Join-Path $StateRoot 'backups') ($Backup.Id + '.status.json')) -Value $manifest
}

function Write-BhoLog {
    param([string]$StateRoot, [string]$Action, [string]$AdapterId, [string]$BackupId, [bool]$Success, [string]$Message)
    try {
        $entry = [pscustomobject]@{ Time = [DateTimeOffset]::Now.ToString('o'); Action = $Action; AdapterId = $AdapterId; BackupId = $BackupId; Success = $Success; Message = $Message }
        $line = ($entry | ConvertTo-Json -Compress) + [Environment]::NewLine
        $logPath = Assert-BhoSafePath (Join-Path $StateRoot 'operations.jsonl')
        [IO.File]::AppendAllText($logPath, $line, (New-Object Text.UTF8Encoding($false)))
    } catch { Write-Warning 'The operation completed, but its log could not be written.' }
}

function Assert-BhoSameHardware {
    param($Original, $Current)
    if ((ConvertTo-BhoAdapterId $Original.AdapterId) -ne (ConvertTo-BhoAdapterId $Current.AdapterId)) { throw 'Adapter GUID mismatch.' }
    if (-not $Original.PnpInstanceId -or -not $Current.PnpInstanceId -or $Original.PnpInstanceId -ine $Current.PnpInstanceId) { throw 'The adapter PnP identity could not be matched safely.' }
    $oldIds = @($Original.HardwareIds)
    $newIds = @($Current.HardwareIds)
    if (-not $oldIds.Count -or -not $newIds.Count -or -not @($oldIds | Where-Object { $newIds -icontains $_ }).Count) {
        throw 'The adapter hardware IDs could not be matched safely.'
    }
    if (-not $Current.IsWifi) { throw 'Only a verified physical Wi-Fi adapter may be tuned.' }
}

function Assert-BhoChangeSupported {
    param($Change, $Snapshot, $Value)
    $kind = [string](Get-BhoField $Change 'Kind' '')
    $id = [string](Get-BhoField $Change 'Id' '')
    $option = ($id -split '\.')[0]
    if ($script:OptionNames -notcontains $option) { throw 'The backup contains an unrecognized tuning option.' }
    switch ($kind) {
        'Advanced' {
            if ($id -cne ($option + '.Advanced') -or $option -eq 'AcPerformance') { throw 'Invalid advanced-property mutation identifier.' }
            $vendor = Get-BhoVendor $Snapshot
            $keyword = [string](Get-BhoField $Change 'Keyword' '')
            if (-not $script:PropertyKeywords.ContainsKey($vendor) -or $script:PropertyKeywords[$vendor][$option] -inotcontains $keyword) {
                throw 'The backup contains a property outside the allowed Wi-Fi tuning keywords.'
            }
            $properties = @($Snapshot.Properties | Where-Object RegistryKeyword -IEQ $keyword)
            if ($properties.Count -ne 1) { throw ('The driver no longer exposes property ' + $keyword + ' uniquely.') }
            $values = @($Value)
            if ($values.Count -ne 1 -or @($properties[0].ValidRegistryValues) -cnotcontains [string]$values[0]) { throw ('Unsupported value for ' + $keyword + '.') }
        }
        'DevicePower' {
            if ($id -cne 'DisablePowerSaving.DevicePower' -or $Change.Keyword -cne 'Enabled' -or -not $Snapshot.DevicePower.Supported -or $Value -isnot [bool]) { throw 'Unsupported device-power change.' }
        }
        'AcPower' {
            if ($id -cne 'AcPerformance' -or $Change.Keyword -cne 'WirelessPowerSaveIndex' -or $null -eq $Value -or [int]$Value -lt 0 -or [int]$Value -gt 3) { throw 'Unsupported AC power change.' }
            $scheme = ConvertTo-BhoAdapterId ([string]$Change.SchemeId)
            $capability = Get-BhoAcPower -SchemeId $scheme
            if (-not $capability.Supported) { throw 'The recorded wireless AC power setting is unavailable.' }
        }
        default { throw 'The backup contains an unrecognized mutation kind.' }
    }
}

function Set-BhoNativeAdvanced {
    param([string]$AdapterId, [string]$Keyword, [string[]]$Value)
    $adapter = Resolve-BhoNativeAdapter $AdapterId
    $property = @(Get-BhoNativeProperties $adapter | Where-Object RegistryKeyword -IEQ $Keyword)
    if ($property.Count -ne 1) { throw 'The advanced property identity changed during the operation.' }
    Set-NetAdapterAdvancedProperty -InputObject $property[0] -RegistryValue $Value -NoRestart -Confirm:$false -ErrorAction Stop | Out-Null
}

function Set-BhoNativeDevicePower {
    param([string]$InstanceName, [bool]$Enabled)
    $instances = @(Get-CimInstance -Namespace 'root/wmi' -ClassName MSPower_DeviceEnable -ErrorAction Stop | Where-Object InstanceName -IEQ $InstanceName)
    if ($instances.Count -ne 1) { throw 'The device-power identity changed during the operation.' }
    $instances[0] | Set-CimInstance -Property @{ Enable = $Enabled } -ErrorAction Stop | Out-Null
}

function Set-BhoAcPower {
    param([string]$SchemeId, [int]$Index)
    $scheme = ConvertTo-BhoAdapterId $SchemeId
    $result = Invoke-BhoPowerCfg @('/setacvalueindex', $scheme, $script:WirelessSubgroup, $script:WirelessSetting, [string]$Index)
    if ($result.ExitCode -ne 0) { throw 'Windows rejected the wireless AC power setting.' }
    $active = Get-BhoAcPower
    if ($active.SchemeId -ieq $scheme) {
        $result = Invoke-BhoPowerCfg @('/setactive', $scheme)
        if ($result.ExitCode -ne 0) { throw 'Windows could not refresh the active power scheme.' }
    }
}

function Set-BhoChange {
    param([string]$AdapterId, $Snapshot, $Change, $Value)
    # Recheck physical eligibility and identity immediately before every write,
    # including rollback writes; a GUID alone must never identify a virtual NIC.
    $adapter = Resolve-BhoNativeAdapter $AdapterId
    $identity = Get-BhoNativeIdentity $adapter
    $currentIdentity = [pscustomobject]@{
        AdapterId = ConvertTo-BhoAdapterId $AdapterId
        PnpInstanceId = $identity.PnpInstanceId
        HardwareIds = @($identity.HardwareIds)
        IsWifi = Test-BhoNativeWifi $adapter
    }
    Assert-BhoSameHardware $Snapshot $currentIdentity
    Assert-BhoChangeSupported $Change $Snapshot $Value
    switch ($Change.Kind) {
        'Advanced' { Set-BhoNativeAdvanced -AdapterId $AdapterId -Keyword $Change.Keyword -Value @($Value) }
        'DevicePower' { Set-BhoNativeDevicePower -InstanceName $Snapshot.DevicePower.InstanceName -Enabled ([bool]$Value) }
        'AcPower' { Set-BhoAcPower -SchemeId $Change.SchemeId -Index ([int]$Value) }
    }
}

function Restart-BhoNativeAdapter {
    param([string]$AdapterId)
    $adapter = Resolve-BhoNativeAdapter $AdapterId
    if (-not (Test-BhoNativeWifi $adapter)) { throw 'Only a verified physical Wi-Fi adapter may be restarted.' }
    Restart-NetAdapter -InputObject $adapter -Confirm:$false -ErrorAction Stop | Out-Null
}

function Wait-BhoConnection {
    param([string]$AdapterId, [bool]$WasConnected, [int]$TimeoutSeconds = 30)
    if (-not $WasConnected) { return 'NotPreviouslyConnected' }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $adapter = Resolve-BhoNativeAdapter $AdapterId
        if ([string]$adapter.Status -eq 'Up' -and (Get-BhoNativeGateway $adapter)) { return 'Connected' }
        Start-Sleep -Milliseconds 500
    } while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    return 'TimedOut'
}

function Assert-BhoValues {
    param([string]$AdapterId, $Original, [object[]]$Changes, [ValidateSet('Before', 'After')][string]$Side)
    $current = Get-BhoSnapshot -AdapterId $AdapterId
    Assert-BhoSameHardware $Original $current
    foreach ($change in $Changes) {
        $expected = Get-BhoField $change $Side
        switch ($change.Kind) {
            'Advanced' {
                $property = @($current.Properties | Where-Object RegistryKeyword -IEQ $change.Keyword)
                if ($property.Count -ne 1 -or -not (Test-BhoEqual $property[0].RegistryValue $expected)) { throw ('Verification failed for ' + $change.Keyword + '.') }
            }
            'DevicePower' {
                if (-not $current.DevicePower.Supported -or $current.DevicePower.InstanceName -ine $Original.DevicePower.InstanceName -or -not (Test-BhoEqual $current.DevicePower.Enabled $expected)) { throw 'Device-power verification failed.' }
            }
            'AcPower' {
                $power = Get-BhoAcPower -SchemeId $change.SchemeId
                if (-not $power.Supported -or -not (Test-BhoEqual $power.WirelessPowerSaveIndex $expected)) { throw 'AC wireless-power verification failed.' }
            }
        }
    }
}

function Invoke-BhoRollback {
    param([string]$AdapterId, $Snapshot, [object[]]$Changes)
    $errors = @()
    # Include the failing write: a cmdlet may throw after partially changing a value.
    for ($i = $Changes.Count - 1; $i -ge 0; $i--) {
        try { Set-BhoChange $AdapterId $Snapshot $Changes[$i] $Changes[$i].Before }
        catch { $errors += $_.Exception.Message }
    }
    if (@($Changes | Where-Object { $_.Kind -in @('Advanced', 'DevicePower') }).Count) {
        try { Restart-BhoNativeAdapter $AdapterId } catch { $errors += $_.Exception.Message }
    }
    try { Assert-BhoValues $AdapterId $Snapshot $Changes 'Before' } catch { $errors += $_.Exception.Message }
    $reconnect = 'NotRequired'
    try { $reconnect = Wait-BhoConnection $AdapterId ([bool]$Snapshot.DefaultGateway) } catch { $errors += $_.Exception.Message }
    if ($reconnect -eq 'TimedOut') { $errors += 'The adapter did not reconnect after rollback.' }
    [pscustomobject]@{ Success = ($errors.Count -eq 0); Errors = @($errors); ReconnectStatus = $reconnect }
}

function Invoke-BhoTransaction {
    param([string]$AdapterId, $Snapshot, [object[]]$Changes, [string]$StateRoot, [string]$Operation)
    $lock = $null
    $backup = $null
    $attempted = @()
    $reconnect = 'NotRequired'
    try {
        Assert-BhoStatePaths $StateRoot
        [IO.Directory]::CreateDirectory($StateRoot) | Out-Null
        Assert-BhoStatePaths $StateRoot
        $lockPath = Assert-BhoSafePath (Join-Path $StateRoot 'operation.lock')
        $lock = New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        Assert-BhoSafePath $lockPath | Out-Null
        # Refresh under the lock, so another optimizer transaction cannot invalidate the snapshot.
        $fresh = Get-BhoSnapshot $AdapterId
        Assert-BhoSameHardware $Snapshot $fresh
        $acChanges = @($Changes | Where-Object Kind -EQ 'AcPower')
        if ($acChanges.Count) {
            if ($acChanges.Count -ne 1) { throw 'Only one wireless AC power setting may be changed in a transaction.' }
            # A restore can target an inactive scheme. Capture the exact scheme
            # that will be written, rather than backing up the active scheme's value.
            $fresh | Add-Member -NotePropertyName ActiveSchemeId -NotePropertyValue $fresh.AcPower.SchemeId -Force
            $fresh.AcPower = Get-BhoAcPower -SchemeId $acChanges[0].SchemeId
        }
        foreach ($change in $Changes) {
            Assert-BhoChangeSupported $change $fresh $change.After
            Assert-BhoChangeSupported $change $fresh $change.Before
        }
        Assert-BhoValues $AdapterId $Snapshot $Changes 'Before'
        $backup = New-BhoBackup -Snapshot $fresh -Changes $Changes -StateRoot $StateRoot -Operation $Operation
        Set-BhoBackupStatus $StateRoot $backup 'Captured' 'Original values saved before mutation.'
        foreach ($change in $Changes) {
            $attempted += $change
            Set-BhoChange $AdapterId $fresh $change $change.After
        }
        if (@($Changes | Where-Object { $_.Kind -in @('Advanced', 'DevicePower') }).Count) { Restart-BhoNativeAdapter $AdapterId }
        Assert-BhoValues $AdapterId $fresh $Changes 'After'
        $reconnect = Wait-BhoConnection $AdapterId ([bool]$fresh.DefaultGateway)
        if ($reconnect -eq 'TimedOut') { throw 'The previously connected adapter did not reconnect within 30 seconds.' }
        Set-BhoBackupStatus $StateRoot $backup 'Applied' ($Operation + ' completed and verified.')
        Write-BhoLog $StateRoot $Operation $AdapterId $backup.Id $true 'Changes verified.'
        return [pscustomobject]@{ Success = $true; BackupPath = $backup.Path; ChangedCount = $Changes.Count; Skipped = @(); Message = ($Operation + ' completed and verified.'); ReconnectStatus = $reconnect; Reconnected = ($reconnect -eq 'Connected'); RollbackSucceeded = $null }
    } catch {
        $message = $_.Exception.Message
        $rollback = $null
        if ($attempted.Count) { $rollback = Invoke-BhoRollback $AdapterId $Snapshot $attempted }
        $backupPath = $null
        $backupId = ''
        if ($backup) {
            $backupPath = $backup.Path; $backupId = $backup.Id
            $status = 'FailedBeforeChanges'
            if ($rollback) {
                if ($rollback.Success) { $status = 'RolledBack'; $message += ' Original values were restored and verified.' }
                else { $status = 'RollbackIncomplete'; $message += ' Rollback needs attention: ' + ($rollback.Errors -join ' ') }
                $reconnect = $rollback.ReconnectStatus
            }
            try { Set-BhoBackupStatus $StateRoot $backup $status $message } catch { $message += ' Backup status could not be saved.' }
        }
        if ([IO.Directory]::Exists($StateRoot)) { Write-BhoLog $StateRoot $Operation $AdapterId $backupId $false $message }
        return [pscustomobject]@{ Success = $false; BackupPath = $backupPath; ChangedCount = 0; Skipped = @(); Message = $message; ReconnectStatus = $reconnect; Reconnected = ($reconnect -eq 'Connected'); RollbackSucceeded = $(if ($rollback) { $rollback.Success } else { $null }) }
    } finally { if ($lock) { $lock.Dispose() } }
}

function Invoke-BhoApply {
    <# .SYNOPSIS Backs up, applies and verifies selected supported Wi-Fi settings. #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string]$AdapterId,
        [ValidateSet('Prefer5GHz', 'LowRoaming', 'DisablePowerSaving', 'MaximumTransmitPower', 'DisableUapsd', 'AcPerformance')]
        [string[]]$Options = @('Prefer5GHz', 'LowRoaming', 'DisablePowerSaving'),
        [string]$StateRoot
    )
    $snapshot = Get-BhoSnapshot $AdapterId
    if (-not $snapshot.IsWifi) { throw 'Only a verified physical Wi-Fi adapter may be tuned.' }
    $plan = @(Get-BhoTuningPlan -Snapshot $snapshot -Options $Options)
    $changes = @($plan | Where-Object { $_.Supported -and $_.Changed })
    $skipped = @($plan | Where-Object { -not $_.Supported })
    if (-not $changes.Count) { return [pscustomobject]@{ Success = $true; BackupPath = $null; ChangedCount = 0; Skipped = $skipped; Message = 'No supported settings need changing.'; ReconnectStatus = 'NotRequired'; Reconnected = $null; Plan = $plan } }
    if (-not $PSCmdlet.ShouldProcess($snapshot.AdapterName, ('Apply ' + $changes.Count + ' Wi-Fi setting changes with a backup'))) {
        return [pscustomobject]@{ Success = $true; BackupPath = $null; ChangedCount = 0; Skipped = $skipped; Message = 'Preview only; no settings or backup files were changed.'; ReconnectStatus = 'NotRequired'; Reconnected = $null; Plan = $plan }
    }
    if (-not (Test-BhoAdministrator)) { throw 'Run as administrator to apply settings. Inventory, plans and diagnostics do not require elevation.' }
    Assert-BhoSameHardware $snapshot $snapshot
    $result = Invoke-BhoTransaction $snapshot.AdapterId $snapshot $changes (Get-BhoStateRoot $StateRoot) 'Apply'
    $result.Skipped = $skipped
    $result | Add-Member -NotePropertyName Plan -NotePropertyValue $plan
    return $result
}

function Get-BhoBackups {
    <# .SYNOPSIS Lists saved snapshots and their separate operation status. #>
    [CmdletBinding()]
    param([string]$StateRoot)
    $directory = Join-Path (Get-BhoStateRoot $StateRoot) 'backups'
    Assert-BhoSafePath $directory | Out-Null
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return }
    foreach ($file in (Get-ChildItem -LiteralPath $directory -Filter '*.json' -File | Where-Object Name -NotLike '*.status.json' | Sort-Object Name -Descending)) {
        try {
            Assert-BhoSafePath $file.FullName | Out-Null
            $backup = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($backup.ArtifactKind -ne 'BHopsOptimizerBackup' -or $backup.SchemaVersion -ne $script:SchemaVersion) { continue }
            if ([string]$backup.Id -notmatch '^\d{8}T\d{9}Z-[0-9a-f]{32}$') { continue }
            $status = 'Captured'
            $manifestPath = Join-Path $directory ($backup.Id + '.status.json')
            Assert-BhoSafePath $manifestPath | Out-Null
            if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if ($manifest.Id -eq $backup.Id) { $status = [string]$manifest.Status }
            }
            [pscustomobject]@{ Id = $backup.Id; Path = $file.FullName; AdapterId = $backup.AdapterId; AdapterName = $backup.AdapterName; CreatedAt = $backup.CreatedAt; Status = $status }
        } catch { Write-Verbose ('Skipped unreadable backup ' + $file.Name + '.') }
    }
}

function Restore-BhoBackup {
    <# .SYNOPSIS Restores recorded setting changes, with a recovery backup and hardware checks. #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$Path, [string]$StateRoot)
    $Path = Assert-BhoSafePath $Path
    $backup = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($backup.SchemaVersion -ne $script:SchemaVersion -or $backup.ArtifactKind -cne 'BHopsOptimizerBackup') { throw 'Unsupported backup format.' }
    $original = $backup.Snapshot
    $current = Get-BhoSnapshot $backup.AdapterId
    Assert-BhoSameHardware $original $current
    if ($backup.AdapterId -ine $original.AdapterId) { throw 'Backup adapter identity fields disagree.' }
    $changes = @()
    $seen = @{}
    foreach ($saved in @($backup.Changes)) {
        if ($seen.ContainsKey([string]$saved.Id)) { throw 'The backup contains duplicate mutation identifiers.' }
        $seen[[string]$saved.Id] = $true
        Assert-BhoChangeSupported $saved $original $saved.Before
        Assert-BhoChangeSupported $saved $current $saved.Before
        $before = $null
        switch ($saved.Kind) {
            'Advanced' {
                $source = @($original.Properties | Where-Object RegistryKeyword -IEQ $saved.Keyword)
                $now = @($current.Properties | Where-Object RegistryKeyword -IEQ $saved.Keyword)
                if ($source.Count -ne 1 -or -not (Test-BhoEqual $source[0].RegistryValue $saved.Before)) { throw 'The recorded original property value does not match the snapshot.' }
                $before = @($now[0].RegistryValue)
            }
            'DevicePower' {
                if (-not (Test-BhoEqual $original.DevicePower.Enabled $saved.Before) -or $original.DevicePower.InstanceName -ine $current.DevicePower.InstanceName) { throw 'The recorded device-power identity or original value does not match.' }
                $before = [bool]$current.DevicePower.Enabled
            }
            'AcPower' {
                if ($saved.SchemeId -ine $original.AcPower.SchemeId -or -not (Test-BhoEqual $original.AcPower.WirelessPowerSaveIndex $saved.Before)) { throw 'The recorded power scheme or original value does not match.' }
                $before = (Get-BhoAcPower -SchemeId $saved.SchemeId).WirelessPowerSaveIndex
            }
        }
        if (-not (Test-BhoEqual $before $saved.Before)) {
            $changes += New-BhoPlanEntry $saved.Id $saved.Label $saved.Kind $saved.Keyword $before $saved.Before $true 'Restore the original saved value.' $saved.SchemeId
        }
    }
    if (-not $changes.Count) { return [pscustomobject]@{ Success = $true; Message = 'The recorded original settings are already present.'; BackupPath = $null; ChangedCount = 0; ReconnectStatus = 'NotRequired' } }
    if (-not $PSCmdlet.ShouldProcess($current.AdapterName, ('Restore ' + $changes.Count + ' original settings from ' + [IO.Path]::GetFileName($Path)))) {
        return [pscustomobject]@{ Success = $true; Message = 'Preview only; no settings or backup files were changed.'; BackupPath = $null; ChangedCount = 0; ReconnectStatus = 'NotRequired' }
    }
    if (-not (Test-BhoAdministrator)) { throw 'Run as administrator to restore settings.' }
    return Invoke-BhoTransaction $current.AdapterId $current $changes (Get-BhoStateRoot $StateRoot) 'Restore'
}

function New-BhoPingClient { New-Object System.Net.NetworkInformation.Ping }

function Invoke-BhoPingRound {
    param([object[]]$Clients, [string[]]$Targets, [int]$TimeoutMs)
    $tasks = @(for ($i = 0; $i -lt $Targets.Count; $i++) {
        try { $Clients[$i].SendPingAsync($Targets[$i], $TimeoutMs) } catch { $null }
    })
    for ($i = 0; $i -lt $Targets.Count; $i++) {
        $status = 'Exception'; $milliseconds = $null
        try {
            if ($null -ne $tasks[$i]) {
                $reply = $tasks[$i].GetAwaiter().GetResult()
                $status = [string]$reply.Status
                if ($status -eq 'Success') { $milliseconds = [double]$reply.RoundtripTime }
            }
        } catch { }
        [pscustomobject]@{ Target = $Targets[$i]; Status = $status; Milliseconds = $milliseconds }
    }
}

function Measure-BhoLatency {
    <# .SYNOPSIS Samples concurrent ICMP RTTs; this is a diagnostic, not a game-jitter measurement. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AdapterId,
        [ValidateRange(10, 1000)][int]$Samples = 100,
        [ValidateRange(100, 5000)][int]$IntervalMs = 250,
        [ValidateCount(1, 8)][string[]]$Targets,
        [ValidateRange(250, 5000)][int]$TimeoutMs = 1000
    )
    $adapter = Resolve-BhoNativeAdapter $AdapterId
    if (-not $Targets) {
        $gateway = Get-BhoNativeGateway $adapter
        $Targets = @(@($gateway, '1.1.1.1', '8.8.8.8') | Where-Object { $_ } | Select-Object -Unique)
    } else { $Targets = @($Targets | Select-Object -Unique) }
    $before = Get-BhoNativeCounters $adapter
    $clients = @($Targets | ForEach-Object { New-BhoPingClient })
    $records = New-Object 'System.Collections.Generic.List[object]'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        for ($sample = 0; $sample -lt $Samples; $sample++) {
            $round = [Diagnostics.Stopwatch]::StartNew()
            foreach ($record in (Invoke-BhoPingRound $clients $Targets $TimeoutMs)) { $records.Add($record) }
            $remaining = $IntervalMs - [int]$round.ElapsedMilliseconds
            if ($sample -lt $Samples - 1 -and $remaining -gt 0) { Start-Sleep -Milliseconds $remaining }
        }
    } finally {
        $clock.Stop()
        foreach ($client in $clients) { $client.Dispose() }
    }
    $after = Get-BhoNativeCounters (Resolve-BhoNativeAdapter $AdapterId)
    $results = @(foreach ($target in $Targets) {
        $all = @($records | Where-Object Target -EQ $target)
        $success = @($all | Where-Object Status -EQ 'Success')
        $values = @($success | ForEach-Object { [double]$_.Milliseconds } | Sort-Object)
        $differences = @()
        for ($i = 1; $i -lt $all.Count; $i++) {
            if ($all[$i].Status -eq 'Success' -and $all[$i - 1].Status -eq 'Success') {
                $differences += [Math]::Abs([double]$all[$i].Milliseconds - [double]$all[$i - 1].Milliseconds)
            }
        }
        [pscustomobject]@{
            Target = $target; Samples = $all.Count; Lost = $all.Count - $success.Count
            LossPercent = [Math]::Round(100.0 * ($all.Count - $success.Count) / $all.Count, 2)
            MeanMs = $(if ($values.Count) { [Math]::Round(($values | Measure-Object -Average).Average, 2) } else { $null })
            P95Ms = $(if ($values.Count) { $values[[Math]::Max(0, [int][Math]::Ceiling($values.Count * 0.95) - 1)] } else { $null })
            MaxMs = $(if ($values.Count) { $values[-1] } else { $null })
            MeanSuccessiveRttDifferenceMs = $(if ($differences.Count) { [Math]::Round(($differences | Measure-Object -Average).Average, 2) } else { $null })
        }
    })
    $received = $null; $sent = $null
    if ($null -ne $before.ReceivedBytes -and $null -ne $after.ReceivedBytes -and $after.ReceivedBytes -ge $before.ReceivedBytes) { $received = [double]$after.ReceivedBytes - [double]$before.ReceivedBytes }
    if ($null -ne $before.SentBytes -and $null -ne $after.SentBytes -and $after.SentBytes -ge $before.SentBytes) { $sent = [double]$after.SentBytes - [double]$before.SentBytes }
    [pscustomobject]@{ DurationSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 2); ReceivedBytes = $received; SentBytes = $sent; Results = $results }
}

Export-ModuleMember -Function Get-BhoAdapters, Get-BhoSnapshot, Get-BhoTuningPlan, Invoke-BhoApply, Get-BhoBackups, Restore-BhoBackup, Measure-BhoLatency
