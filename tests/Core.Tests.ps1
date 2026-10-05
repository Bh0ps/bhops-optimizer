#requires -Version 5.1
<#
Dependency-free core tests. Every Windows platform/network primitive is replaced
inside the module before it is called. These tests never change a real adapter,
power setting, registry value or route and never send a ping packet.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$repoRoot = Split-Path $PSScriptRoot -Parent
$module = Import-Module (Join-Path $repoRoot 'src/BHopsOptimizer.Core.psd1') -Force -PassThru
$testRoot = Join-Path $repoRoot ('tests/.test-state-' + [guid]::NewGuid().ToString('N'))
$script:passed = 0
$script:failed = 0
$script:failures = @()
$script:testLinks = @()
$script:testAdapterId = '11111111-1111-1111-1111-111111111111'
$script:testSchemeId = '99999999-9999-9999-9999-999999999999'

# Module-local fake cmdlets shadow Windows cmdlets, so all paths (including
# rollback and restore) run through the same public API with a fake platform.
& $module {
    $script:BhoOriginalPingRound = (Get-Command Invoke-BhoPingRound).ScriptBlock
    function script:Get-NetAdapter {
        [CmdletBinding()] param([switch]$IncludeHidden)
        $script:BhoTestState.Adapter
    }
    function script:Get-PnpDeviceProperty {
        [CmdletBinding()] param([string]$InstanceId, [string]$KeyName)
        [pscustomobject]@{ Data = @($script:BhoTestState.HardwareIds) }
    }
    function script:Get-CimInstance {
        [CmdletBinding()] param([string]$Namespace, [string]$ClassName)
        switch ($ClassName) {
            'MSPower_DeviceEnable' { $script:BhoTestState.Power }
            'Win32_NetworkAdapter' { [pscustomobject]@{ GUID = $script:BhoTestState.Adapter.InterfaceGuid; PNPDeviceID = $script:BhoTestState.Adapter.PnPDeviceID } }
            'Win32_PnPSignedDriver' { [pscustomobject]@{ DeviceID = $script:BhoTestState.Adapter.PnPDeviceID; DriverVersion = '9.9.9.9' } }
            default { throw ('Unexpected fake CIM class: ' + $ClassName) }
        }
    }
    function script:Get-NetAdapterAdvancedProperty {
        [CmdletBinding()] param([string]$Name, [switch]$AllProperties)
        @($script:BhoTestState.Properties)
    }
    function script:Assert-BhoFakeBackup {
        $files = @(Get-ChildItem -LiteralPath (Join-Path $script:BhoTestState.StateRoot 'backups') -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object Name -NotLike '*.status.json')
        if (-not $files.Count) { throw 'A fake platform mutation occurred before its backup existed.' }
        $script:BhoTestState.BackupSeenBeforeEveryWrite = $true
    }
    function script:Set-NetAdapterAdvancedProperty {
        [CmdletBinding(SupportsShouldProcess = $true)]
        param($InputObject, [string[]]$RegistryValue, [switch]$NoRestart)
        Assert-BhoFakeBackup
        $script:BhoTestState.Writes += ('Advanced:' + $InputObject.RegistryKeyword + '=' + ($RegistryValue -join ','))
        if (-not $script:BhoTestState.IgnoreWrites) {
            $InputObject.RegistryValue = @($RegistryValue)
            $index = [array]::IndexOf([string[]]$InputObject.ValidRegistryValues, [string]$RegistryValue[0])
            if ($index -ge 0) { $InputObject.DisplayValue = $InputObject.ValidDisplayValues[$index] }
        }
        # Throw AFTER mutation to exercise restoration of a partially successful write.
        if ($InputObject.RegistryKeyword -eq $script:BhoTestState.FailKeywordOnce) {
            $script:BhoTestState.FailKeywordOnce = ''
            throw 'Injected write failure after mutation.'
        }
    }
    function script:Set-CimInstance {
        [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject, [hashtable]$Property)
        process {
            Assert-BhoFakeBackup
            $script:BhoTestState.Writes += ('DevicePower=' + $Property.Enable)
            if (-not $script:BhoTestState.IgnoreWrites) { $InputObject.Enable = [bool]$Property.Enable }
        }
    }
    function script:Get-NetRoute {
        [CmdletBinding()] param([int]$InterfaceIndex, [string]$DestinationPrefix)
        if ($script:BhoTestState.Connected) { [pscustomobject]@{ NextHop = '192.0.2.1'; RouteMetric = 10 } }
    }
    function script:Get-NetAdapterStatistics {
        [CmdletBinding()] param([string]$Name)
        $script:BhoTestState.CounterReads++
        [pscustomobject]@{ ReceivedBytes = 1000 * $script:BhoTestState.CounterReads; SentBytes = 300 * $script:BhoTestState.CounterReads; ReceivedDiscardedPackets = 0; OutboundDiscardedPackets = 0; ReceivedPacketErrors = 0; OutboundPacketErrors = 0 }
    }
    function script:Restart-NetAdapter {
        [CmdletBinding(SupportsShouldProcess = $true)] param($InputObject)
        $script:BhoTestState.Restarts++
    }
    function script:Invoke-BhoPowerCfg {
        param([string[]]$Arguments)
        $lines = @()
        switch ($Arguments[0]) {
            '/getactivescheme' { $lines = @('Power Scheme GUID: ' + $script:BhoTestState.ActiveScheme) }
            '/query' {
                $index = [int]$script:BhoTestState.AcIndex
                $lines = @('Localized AC label: ' + ('0x{0:x8}' -f $index), 'Localized DC label: 0x00000002')
            }
            '/setacvalueindex' {
                Assert-BhoFakeBackup
                $script:BhoTestState.Writes += ('AcPower=' + $Arguments[4])
                $script:BhoTestState.AcIndex = [int]$Arguments[4]
            }
            '/setactive' {
                if ($Arguments[1] -ne $script:BhoTestState.ActiveScheme) { throw 'A fake power scheme was unexpectedly switched.' }
                $script:BhoTestState.PowerRefreshes++
            }
            default { throw 'Unexpected fake powercfg operation.' }
        }
        [pscustomobject]@{ ExitCode = 0; Lines = $lines }
    }
    function script:Test-BhoAdministrator { return $script:BhoTestState.IsAdmin }
    function script:Wait-BhoConnection {
        param([string]$AdapterId, [bool]$WasConnected, [int]$TimeoutSeconds = 30)
        if (-not $WasConnected) { return 'NotPreviouslyConnected' }
        $script:BhoTestState.WaitCalls++
        if ($script:BhoTestState.TimeoutOnce) { $script:BhoTestState.TimeoutOnce = $false; return 'TimedOut' }
        return 'Connected'
    }
    function script:Start-Sleep { [CmdletBinding()] param([int]$Milliseconds, [int]$Seconds) }
    function script:New-BhoPingClient {
        $client = [pscustomobject]@{}
        $client | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        return $client
    }
    function script:Invoke-BhoPingRound {
        param([object[]]$Clients, [string[]]$Targets, [int]$TimeoutMs)
        $round = $script:BhoTestState.PingRound
        $script:BhoTestState.PingRound++
        foreach ($target in $Targets) {
            if ($script:BhoTestState.AllPingsLost -or ($target -eq '192.0.2.1' -and $round -eq 2)) {
                [pscustomobject]@{ Target = $target; Status = 'TimedOut'; Milliseconds = $null }
            } else {
                $rtt = 8.0
                if ($target -eq '192.0.2.1') { $rtt = 10.0 * ($round + 1) }
                [pscustomobject]@{ Target = $target; Status = 'Success'; Milliseconds = $rtt }
            }
        }
    }
}

