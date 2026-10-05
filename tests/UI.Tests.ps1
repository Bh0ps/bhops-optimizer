#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src\BHopsOptimizer.Presentation.psm1') -Force
# Dot-sourcing only defines functions. Show-BhoWindow is never called, so this
# suite does not load WPF, create a window or use UI Automation.
. (Join-Path $repoRoot 'src\BHopsOptimizer.UI.ps1')
$script:passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
    $script:passed++
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) { throw ('Assertion failed: ' + $Message + '. Expected "' + $Expected + '", got "' + $Actual + '".') }
    $script:passed++
}
function New-FakeControl {
    $control = [pscustomobject]@{ Text=''; ToolTip=$null; ItemsSource=@(); SelectedItem=$null; IsEnabled=$true; Visibility='Visible'; Log=''; ScrollCount=0 }
    $control | Add-Member -MemberType ScriptMethod -Name AppendText -Value { param($text) $this.Log += $text }
    $control | Add-Member -MemberType ScriptMethod -Name ScrollToEnd -Value { $this.ScrollCount++ }
    return $control
}
function Reset-FakeUi {
    $script:Ui = @{ Controls=@{}; Busy=$false; Demo=$false; NetworkChecks=@(); SystemChecks=@(); Job=$null; RefreshRequested=$false; PreviewSelections=@{}; Page='Overview' }
    foreach ($name in @('ActivityText','OperationStatus','BusyProgress','NetworkApply','NetworkPreview','SystemApply','SystemPreview','GamingApply','GamingPreview','RunDiagnostics','CheckDrivers','RefreshBackups','NetworkRecommended','AdapterSelector','InstallDriver','RestoreBackup','DriverGrid','BackupGrid','DriverStatus','DriverEmpty','LatencyGrid','DiagnosticSummary','DiagnosticContext','ExportDiagnostics','OverviewLatencyCaption','OverviewLatency','OverviewLoss','OverviewTestNote','NetworkPlanRows','NetworkPlanSummary','NetworkPlanCard')) {
        $script:Ui.Controls[$name] = New-FakeControl
    }
    $script:ResponseExists=$true; $script:ResponseJson=''; $script:CallbackCount=0
}
function Set-FakeCompletedJob {
    param([string]$Operation, $Data)
    $process = [pscustomobject]@{ HasExited=$true; Disposed=$false }
    $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Disposed=$true }
    $script:ResponseJson = ConvertTo-Json -InputObject ([pscustomobject]@{Success=$true;Data=$Data;Error=$null}) -Depth 20
    $script:Ui.Busy=$true
    $script:Ui.Job=[pscustomobject]@{ Process=$process; ResponsePath='mock:\job.response.json'; Operation=$Operation; StartedAt=[datetime]'2026-01-01T12:00:00'; Callback={param($result) $script:CallbackCount++; Show-BhoApplyResult $result} }
    return $process
}
function New-FakeDiagnosticResult {
    param($Received, $Sent, $Mean = 12.3, [double]$Loss = 0)
    [pscustomobject]@{DurationSeconds=1.5;ReceivedBytes=$Received;SentBytes=$Sent;Results=@([pscustomobject]@{Target='1.1.1.1';MeanMs=$Mean;LossPercent=$Loss})}
}

# Replace the completion path's file and clock boundaries. Reject unexpected
# filesystem or process operations rather than touching the test machine.
function Get-Content { param([string]$LiteralPath,[switch]$Raw) if($LiteralPath -cne 'mock:\job.response.json'){throw 'Unexpected file read.'}; return $script:ResponseJson }
function Test-Path { param([string]$LiteralPath) if($LiteralPath -cne 'mock:\job.response.json'){throw 'Unexpected filesystem query.'}; return $script:ResponseExists }
function Get-Date { param([string]$Format) $fixed=[datetime]'2026-01-01T12:00:01';if($Format){return $fixed.ToString($Format)};return $fixed }
function Start-Process { throw 'Real processes are forbidden in UI tests.' }
function New-Item { throw 'Filesystem mutations are forbidden in UI tests.' }
function Set-Content { throw 'Filesystem mutations are forbidden in UI tests.' }

