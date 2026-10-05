#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Gui','Inventory','Diagnose','Plan','Apply','Restore','SystemPlan','SystemApply','SystemRestore','DriverCheck','DriverInstall','Worker')]
    [string]$Action = 'Gui',
    [ValidateSet('Network','System','Gaming','Minimal')][string]$Preset = 'Network',
    [string]$AdapterId,
    [string[]]$Options,
    [string[]]$Tweaks,
    [string]$BackupPath,
    [string]$OfferId,
    [ValidateRange(10,1000)][int]$Samples = 100,
    [string]$StateRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'BHopsOptimizer\State'),
    [string]$RequestPath,
    [string]$ResponsePath,
    [switch]$Demo,
    [switch]$SmokeTest,
    [string]$ScreenshotPath,
    [ValidateSet('Overview','Network','System','Gaming','Diagnostics','Drivers','Backups')][string]$PreviewPage='Overview'
)
$ErrorActionPreference = 'Stop'
$script:AppRoot = $PSScriptRoot
$script:AppVersion = '0.2.0'
Import-Module (Join-Path $PSScriptRoot 'src\BHopsOptimizer.Core.psd1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'src\BHopsOptimizer.System.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'src\BHopsOptimizer.Drivers.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'src\BHopsOptimizer.Worker.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'src\BHopsOptimizer.Presentation.psm1') -Force -DisableNameChecking