function New-TestProperty {
    param([string]$Keyword, [string]$Current, [string[]]$Values, [string[]]$Labels)
    $index = [array]::IndexOf($Values, $Current)
    [pscustomobject]@{ RegistryKeyword = $Keyword; RegistryValue = @($Current); DisplayName = $Keyword; DisplayValue = $Labels[$index]; ValidRegistryValues = @($Values); ValidDisplayValues = @($Labels) }
}

function Reset-TestState {
    $casePath = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    $script:state = [pscustomobject]@{
        StateRoot = $casePath
        Adapter = [pscustomobject]@{ InterfaceGuid = $script:testAdapterId; Name = 'Fake Wi-Fi'; InterfaceDescription = 'MediaTek fake adapter'; Status = 'Up'; LinkSpeed = '1 Gbps'; DriverVersion = '1.2.3.4'; NdisPhysicalMedium = 9; HardwareInterface = $true; ifIndex = 99; PnPDeviceID = 'PCI\VEN_14C3&DEV_0616\FAKE' }
        HardwareIds = @('PCI\VEN_14C3&DEV_0616&SUBSYS_FAKE')
        Properties = @(
            (New-TestProperty 'PreferredBand' '0' @('0', '42', '6') @('1. No Preference', '2. Prefer 5 GHz', '3. Prefer 6 GHz')),
            (New-TestProperty 'RoamIndicateTh' '4' @('0', '1', '4') @('1. Highest', '2. Lowest', '5. Medium-High')),
            (New-TestProperty 'LowPowerEnable' '0' @('0', '1') @('Disabled', 'Enabled'))
        )
        Power = [pscustomobject]@{ InstanceName = 'PCI\VEN_14C3&DEV_0616\FAKE_0'; Enable = $true }
        ActiveScheme = $script:testSchemeId; AcIndex = 3; PowerRefreshes = 0
        Connected = $true; IsAdmin = $true; Writes = @(); Restarts = 0; WaitCalls = 0
        FailKeywordOnce = ''; IgnoreWrites = $false; TimeoutOnce = $false
        BackupSeenBeforeEveryWrite = $false; CounterReads = 0; PingRound = 0; AllPingsLost = $false
    }
    & $module { param($State) $script:BhoTestState = $State } $script:state
}