try {
    Reset-FakeUi
    $unavailable=[pscustomobject]@{Title='Reviewed driver';Version='3.6.0.1434';Compatible=$false;Reason='Requires x64 Windows 11 build 22621 or later.'}
    Set-BhoDriverData ([pscustomobject]@{InstalledVersion='3.1.0.0';Offers=@($unavailable);Message='Reviewed offers are listed below.'})
    Assert-Equal (Get-BhoControl 'DriverStatus').Text 'No compatible update available' 'Unsupported platforms do not imply an update is unnecessary'
    Assert-Equal $unavailable.ShortStatus 'Unavailable' 'A newer incompatible offer remains unavailable'
    Assert-Equal $unavailable.Reason 'Requires x64 Windows 11 build 22621 or later.' 'The row retains the exact compatibility explanation'
    (Get-BhoControl 'DriverGrid').SelectedItem=$unavailable
    Set-BhoBusy $false
    Assert-True (-not (Get-BhoControl 'InstallDriver').IsEnabled) 'An incompatible offer cannot enable installation'
    $available=[pscustomobject]@{Title='Reviewed driver';Version='3.6.0.1434';Compatible=$true;Reason='Exact hardware ID matches.'}
    Set-BhoDriverData ([pscustomobject]@{InstalledVersion='3.1.0.0';Offers=@($available);Message='Reviewed offers are listed below.'})
    Assert-Equal (Get-BhoControl 'DriverStatus').Text 'Update available' 'Compatible updates remain clearly available'
    (Get-BhoControl 'DriverGrid').SelectedItem=$available
    Set-BhoBusy $false
    Assert-True (Get-BhoControl 'InstallDriver').IsEnabled 'A compatible selected offer can enable installation'
    Set-BhoDriverData ([pscustomobject]@{InstalledVersion='3.1.0.0';Offers=@();Message='No reviewed automatic update for this adapter.'})
    Assert-Equal (Get-BhoControl 'DriverStatus').Text 'No reviewed update' 'No offers has its own summary'
    Assert-Equal (Get-BhoControl 'DriverGrid').Visibility 'Collapsed' 'An empty offer list does not show an empty table'

    Reset-FakeUi
    Set-BhoDiagnostics (New-FakeDiagnosticResult $null $null)
    $summary=(Get-BhoControl 'DiagnosticContext').Text
    Assert-True ($summary -match 'Received traffic unavailable' -and $summary -match 'Sent traffic unavailable') 'Missing traffic counters remain unknown'
    Assert-True ($summary -notmatch '0 MB') 'Unknown traffic is never reported as zero'
    Set-BhoDiagnostics (New-FakeDiagnosticResult 0 $null)
    $summary=(Get-BhoControl 'DiagnosticContext').Text
    Assert-True ($summary -match '0 MB received' -and $summary -match 'Sent traffic unavailable') 'A real zero is distinct from an unavailable counter'
    Set-BhoDiagnostics (New-FakeDiagnosticResult 2097152 1048576)
    Assert-True ((Get-BhoControl 'DiagnosticContext').Text -match '2 MB received.*1 MB sent') 'Known traffic counters retain their units and values'
    Assert-Equal (Get-BhoControl 'OverviewLatencyCaption').Text 'Endpoint latency' 'Public probes are not labelled router latency'
    Set-BhoDiagnostics (New-FakeDiagnosticResult $null $null $null 100)
    Assert-Equal (Get-BhoControl 'OverviewLatency').Text 'No replies' 'An all-loss test does not show zero latency'
    Assert-Equal (Get-BhoControl 'OverviewLoss').Text '100%' 'All-loss results stay visible on the overview'

    Reset-FakeUi
    $plan=@(
        [pscustomobject]@{Id='Prefer5GHz.Advanced';Kind='Advanced';Before=@('1');After=@('3');Supported=$true;Changed=$true;Reason='Selected driver value.'},
        [pscustomobject]@{Id='DisablePowerSaving.DevicePower';Kind='DevicePower';Before=$false;After=$false;Supported=$true;Changed=$false;Reason='Already configured.'},
        [pscustomobject]@{Id='LowRoaming.Advanced';Kind='Advanced';Before=@();After=@();Supported=$false;Changed=$false;Reason='Unsupported driver setting.'}
    )
    Set-BhoPreview 'Network' $plan
    $summary=(Get-BhoControl 'NetworkPlanSummary').Text
    Assert-True ($summary -match '^1 change' -and $summary -match '1 already configured' -and $summary -match '1 unavailable') 'The preview summary counts changes, configured settings and skipped settings separately'
    Assert-Equal @((Get-BhoControl 'NetworkPlanRows').ItemsSource).Count 3 'The visible preview retains all rows behind its summary'
    Assert-Equal (Get-BhoControl 'NetworkPlanCard').Visibility 'Visible' 'A preview opens its summary card'

    Reset-FakeUi
    $process=Set-FakeCompletedJob 'DriverInstall' ([pscustomobject]@{Success=$true;Message='Driver installed.';BackupPath='mock:\driver-backup';RebootRequired=$true})
    Complete-BhoUiJob
    Assert-True ((Get-BhoControl 'OperationStatus').Text -match 'restart') 'A required restart survives the generic completion log'
    Assert-True ((Get-BhoControl 'ActivityText').Log -match 'Driver installation complete\.') 'Generic completion remains available in Activity'
    Assert-True ((Get-BhoControl 'ActivityText').Log -match 'mock:\\driver-backup') 'The recovery path stays available in Activity'
    Assert-True ($script:Ui.RefreshRequested -and -not $script:Ui.Busy) 'Successful application requests refreshed inventory and clears busy state'
    Assert-True ($null -eq $script:Ui.Job -and $process.Disposed) 'Completion clears the job and disposes its process handle'
    Assert-Equal $script:CallbackCount 1 'A successful response invokes its completion callback once'

    Reset-FakeUi
    $process=Set-FakeCompletedJob 'NetworkApply' ([pscustomobject]@{Success=$true;Message='No changes are needed.';BackupPath=$null;RebootRequired=$false})
    Complete-BhoUiJob
    Assert-Equal (Get-BhoControl 'OperationStatus').Text 'No changes are needed.' 'No-op application retains the backend outcome in the footer'
    Assert-True $process.Disposed 'No-op completion still disposes its process handle'

    Reset-FakeUi
    $process=Set-FakeCompletedJob 'NetworkApply' ([pscustomobject]@{Success=$false;Message='The failed change was rolled back.';BackupPath='mock:\recovery-backup';RebootRequired=$false})
    Complete-BhoUiJob
    Assert-Equal $script:CallbackCount 0 'A failed backend operation never enters the success callback'
    Assert-True ((Get-BhoControl 'OperationStatus').Text -match 'ERROR:.*rolled back') 'A backend failure cannot be displayed as successful completion'
    Assert-True ((Get-BhoControl 'ActivityText').Log -match 'Recovery backup: mock:\\recovery-backup') 'Failed operations retain their recovery backup path'
    Assert-True ($process.Disposed -and -not $script:Ui.Busy) 'Failure also disposes the process and clears busy state'

    Write-Output ('UI tests passed: ' + $script:passed + ' assertions; controls, responses and OS boundaries were fake. No windows or system settings were touched.')
}
finally { Remove-Module BHopsOptimizer.Presentation -Force -ErrorAction SilentlyContinue }