function Test-BhoAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-BhoAllBackups {
    $items = @()
    foreach ($record in @(Get-BhoBackups -StateRoot $StateRoot)) {
        $record | Add-Member -NotePropertyName Type -NotePropertyValue 'Network' -Force
        $record | Add-Member -NotePropertyName RequiresAdmin -NotePropertyValue $true -Force
        $items += $record
    }
    foreach ($record in @(Get-BhoSystemBackups -StateRoot $StateRoot)) {
        $record | Add-Member -NotePropertyName Type -NotePropertyValue 'System' -Force
        $record | Add-Member -NotePropertyName AdapterName -NotePropertyValue 'Windows / Gaming settings' -Force
        $items += $record
    }
    return @($items | Sort-Object CreatedAt -Descending)
}
function Resolve-BhoAdapterId {
    param([string]$Requested)
    if ($Requested) { return $Requested }
    $adapters = @(Get-BhoAdapters | Where-Object IsWifi)
    $active = @($adapters | Where-Object Status -eq 'Up')
    if ($active.Count -gt 1 -or ($active.Count -eq 0 -and $adapters.Count -gt 1)) {
        throw 'More than one Wi-Fi adapter is available. Choose an AdapterId from -Action Inventory.'
    }
    if ($active.Count -eq 1) { return $active[0].Id }
    if ($adapters.Count -eq 1) { return $adapters[0].Id }
    throw 'No physical Wi-Fi adapter was found. System and Gaming selections can still be used.'
}
function Invoke-BhoOperation {
    param([string]$Operation,[object]$Arguments)
    switch ($Operation) {
        'Inventory' { return [pscustomobject]@{Adapters=@(Get-BhoAdapters);Tweaks=@(Get-BhoSystemTweaks);Backups=@(Get-BhoAllBackups);Version=$script:AppVersion} }
        'Snapshot' { return Get-BhoSnapshot -AdapterId $Arguments.AdapterId }
        'NetworkPlan' {
            $snapshot = Get-BhoSnapshot -AdapterId $Arguments.AdapterId
            return @(Get-BhoTuningPlan -Snapshot $snapshot -Options @($Arguments.Options))
        }
        'NetworkPreview' {
            $snapshot=Get-BhoSnapshot -AdapterId $Arguments.AdapterId
            return [pscustomobject]@{Snapshot=$snapshot;Plan=@(Get-BhoTuningPlan -Snapshot $snapshot -Options @($Arguments.Options))}
        }
        'NetworkApply' { return Invoke-BhoApply -AdapterId $Arguments.AdapterId -Options @($Arguments.Options) -StateRoot $StateRoot -WhatIf:([bool]$Arguments.DryRun) -Confirm:$false }
        'NetworkRestore' { return Restore-BhoBackup -Path $Arguments.BackupPath -StateRoot $StateRoot -WhatIf:([bool]$Arguments.DryRun) -Confirm:$false }
        'SystemPlan' { return @(Get-BhoSystemPlan -Ids @($Arguments.Ids)) }
        'SystemApply' { return Invoke-BhoSystemApply -Ids @($Arguments.Ids) -StateRoot $StateRoot -WhatIf:([bool]$Arguments.DryRun) -Confirm:$false }
        'SystemRestore' { return Restore-BhoSystemBackup -Path $Arguments.BackupPath -StateRoot $StateRoot -WhatIf:([bool]$Arguments.DryRun) -Confirm:$false }
        'Diagnostics' { return Measure-BhoLatency -AdapterId $Arguments.AdapterId -Samples ([int]$Arguments.Samples) }
        'DriverCheck' { return Get-BhoDriverOffers -AdapterId $Arguments.AdapterId }
        'DriverInstall' { return Invoke-BhoDriverInstall -AdapterId $Arguments.AdapterId -OfferId $Arguments.OfferId -StateRoot $StateRoot -WhatIf:([bool]$Arguments.DryRun) -Confirm:$false }
        'Backups' { return @(Get-BhoAllBackups) }
        default { throw 'Unknown operation. No changes were made.' }
    }
}
if ($Action -eq 'Worker') {
    # The UI passes structured data, never a script string, to its background worker.
    $workerPathsValidated=$false
    try {
        if (-not $RequestPath -or -not $ResponsePath) { throw 'Worker request and response paths are required.' }
        $workerPaths=Assert-BhoWorkerPaths -StateRoot $StateRoot -RequestPath $RequestPath -ResponsePath $ResponsePath
        $RequestPath=$workerPaths.RequestPath;$ResponsePath=$workerPaths.ResponsePath;$workerPathsValidated=$true
        $request = Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
        if ($request.SchemaVersion -ne 1) { throw 'Unsupported worker request.' }
        $mutation = $request.Operation -in @('NetworkApply','NetworkRestore','SystemApply','SystemRestore','DriverInstall')
        $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        if ($mutation -and $request.RequesterSid -ne $currentSid) { throw 'Apply changes using your signed-in Windows account. Elevating as a different account would target the wrong user settings.' }
        $data = Invoke-BhoOperation -Operation $request.Operation -Arguments $request.Arguments
        $response = [pscustomobject]@{Success=$true;Data=$data;Error=$null}
    } catch { $response = [pscustomobject]@{Success=$false;Data=$null;Error=$_.Exception.Message} }
    if($workerPathsValidated){Write-BhoWorkerResponse -StateRoot $StateRoot -RequestPath $RequestPath -ResponsePath $ResponsePath -Response $response}
    if (-not $response.Success) { exit 1 }
    exit 0
}
if ($Action -eq 'Gui') {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Start the UI with Windows PowerShell -STA, Start-BHopsOptimizer.cmd, or the portable EXE.' }
    . (Join-Path $PSScriptRoot 'src\BHopsOptimizer.UI.ps1')
    Show-BhoWindow -Demo:$Demo -SmokeTest:$SmokeTest -ScreenshotPath $ScreenshotPath -PreviewPage $PreviewPage
    exit 0
}
if ($Options.Count -eq 1 -and $Options[0].Contains(',')) { $Options = $Options[0].Split(',') }
if ($Tweaks.Count -eq 1 -and $Tweaks[0].Contains(',')) { $Tweaks = $Tweaks[0].Split(',') }
$networkPreset = @('Prefer5GHz','LowRoaming','DisablePowerSaving')
$systemPreset = @('show-file-extensions')
$gamingPreset = @('enable-game-mode','disable-background-capture')
if (-not $Options) { $Options = if ($Preset -in @('Network','Gaming')) { $networkPreset } else { @() } }
if (-not $Tweaks) { $Tweaks = switch ($Preset) { 'System' {$systemPreset}; 'Minimal' {$systemPreset}; 'Gaming' {$gamingPreset}; default {@()} } }
$argsObject = [pscustomobject]@{AdapterId=$AdapterId;Options=$Options;Ids=$Tweaks;BackupPath=$BackupPath;OfferId=$OfferId;Samples=$Samples;DryRun=[bool]$WhatIfPreference}
switch ($Action) {
    'Inventory' { $output = Invoke-BhoOperation 'Inventory' $argsObject }
    'Diagnose' { $argsObject.AdapterId=Resolve-BhoAdapterId $AdapterId; $output=Invoke-BhoOperation 'Diagnostics' $argsObject }
    'Plan' {
        $network=@();$system=@()
        if ($Options.Count) { $argsObject.AdapterId=Resolve-BhoAdapterId $AdapterId; $network=@(Invoke-BhoOperation 'NetworkPlan' $argsObject) }
        if ($Tweaks.Count) { $system=@(Invoke-BhoOperation 'SystemPlan' $argsObject) }
        $output=[pscustomobject]@{Preset=$Preset;Network=$network;System=$system}
    }
    'Apply' {
        $network=$null;$system=$null
        if ($Options.Count) { $argsObject.AdapterId=Resolve-BhoAdapterId $AdapterId; $network=Invoke-BhoOperation 'NetworkApply' $argsObject; if ($network.Success -eq $false -and -not $WhatIfPreference) { throw $network.Message } }
        try { if ($Tweaks.Count) { $system=Invoke-BhoOperation 'SystemApply' $argsObject } }
        catch { $output=[pscustomobject]@{Success=$false;Network=$network;System=$null;Message=('System step failed: '+$_.Exception.Message);NetworkBackupPath=if($network){$network.BackupPath}else{$null}}; $output | ConvertTo-Json -Depth 15; exit 1 }
        $output=[pscustomobject]@{Success=($null -eq $network -or $network.Success -ne $false) -and ($null -eq $system -or $system.Success -ne $false);Network=$network;System=$system}
    }
    'Restore' { if (-not $BackupPath) { throw 'Specify -BackupPath from the backup list.' }; $output=Invoke-BhoOperation 'NetworkRestore' $argsObject }
    'SystemPlan' { $output=Invoke-BhoOperation 'SystemPlan' $argsObject }
    'SystemApply' { $output=Invoke-BhoOperation 'SystemApply' $argsObject }
    'SystemRestore' { if (-not $BackupPath) { throw 'Specify -BackupPath.' }; $output=Invoke-BhoOperation 'SystemRestore' $argsObject }
    'DriverCheck' { $argsObject.AdapterId=Resolve-BhoAdapterId $AdapterId; $output=Invoke-BhoOperation 'DriverCheck' $argsObject }
    'DriverInstall' { $argsObject.AdapterId=Resolve-BhoAdapterId $AdapterId; if (-not $OfferId) { throw 'Specify an OfferId returned by DriverCheck.' }; $output=Invoke-BhoOperation 'DriverInstall' $argsObject }
}
$output | ConvertTo-Json -Depth 20
if ($output.Success -eq $false -and -not $WhatIfPreference) { exit 1 }