function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Actual, $Expected, [string]$Message) if ([string]$Actual -cne [string]$Expected) { throw ($Message + ' Expected [' + $Expected + '], got [' + $Actual + '].') } }
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern = '.')
    try { & $Action | Out-Null } catch { if ($_.Exception.Message -match $Pattern) { return }; throw }
    throw 'Expected an exception, but none was thrown.'
}
function Test-CoreCase {
    param([string]$Name, [scriptblock]$Action)
    Reset-TestState
    try { & $Action; $script:passed++; Write-Output ('PASS ' + $Name) }
    catch { $script:failed++; $script:failures += ($Name + ': ' + $_.Exception.Message); Write-Output ('FAIL ' + $Name + ': ' + $_.Exception.Message) }
}
function Read-TestBackup { param([string]$Path) Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
function Write-TestBackupCopy {
    param($Backup)
    [IO.Directory]::CreateDirectory($state.StateRoot) | Out-Null
    $path = Join-Path $state.StateRoot 'edited-copy.json'
    $Backup | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function New-TestJunction {
    param([string]$Path, [string]$Target)
    $allowed = [IO.Path]::GetFullPath($testRoot) + [IO.Path]::DirectorySeparatorChar
    foreach ($candidate in @($Path, $Target)) {
        if (-not [IO.Path]::GetFullPath($candidate).StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test junction paths must remain inside the test root.' }
    }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.Directory]::CreateDirectory($Target) | Out-Null
    New-Item -ItemType Junction -Path $Path -Value $Target -ErrorAction Stop | Out-Null
    $script:testLinks += [IO.Path]::GetFullPath($Path)
}

function New-TestLinkTarget {
    $target = Join-Path $testRoot ('target-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($target) | Out-Null
    return $target
}

try {
    Test-CoreCase 'Inventory and snapshot bind GUID, hardware and exact capabilities' {
        $adapters = @(Get-BhoAdapters)
        Assert-Equal $adapters.Count 1 'Adapter count.'
        Assert-True $adapters[0].IsWifi 'Expected fake Wi-Fi adapter.'
        $snapshot = Get-BhoSnapshot -AdapterId $testAdapterId
        Assert-Equal $snapshot.AdapterId $testAdapterId 'GUID binding.'
        Assert-Equal $snapshot.Properties.Count 3 'Snapshot properties.'
        Assert-True $snapshot.DevicePower.Supported 'Device-power capability.'
        Assert-Equal $snapshot.AcPower.WirelessPowerSaveIndex 3 'Locale-independent power query.'
        Assert-Equal $snapshot.DefaultGateway '192.0.2.1' 'Gateway.'
        Assert-Equal $state.Writes.Count 0 'Read-only calls must not write.'
    }
    Test-CoreCase 'Plan resolves actual display/value pairs rather than vendor numeric guesses' {
        $plan = @(Get-BhoTuningPlan (Get-BhoSnapshot $testAdapterId) -Options Prefer5GHz,LowRoaming,DisablePowerSaving,MaximumTransmitPower,DisableUapsd,AcPerformance)
        $band = $plan | Where-Object Id -EQ 'Prefer5GHz.Advanced'
        Assert-Equal $band.After[0] '42' 'Driver-defined 5 GHz value.'
        Assert-Equal ($plan | Where-Object Id -EQ 'LowRoaming.Advanced').After[0] '1' 'Lowest roaming value.'
        Assert-Equal @($plan | Where-Object { -not $_.Supported }).Count 2 'Missing capabilities are skipped.'
        Assert-True (-not ($plan | Where-Object Id -EQ 'DisablePowerSaving.Advanced').Changed) 'Already disabled power must remain unchanged.'
        Assert-Equal $state.Writes.Count 0 'A plan must not write.'
    }
    Test-CoreCase 'Ambiguous labels and mismatched capability arrays are skipped' {
        $state.Properties[0].ValidDisplayValues = @('No Preference', 'Prefer 5 GHz', 'Prefer 5 GHz')
        Assert-True (-not @(Get-BhoTuningPlan (Get-BhoSnapshot $testAdapterId) -Options Prefer5GHz)[0].Supported) 'Ambiguous labels must be skipped.'
        $state.Properties[0].ValidDisplayValues = @('No Preference')
        Assert-True (-not @(Get-BhoTuningPlan (Get-BhoSnapshot $testAdapterId) -Options Prefer5GHz)[0].Supported) 'Unpaired values must be skipped.'
    }
    Test-CoreCase 'Unknown current values and duplicate registry mappings cannot create an unsafe plan' {
        $state.Properties[0].RegistryValue = @('not-enumerated')
        Assert-True (-not @(Get-BhoTuningPlan (Get-BhoSnapshot $testAdapterId) -Options Prefer5GHz)[0].Supported) 'Unknown original value must be skipped.'
        $state.Properties[0].RegistryValue = @('0')
        $state.Properties[0].ValidRegistryValues = @('0', '42', '42')
        Assert-True (-not @(Get-BhoTuningPlan (Get-BhoSnapshot $testAdapterId) -Options Prefer5GHz)[0].Supported) 'Duplicate mappings must be skipped.'
    }
    Test-CoreCase 'Intel properties use validated labels with arbitrary driver values' {
        $state.HardwareIds = @('PCI\VEN_8086&DEV_FAKE')
        $state.Adapter.InterfaceDescription = 'Intel fake adapter'
        $state.Properties = @(
            (New-TestProperty 'RoamingPreferredBand' '9' @('9', '77') @('No Preference', 'Prefer 5 GHz band')),
            (New-TestProperty 'RoamAggressiveness' '9' @('9', '88') @('Medium', '1. Lowest')),
            (New-TestProperty 'TransmitPower' '9' @('9', '99') @('Lowest', '5. Highest')),
            (New-TestProperty 'uAPSDSupport' '9' @('9', '66') @('Enabled', 'Disabled'))
        )
        $plan = @(Get-BhoTuningPlan (Get-BhoSnapshot $testAdapterId) -Options Prefer5GHz,LowRoaming,MaximumTransmitPower,DisableUapsd)
        Assert-Equal ($plan.After | ForEach-Object { $_ } | Sort-Object) @('66', '77', '88', '99') 'Intel paired values.'
        Assert-Equal @($plan | Where-Object { -not $_.Supported }).Count 0 'Intel exposed capabilities.'
    }
    Test-CoreCase 'Unknown vendors and Ethernet adapters are not given blind tuning values' {
        $state.HardwareIds = @('PCI\VEN_1234&DEV_FAKE')
        $state.Adapter.InterfaceDescription = 'Unknown adapter'
        Assert-True (-not @(Get-BhoTuningPlan (Get-BhoSnapshot $testAdapterId) -Options Prefer5GHz)[0].Supported) 'Unknown vendor must be skipped.'
        $state.Adapter.NdisPhysicalMedium = 0
        Assert-True (-not @(Get-BhoTuningPlan (Get-BhoSnapshot $testAdapterId) -Options AcPerformance)[0].Supported) 'Ethernet must be skipped.'
    }
    Test-CoreCase 'Wi-Fi Direct virtual interfaces with an 802.11 medium are ineligible' {
        $state.Adapter.Name = 'Local Area Connection* 1'
        $state.Adapter.InterfaceDescription = 'Microsoft Wi-Fi Direct Virtual Adapter'
        $state.Adapter.HardwareInterface = $false
        $state.Adapter.NdisPhysicalMedium = 9
        Assert-True (-not @(Get-BhoAdapters)[0].IsWifi) 'Virtual interface must not appear as eligible Wi-Fi.'
        Assert-True (-not (Get-BhoSnapshot $testAdapterId).IsWifi) 'Virtual snapshot eligibility.'
        Assert-Throws { Invoke-BhoApply $testAdapterId -Options AcPerformance -StateRoot $state.StateRoot -Confirm:$false } 'physical Wi-Fi'
        Assert-Equal $state.Writes.Count 0 'Virtual adapter must never be mutated.'
        Assert-True (-not (Test-Path -LiteralPath $state.StateRoot)) 'Virtual apply must not create state.'
    }
    Test-CoreCase 'Virtual identity blocks tuning even if a hardware flag is misleading or absent' {
        $state.Adapter.PnPDeviceID = 'SWD\WIFIDIRECT\FAKE'
        Assert-True (-not @(Get-BhoAdapters)[0].IsWifi) 'Software-device identity must be ineligible despite hardware flag.'
        $state.Adapter.PnPDeviceID = 'PCI\VEN_14C3&DEV_0616\FAKE'
        $state.Adapter.PSObject.Properties.Remove('HardwareInterface')
        $state.Adapter.InterfaceDescription = 'Microsoft Hosted Network Virtual Adapter'
        Assert-True (-not @(Get-BhoAdapters)[0].IsWifi) 'Known virtual description must be ineligible without hardware flag.'
        $state.Adapter.InterfaceDescription = 'MediaTek fake adapter'
        Assert-True @(Get-BhoAdapters)[0].IsWifi 'Older physical providers without a hardware flag remain readable.'
    }
    Test-CoreCase 'WhatIf needs no elevation, writes no backup and changes no platform state' {
        $state.IsAdmin = $false
        $result = Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -WhatIf
        Assert-Equal $result.ChangedCount 0 'WhatIf changes.'
        Assert-Equal $state.Writes.Count 0 'WhatIf platform writes.'
        Assert-True (-not (Test-Path -LiteralPath $state.StateRoot)) 'WhatIf must not create files.'
    }
    Test-CoreCase 'Actual apply requires elevation before creating any state' {
        $state.IsAdmin = $false
        Assert-Throws { Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false } 'administrator'
        Assert-Equal $state.Writes.Count 0 'Denied writes.'
        Assert-True (-not (Test-Path -LiteralPath $state.StateRoot)) 'Denied apply must not create state.'
    }
    Test-CoreCase 'A junction at StateRoot is rejected before any write or mutation' {
        $target = New-TestLinkTarget
        New-TestJunction -Path $state.StateRoot -Target $target
        Assert-Throws { Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false } 'reparse-point'
        Assert-Equal $state.Writes.Count 0 'Junction root must not permit platform mutation.'
        Assert-Equal @(Get-ChildItem -LiteralPath $target -Force).Count 0 'Junction target must remain untouched.'
    }
    Test-CoreCase 'A junction ancestor is rejected even when the StateRoot leaf is missing' {
        $target = New-TestLinkTarget
        $link = Join-Path $state.StateRoot 'ancestor'
        New-TestJunction -Path $link -Target $target
        $state.StateRoot = Join-Path $link 'missing-state'
        Assert-Throws { Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false } 'reparse-point'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'missing-state'))) 'Missing leaf must not be created through an ancestor junction.'
        Assert-Equal $state.Writes.Count 0 'Unsafe ancestry must not mutate platform state.'
    }
    Test-CoreCase 'A child backups junction is rejected before backup creation or platform mutation' {
        $target = New-TestLinkTarget
        New-TestJunction -Path (Join-Path $state.StateRoot 'backups') -Target $target
        $result = Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false
        Assert-True (-not $result.Success) 'Unsafe backups child must fail.'
        Assert-True ($result.Message -match 'reparse-point') 'Unsafe-child failure detail.'
        Assert-Equal $state.Writes.Count 0 'No writes after unsafe child validation.'
        Assert-Equal @(Get-ChildItem -LiteralPath $target -Force).Count 0 'No escaped backup or manifest writes.'
        Assert-Throws { Get-BhoBackups -StateRoot $state.StateRoot } 'reparse-point'
    }
    Test-CoreCase 'Dangling junction ancestry is still rejected instead of creating its missing target' {
        $target = New-TestLinkTarget
        New-TestJunction -Path $state.StateRoot -Target $target
        [IO.Directory]::Delete($target, $false)
        Assert-Throws { Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false } 'reparse-point'
        Assert-True (-not (Test-Path -LiteralPath $target)) 'Missing junction target must not be recreated.'
        Assert-Equal $state.Writes.Count 0 'Dangling junction must not permit mutation.'
    }
    Test-CoreCase 'Reparse leaves at the lock and log paths are rejected explicitly before mutation' {
        $lockTarget = New-TestLinkTarget
        $logTarget = New-TestLinkTarget
        New-TestJunction -Path (Join-Path $state.StateRoot 'operation.lock') -Target $lockTarget
        New-TestJunction -Path (Join-Path $state.StateRoot 'operations.jsonl') -Target $logTarget
        $result = Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false
        Assert-True (-not $result.Success) 'Unsafe lock/log leaves must fail.'
        Assert-True ($result.Message -match 'reparse-point') 'Explicit reparse validation must reject lock/log leaves.'
        Assert-Equal $state.Writes.Count 0 'Unsafe leaves must be rejected before platform writes.'
        Assert-Equal @(Get-ChildItem -LiteralPath $lockTarget -Force).Count 0 'Lock target must remain untouched.'
        Assert-Equal @(Get-ChildItem -LiteralPath $logTarget -Force).Count 0 'Log target must remain untouched.'
    }
    Test-CoreCase 'The logger independently refuses a junction ancestor and cannot write through it' {
        $target = New-TestLinkTarget
        New-TestJunction -Path $state.StateRoot -Target $target
        & $module { param($Root) Write-BhoLog $Root 'Test' '11111111-1111-1111-1111-111111111111' '' $false 'Fake test message.' } $state.StateRoot -WarningAction SilentlyContinue
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $target 'operations.jsonl'))) 'Logger must not follow a junction.'
    }
    Test-CoreCase 'The JSON writer independently rejects linked ancestry for status and replace paths' {
        $target = New-TestLinkTarget
        New-TestJunction -Path $state.StateRoot -Target $target
        $path = Join-Path $state.StateRoot 'fake.status.json'
        Assert-Throws { & $module { param($Path) Write-BhoJson -Path $Path -Value ([pscustomobject]@{ Status = 'Fake' }) } $path } 'reparse-point'
        Assert-Equal @(Get-ChildItem -LiteralPath $target -Force).Count 0 'No JSON temporary/replacement files may escape.'
    }
    Test-CoreCase 'Apply saves exact original values first, verifies writes and lists backup status' {
        $result = Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false
        Assert-True $result.Success $result.Message
        Assert-Equal $result.ChangedCount 3 'Apply changes.'
        Assert-True $state.BackupSeenBeforeEveryWrite 'Backup must precede every fake write.'
        Assert-Equal $state.Properties[0].RegistryValue[0] '42' 'Applied band.'
        Assert-Equal $state.Power.Enable $false 'Applied device power.'
        Assert-Equal $state.Restarts 1 'One grouped adapter restart.'
        $backup = Read-TestBackup $result.BackupPath
        Assert-Equal $backup.Snapshot.Properties[0].RegistryValue[0] '0' 'Exact original band.'
        Assert-Equal $backup.Snapshot.Properties[1].RegistryValue[0] '4' 'Exact original roaming.'
        Assert-Equal $backup.Snapshot.DevicePower.Enabled $true 'Exact original power.'
        Assert-Equal @(Get-BhoBackups $state.StateRoot).Count 1 'Backup list count.'
        Assert-Equal @(Get-BhoBackups $state.StateRoot)[0].Status 'Applied' 'Backup status.'
    }
    Test-CoreCase 'Idempotent reapply does not create a new backup or restart' {
        $first = Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false
        $writes = $state.Writes.Count
        $second = Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false
        Assert-True $second.Success 'Idempotent apply.'
        Assert-Equal $second.ChangedCount 0 'Idempotent changes.'
        Assert-Equal $state.Writes.Count $writes 'Idempotent platform writes.'
        Assert-Equal @(Get-BhoBackups $state.StateRoot).Count 1 'Idempotent backup count.'
    }
    Test-CoreCase 'A cmdlet throwing after mutation restores all attempted exact original values' {
        $state.FailKeywordOnce = 'RoamIndicateTh'
        $result = Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false
        Assert-True (-not $result.Success) 'Injected mutation must fail.'
        Assert-True $result.RollbackSucceeded 'Automatic rollback must succeed.'
        Assert-Equal $state.Properties[0].RegistryValue[0] '0' 'Rolled-back band.'
        Assert-Equal $state.Properties[1].RegistryValue[0] '4' 'Rolled-back partial roaming write.'
        Assert-Equal $state.Power.Enable $true 'Original power.'
        Assert-Equal @(Get-BhoBackups $state.StateRoot)[0].Status 'RolledBack' 'Rollback status.'
    }
    Test-CoreCase 'Read-back verification failures are not falsely reported as success' {
        $state.IgnoreWrites = $true
        $result = Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false
        Assert-True (-not $result.Success) 'Silent ignored writes must fail verification.'
        Assert-True $result.RollbackSucceeded 'Original values should remain verified.'
        Assert-True ($result.Message -match 'Verification failed') 'Verification failure detail.'
    }
    Test-CoreCase 'Reconnect timeout triggers rollback and a failure result' {
        $state.TimeoutOnce = $true
        $result = Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false
        Assert-True (-not $result.Success) 'Reconnect timeout must not report success.'
        Assert-True $result.RollbackSucceeded 'Rollback after reconnect timeout.'
        Assert-Equal $result.ReconnectStatus 'Connected' 'Rollback reconnected.'
        Assert-Equal $state.Properties[0].RegistryValue[0] '0' 'Original band after timeout.'
    }
    Test-CoreCase 'Restore is exact and leaves the original backup bytes unchanged' {
        $apply = Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false
        $hashBefore = (Get-FileHash -LiteralPath $apply.BackupPath -Algorithm SHA256).Hash
        $result = Restore-BhoBackup $apply.BackupPath -StateRoot $state.StateRoot -Confirm:$false
        Assert-True $result.Success $result.Message
        Assert-Equal $state.Properties[0].RegistryValue[0] '0' 'Restored band.'
        Assert-Equal $state.Properties[1].RegistryValue[0] '4' 'Restored roaming.'
        Assert-Equal $state.Power.Enable $true 'Restored power.'
        Assert-Equal ((Get-FileHash -LiteralPath $apply.BackupPath -Algorithm SHA256).Hash) $hashBefore 'Original backup immutability.'
        Assert-Equal @(Get-BhoBackups $state.StateRoot).Count 2 'Restore recovery backup.'
        Assert-Equal $state.Adapter.DriverVersion '1.2.3.4' 'Restore must not alter driver version.'
    }
    Test-CoreCase 'Restore WhatIf changes no state and requires no admin' {
        $apply = Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false
        $state.IsAdmin = $false
        $writes = $state.Writes.Count
        $result = Restore-BhoBackup $apply.BackupPath -StateRoot $state.StateRoot -WhatIf
        Assert-True $result.Success 'Restore preview.'
        Assert-Equal $state.Writes.Count $writes 'Restore preview writes.'
        Assert-Equal @(Get-BhoBackups $state.StateRoot).Count 1 'Restore preview backups.'
    }
    Test-CoreCase 'Restore rejects different hardware before any mutation' {
        $apply = Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false
        $state.HardwareIds = @('PCI\VEN_14C3&DEV_DIFFERENT')
        $writes = $state.Writes.Count
        Assert-Throws { Restore-BhoBackup $apply.BackupPath -StateRoot $state.StateRoot -Confirm:$false } 'hardware IDs'
        Assert-Equal $state.Writes.Count $writes 'Different hardware must not write.'
    }
    Test-CoreCase 'Restore rejects arbitrary kinds and properties from JSON' {
        $apply = Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false
        $backup = Read-TestBackup $apply.BackupPath
        $backup.Changes[0].Kind = 'Registry'
        $path = Write-TestBackupCopy $backup
        $writes = $state.Writes.Count
        Assert-Throws { Restore-BhoBackup $path -StateRoot $state.StateRoot -Confirm:$false } 'unrecognized mutation kind'
        $backup = Read-TestBackup $apply.BackupPath
        $backup.Changes[0].Keyword = 'TcpAckFrequency'
        $path = Write-TestBackupCopy $backup
        Assert-Throws { Restore-BhoBackup $path -StateRoot $state.StateRoot -Confirm:$false } 'outside the allowed'
        Assert-Equal $state.Writes.Count $writes 'Rejected backup must not write.'
    }
    Test-CoreCase 'Restore rejects unsupported original values before changing any setting' {
        $apply = Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false
        $state.Properties[1].ValidRegistryValues = @('0', '1')
        $state.Properties[1].ValidDisplayValues = @('Highest', 'Lowest')
        $writes = $state.Writes.Count
        Assert-Throws { Restore-BhoBackup $apply.BackupPath -StateRoot $state.StateRoot -Confirm:$false } 'Unsupported value'
        Assert-Equal $state.Writes.Count $writes 'Unsupported restore must not partially write.'
    }
    Test-CoreCase 'Restore rejects backup input reached through a junction outside StateRoot' {
        $apply = Invoke-BhoApply $testAdapterId -StateRoot $state.StateRoot -Confirm:$false
        $link = Join-Path $testRoot ('restore-link-' + [guid]::NewGuid().ToString('N'))
        New-TestJunction -Path $link -Target ([IO.Path]::GetDirectoryName($apply.BackupPath))
        $inputPath = Join-Path $link ([IO.Path]::GetFileName($apply.BackupPath))
        $writes = $state.Writes.Count
        Assert-Throws { Restore-BhoBackup $inputPath -StateRoot $state.StateRoot -Confirm:$false } 'reparse-point'
        Assert-Equal $state.Writes.Count $writes 'Linked restore input must not mutate anything.'
        # An ordinary copied file outside the state root remains supported.
        $copyPath = Join-Path (New-TestLinkTarget) 'ordinary-backup.json'
        Copy-Item -LiteralPath $apply.BackupPath -Destination $copyPath
        $result = Restore-BhoBackup $copyPath -StateRoot $state.StateRoot -WhatIf
        Assert-True $result.Success 'An ordinary external backup file may be previewed.'
    }
    Test-CoreCase 'AC performance changes only the recorded AC wireless index and restores it' {
        $apply = Invoke-BhoApply $testAdapterId -Options AcPerformance -StateRoot $state.StateRoot -Confirm:$false
        Assert-True $apply.Success $apply.Message
        Assert-Equal $state.AcIndex 0 'AC maximum performance.'
        Assert-Equal $state.ActiveScheme $testSchemeId 'Power scheme preserved.'
        Assert-Equal $state.Restarts 0 'AC-only settings need no adapter restart.'
        $restored = Restore-BhoBackup $apply.BackupPath -StateRoot $state.StateRoot -Confirm:$false
        Assert-True $restored.Success $restored.Message
        Assert-Equal $state.AcIndex 3 'Restored original AC index.'
    }
    Test-CoreCase 'Restoring an inactive AC scheme captures a correct recovery backup without switching schemes' {
        $apply = Invoke-BhoApply $testAdapterId -Options AcPerformance -StateRoot $state.StateRoot -Confirm:$false
        $newScheme = '88888888-8888-8888-8888-888888888888'
        $state.ActiveScheme = $newScheme
        $restored = Restore-BhoBackup $apply.BackupPath -StateRoot $state.StateRoot -Confirm:$false
        Assert-True $restored.Success $restored.Message
        Assert-Equal $state.ActiveScheme $newScheme 'Inactive restore must preserve the active scheme.'
        $recovery = Read-TestBackup $restored.BackupPath
        Assert-Equal $recovery.Snapshot.AcPower.SchemeId $testSchemeId 'Recovery records the scheme actually changed.'
        Assert-Equal $recovery.Snapshot.AcPower.WirelessPowerSaveIndex 0 'Recovery records the exact pre-restore index.'
        $undoRestore = Restore-BhoBackup $restored.BackupPath -StateRoot $state.StateRoot -Confirm:$false
        Assert-True $undoRestore.Success $undoRestore.Message
        Assert-Equal $state.AcIndex 0 'Recovery backup restores the pre-restore index.'
    }
    Test-CoreCase 'A failed asynchronous probe start keeps the correct target-to-result positions' {
        $broken = [pscustomobject]@{}
        $broken | Add-Member -MemberType ScriptMethod -Name SendPingAsync -Value { param($Target, $Timeout) throw 'Fake start failure.' }
        $healthy = [pscustomobject]@{}
        $healthy | Add-Member -MemberType ScriptMethod -Name SendPingAsync -Value {
            param($Target, $Timeout)
            $task = [pscustomobject]@{}
            $task | Add-Member -MemberType ScriptMethod -Name GetAwaiter -Value {
                $awaiter = [pscustomobject]@{}
                $awaiter | Add-Member -MemberType ScriptMethod -Name GetResult -Value { [pscustomobject]@{ Status = 'Success'; RoundtripTime = 7 } }
                return $awaiter
            }
            return $task
        }
        $records = @(& $module { param($Clients) & $script:BhoOriginalPingRound -Clients $Clients -Targets @('fake-invalid', 'fake-healthy') -TimeoutMs 250 } @($broken, $healthy))
        Assert-Equal $records.Count 2 'One result per target.'
        Assert-Equal $records[0].Status 'Exception' 'Failed start status.'
        Assert-Equal $records[1].Target 'fake-healthy' 'Successful target position.'
        Assert-Equal $records[1].Milliseconds 7 'Successful target RTT.'
    }
    Test-CoreCase 'Latency uses fake probes, correct loss/percentiles and excludes loss-adjacent deltas' {
        $result = Measure-BhoLatency $testAdapterId -Samples 10 -IntervalMs 100
        Assert-Equal $result.Results.Count 3 'Default targets.'
        $gateway = $result.Results | Where-Object Target -EQ '192.0.2.1'
        Assert-Equal $gateway.Samples 10 'Ping samples.'
        Assert-Equal $gateway.Lost 1 'Lost sample.'
        Assert-Equal $gateway.LossPercent 10 'Loss percentage.'
        Assert-Equal $gateway.MeanMs 57.78 'Success-only mean.'
        Assert-Equal $gateway.P95Ms 100 'Nearest-rank 95th percentile.'
        Assert-Equal $gateway.MeanSuccessiveRttDifferenceMs 10 'Only adjacent successful probes are compared.'
        Assert-Equal $result.ReceivedBytes 1000 'Counter difference.'
        Assert-Equal $state.Writes.Count 0 'Diagnostics must not mutate settings.'
    }
    Test-CoreCase 'All lost probes report null RTT metrics rather than zero latency' {
        $state.AllPingsLost = $true
        $result = Measure-BhoLatency $testAdapterId -Samples 10 -IntervalMs 100 -Targets '192.0.2.1'
        Assert-Equal $result.Results[0].Lost 10 'All probes lost.'
        Assert-Equal $result.Results[0].LossPercent 100 'All-loss percentage.'
        Assert-True ($null -eq $result.Results[0].MeanMs) 'Mean should be unavailable.'
        Assert-True ($null -eq $result.Results[0].P95Ms) 'Percentile should be unavailable.'
    }
    Test-CoreCase 'Invalid adapter IDs and diagnostic bounds are rejected' {
        Assert-Throws { Get-BhoSnapshot -AdapterId 'not-a-guid' } 'valid network adapter GUID'
        Assert-Throws { Measure-BhoLatency $testAdapterId -Samples 1 } '.'
        Assert-Throws { Measure-BhoLatency $testAdapterId -IntervalMs 0 } '.'
    }
} finally {
    # Verify a resolved absolute path before recursive test cleanup.
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $allowedParent = [IO.Path]::GetFullPath((Join-Path $repoRoot 'tests')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTestRoot.StartsWith($allowedParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test cleanup path escaped the tests directory.' }
    # Unlink junctions themselves without traversing their targets before any
    # recursive cleanup. Targets are also confined to the owned test root.
    foreach ($link in @($script:testLinks | Sort-Object Length -Descending)) {
        $resolvedLink = [IO.Path]::GetFullPath($link)
        if (-not $resolvedLink.StartsWith($resolvedTestRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test link cleanup escaped the test root.' }
        $item = Get-Item -LiteralPath $resolvedLink -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { [IO.Directory]::Delete($resolvedLink, $false) }
    }
    if (Test-Path -LiteralPath $resolvedTestRoot) { Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force }
    Remove-Module $module -ErrorAction SilentlyContinue
}
Write-Output ('Core tests: ' + $script:passed + ' passed, ' + $script:failed + ' failed. No real network or settings were touched.')
if ($script:failed) { throw ($script:failures -join [Environment]::NewLine) }
