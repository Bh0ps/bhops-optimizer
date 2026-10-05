#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\BHopsOptimizer.Presentation.psm1'
Import-Module $modulePath -Force
$script:passed = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) { throw ('Assertion failed: ' + $Message + '. Expected "' + $Expected + '", got "' + $Actual + '".') }
    $script:passed++
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
    $script:passed++
}
function New-TestPlan {
    param([string]$Id, $Before, $After, [string]$Kind = '', [string]$Keyword = '', [bool]$Supported = $true, [bool]$Changed = $true, [string]$Reason = '', [string]$Label = 'Original title')
    [pscustomobject]@{ Id = $Id; Label = $Label; Kind = $Kind; Keyword = $Keyword; Before = $Before; After = $After; Supported = $Supported; Changed = $Changed; Reason = $Reason }
}

try {
    # Every case supplies data. No backend module, network, registry or power
    # API is imported or called, even when this script runs as administrator.
    $driverProperty = [pscustomobject]@{
        RegistryKeyword = 'PreferredBand'; RegistryValue = @('1')
        DisplayName = 'Preferred Band'; DisplayValue = '1. No Preference'
        ValidRegistryValues = @('1', '2', '3')
        ValidDisplayValues = @('1. No Preference', '2. Prefer 2.4GHz', '3. Prefer 5GHz')
    }
    $snapshot = [pscustomobject]@{ Properties = @($driverProperty) }
    $networkPlan = New-TestPlan 'Prefer5GHz.Advanced' @('1') @('3') 'Advanced' 'PreferredBand' -Reason 'Driver capability mapping.'
    $originalPlan = ConvertTo-Json -InputObject $networkPlan -Depth 8
    $originalSnapshot = ConvertTo-Json -InputObject $snapshot -Depth 8
    $row = @(ConvertTo-BhoPreviewRows -Plan @($networkPlan) -Snapshot $snapshot)[0]
    Assert-Equal $row.Title 'Preferred Wi-Fi band' 'Network titles describe the setting'
    Assert-Equal $row.Current 'No Preference' 'Current driver numeric values use paired display labels'
    Assert-Equal $row.Proposed 'Prefer 5GHz' 'Proposed values use the exact driver wording without menu prefixes'
    Assert-Equal $row.Status 'Will change' 'Supported changes are explicit'
    Assert-Equal $row.StatusKey 'change' 'Change status matches the row template key'
    Assert-True ($row.Supported -and $row.Changed) 'Supported and changed flags survive formatting'
    Assert-True ($row.TechnicalDetail -match 'PreferredBand' -and $row.TechnicalDetail -match 'Stored proposed value: 3') 'Raw keyword and value remain available separately'
    Assert-Equal $row.RawBefore[0] '1' 'Raw current evidence is retained'
    Assert-Equal $row.Reason 'Driver capability mapping.' 'Original reasons are retained'
    Assert-True ($row.Tooltip -match 'Driver capability mapping') 'Tooltips include the original reason'
    Assert-Equal (ConvertTo-Json -InputObject $networkPlan -Depth 8) $originalPlan 'The formatter does not change the plan'
    Assert-Equal (ConvertTo-Json -InputObject $snapshot -Depth 8) $originalSnapshot 'The formatter does not change the snapshot'

    # Match the read-only NetworkPreview worker response and its JSON boundary.
    # A single plan entry must survive as an array with its paired labels intact.
    $response = [pscustomobject]@{ Success = $true; Data = [pscustomobject]@{ Snapshot = $snapshot; Plan = @($networkPlan) }; Error = $null }
    $decoded = ConvertTo-Json -InputObject $response -Depth 20 | ConvertFrom-Json
    $roundTripRows = @(ConvertTo-BhoPreviewRows -Plan @($decoded.Data.Plan) -Snapshot $decoded.Data.Snapshot)
    Assert-Equal $roundTripRows.Count 1 'A single worker preview entry produces one row'
    Assert-Equal $roundTripRows[0].Current 'No Preference' 'Current labels survive the worker JSON boundary'
    Assert-Equal $roundTripRows[0].Proposed 'Prefer 5GHz' 'Proposed labels survive the worker JSON boundary'
    Assert-Equal $roundTripRows[0].StatusKey 'change' 'Change status survives the worker JSON boundary'

    # Numerically identical driver values can mean different things. A generic
    # 0/1/2 guess would reverse this property's meaning.
    $powerProperty = [pscustomobject]@{
        RegistryKeyword = 'LowPowerEnable'; RegistryValue = @('1'); DisplayValue = 'Disabled'
        ValidRegistryValues = @('1', '0'); ValidDisplayValues = @('Disabled', 'Enabled')
    }
    $powerSnapshot = [pscustomobject]@{ Properties = @($powerProperty) }
    $row = @(ConvertTo-BhoPreviewRows @(New-TestPlan 'DisablePowerSaving.Advanced' @('1') @('0') 'Advanced' 'LowPowerEnable') -Snapshot $powerSnapshot)[0]
    Assert-Equal $row.Current 'Disabled' 'Advanced values are never guessed from 0 or 1'
    Assert-Equal $row.Proposed 'Enabled' 'The driver owns the meaning of its stored values'

    $driverProperty.RegistryValue = @('2'); $driverProperty.DisplayValue = 'Prefer 2.4GHz'
    $row = @(ConvertTo-BhoPreviewRows @($networkPlan) -Snapshot $snapshot)[0]
    Assert-Equal $row.Current 'No Preference' 'A changed snapshot cannot replace the plan current value'
    $driverProperty.ValidRegistryValues = @('1', '1', '3')
    $row = @(ConvertTo-BhoPreviewRows @($networkPlan) -Snapshot $snapshot)[0]
    Assert-Equal $row.Current 'Value 1' 'Ambiguous driver maps do not invent a label'
    Assert-Equal $row.Proposed 'Value 3' 'Malformed pairing falls back to readable exact values'
    $driverProperty.RegistryValue = @('1'); $driverProperty.DisplayValue = '1. No Preference'
    $row = @(ConvertTo-BhoPreviewRows @($networkPlan) -Snapshot $snapshot)[0]
    Assert-Equal $row.Current 'No Preference' 'Matching DisplayValue remains useful when capability pairs are unavailable'
    $driverProperty.ValidRegistryValues = @('1', '2', '3')
    $snapshot.Properties = @($driverProperty, $driverProperty)
    $row = @(ConvertTo-BhoPreviewRows @($networkPlan) -Snapshot $snapshot)[0]
    Assert-Equal $row.Current 'Value 1' 'Duplicate snapshot properties are not selected arbitrarily'
    $reasonPlan = New-TestPlan 'Prefer5GHz.Advanced' @('1') @('3') 'Advanced' 'PreferredBand' -Reason 'Resolved from the driver''s paired value and display-label capabilities: 3. Prefer 5GHz'
    $row = @(ConvertTo-BhoPreviewRows @($reasonPlan))[0]
    Assert-Equal $row.Current 'Value 1' 'No snapshot means the formatter does not assume current labels'
    Assert-Equal $row.Proposed 'Prefer 5GHz' 'The backend selected label can be used without a snapshot'

    $skipped = New-TestPlan 'LowRoaming.Advanced' @() @() 'Advanced' '' -Supported $false -Changed $true -Reason 'This vendor has no validated mapping; skipped.'
    $unchanged = New-TestPlan 'enable-game-mode' 'AutoGameModeEnabled=1 (DWord)' 'AutoGameModeEnabled=1 (DWord)' -Changed $false -Reason 'Already configured.'
    $rows = @(ConvertTo-BhoPreviewRows @($skipped, $unchanged))
    Assert-Equal $rows[0].Status 'Skipped' 'Skipped settings stay distinct from unchanged settings'
    Assert-Equal $rows[0].StatusKey 'skipped' 'Skipped status matches the row template key'
    Assert-Equal $rows[0].Current 'Unavailable' 'Missing capabilities have a clear current label'
    Assert-Equal $rows[0].Proposed 'No change' 'An unsupported setting never displays a promised change'
    Assert-True (-not $rows[0].Changed -and -not $rows[0].Supported) 'Unsupported plans cannot become changes'
    Assert-Equal $rows[0].Detail $skipped.Reason 'A skipped reason is visible in the row'
    Assert-Equal $rows[1].Status 'Already configured' 'Unchanged supported settings have their own label'
    Assert-Equal $rows[1].StatusKey 'unchanged' 'Unchanged status matches the row template key'
    Assert-Equal $rows[1].Current 'On' 'Game Mode current value is semantic'
    Assert-Equal $rows[1].Proposed 'On' 'Already configured settings retain the selected value'

    $rows = @(ConvertTo-BhoPreviewRows @(
        (New-TestPlan 'DisablePowerSaving.DevicePower' $true $false 'DevicePower' 'Enabled'),
        (New-TestPlan 'AcPerformance' 3 0 'AcPower' 'WirelessPowerSaveIndex')
    ))
    Assert-Equal $rows[0].Current 'On' 'Windows device power values are readable booleans'
    Assert-Equal $rows[0].Proposed 'Off' 'Preventing device power saving has an unambiguous target'
    Assert-Equal $rows[1].Current 'Maximum power saving' 'Wireless power indexes have friendly names'
    Assert-Equal $rows[1].Proposed 'Maximum performance' 'AC power changes show the actual selected mode'

    $rows = @(ConvertTo-BhoPreviewRows @(
        (New-TestPlan 'show-file-extensions' 'HideFileExt=1 (DWord)' 'HideFileExt=0 (DWord)'),
        (New-TestPlan 'disable-advertising-id' 'Enabled=1 (DWord)' 'Enabled=0 (DWord)'),
        (New-TestPlan 'disable-tailored-experiences' 'TailoredExperiencesWithDiagnosticDataEnabled=1 (DWord)' 'TailoredExperiencesWithDiagnosticDataEnabled=0 (DWord)'),
        (New-TestPlan 'disable-background-capture' 'HistoricalCaptureEnabled=1 (DWord)' 'HistoricalCaptureEnabled=0 (DWord)'),
        (New-TestPlan 'reduce-window-animations' 'MinAnimate=1 (String); TaskbarAnimations=1 (DWord)' 'MinAnimate=0 (String); TaskbarAnimations=0 (DWord)'),
        (New-TestPlan 'disable-mouse-acceleration' 'MouseSpeed=1 (String); MouseThreshold1=6 (String); MouseThreshold2=10 (String)' 'MouseSpeed=0 (String); MouseThreshold1=0 (String); MouseThreshold2=0 (String)'),
        (New-TestPlan 'high-performance-power' '381b4222-f694-41f0-9685-ff5bb260df2e' '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
    ))
    Assert-Equal $rows[0].Current 'Hidden' 'File extension polarity is translated correctly'
    Assert-Equal $rows[0].Proposed 'Shown' 'File extensions show the actual visible outcome'
    foreach ($index in 1..5) {
        Assert-Equal $rows[$index].Current 'On' ('Known Windows preference ' + $rows[$index].Id + ' current state')
        Assert-Equal $rows[$index].Proposed 'Off' ('Known Windows preference ' + $rows[$index].Id + ' target state')
    }
    Assert-Equal $rows[6].Current 'Balanced' 'Standard active power GUIDs are named'
    Assert-Equal $rows[6].Proposed 'High performance' 'High performance GUID is named'
    foreach ($item in $rows) {
        Assert-True (($item.Current + $item.Proposed) -notmatch '\(DWord\)|\(String\)|=|HKCU:|\[|\]') ('The primary values contain no registry or JSON syntax: ' + $item.Id)
    }

    $rows = @(ConvertTo-BhoPreviewRows @(
        (New-TestPlan 'show-file-extensions' 'HideFileExt=<missing>' 'HideFileExt=0 (DWord)'),
        (New-TestPlan 'show-file-extensions' 'HideFileExt=0 (String)' 'HideFileExt=0 (DWord)'),
        (New-TestPlan 'enable-game-mode' 'AutoGameModeEnabled=27 (DWord)' 'AutoGameModeEnabled=1 (DWord)'),
        (New-TestPlan 'reduce-window-animations' 'MinAnimate=1 (String); TaskbarAnimations=0 (DWord)' 'MinAnimate=0 (String); TaskbarAnimations=0 (DWord)'),
        (New-TestPlan 'disable-mouse-acceleration' 'MouseSpeed=0 (String); MouseThreshold1=6 (String); MouseThreshold2=10 (String)' 'MouseSpeed=0 (String); MouseThreshold1=0 (String); MouseThreshold2=0 (String)'),
        (New-TestPlan 'high-performance-power' '11111111-2222-3333-4444-555555555555' '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'),
        (New-TestPlan 'show-file-extensions' '' '' -Supported $false -Changed $false -Reason 'Requires Windows 10 or Windows 11.')
    ))
    Assert-Equal $rows[0].Current 'Not set' 'An absent registry preference is not a guessed Windows default'
    Assert-Equal $rows[1].Current 'Custom value' 'Unexpected existing datatypes are not portrayed as already correct'
    Assert-Equal $rows[1].Proposed 'Shown' 'A replacement retains its semantic target'
    Assert-True ($rows[1].TechnicalDetail -match 'HideFileExt=0 \(String\)') 'Original datatype evidence is kept separately'
    Assert-Equal $rows[2].Current 'Custom value' 'Unknown values are not incorrectly called On or Off'
    Assert-Equal $rows[3].Current 'Windows: On; taskbar: Off' 'Mixed animation preferences remain accurate'
    Assert-Equal $rows[4].Current 'Off (custom thresholds)' 'Threshold reset changes remain visible when acceleration is already off'
    Assert-Equal $rows[5].Current 'Custom power plan' 'Unknown power GUIDs do not receive a guessed standard name'
    Assert-True ($rows[5].TechnicalDetail -match '11111111-2222-3333-4444-555555555555') 'The exact custom power GUID is retained'
    Assert-Equal $rows[6].Current 'Unavailable' 'An unsupported OS has no invented current state'
    Assert-Equal $rows[6].Proposed 'No change' 'An unsupported Windows preference will be skipped'

    $opaque = [pscustomobject]@{ Name = 'device data'; Nested = [pscustomobject]@{ Value = 12 } }
    $rows = @(ConvertTo-BhoPreviewRows @(
        (New-TestPlan 'future-option' @('Manual', 'Automatic') @('Automatic') -Label 'Future setting'),
        (New-TestPlan 'future-complex' $opaque $opaque -Label 'Complex setting'),
        (New-TestPlan 'future-registry' 'NewFlag=9 (DWord)' 'NewFlag=0 (DWord)' -Label 'Another setting')
    ))
    Assert-Equal $rows[0].Title 'Future setting' 'Unknown IDs retain the backend title'
    Assert-Equal $rows[0].Current 'Manual, Automatic' 'Unknown arrays are readable without JSON escapes'
    Assert-Equal $rows[1].Current 'Custom value' 'Complex values do not leak raw JSON into cells'
    Assert-True ([object]::ReferenceEquals($rows[1].RawBefore, $opaque)) 'Original complex evidence stays available'
    Assert-True ($rows[1].TechnicalDetail -match 'Nested') 'Complex evidence appears in technical details'
    Assert-Equal $rows[2].Current 'Custom value' 'Future registry syntax stays in technical details'
    Assert-True ($rows[2].TechnicalDetail -match 'NewFlag=9') 'Future registry values remain exact in technical details'
    Assert-Equal @(ConvertTo-BhoPreviewRows -Plan @()).Count 0 'Empty plans produce no placeholder changes'
    Assert-Equal @(@($unchanged, $skipped) | ConvertTo-BhoPreviewRows).Count 2 'Pipeline input preserves row count'
    Assert-Equal (Get-BhoOperationDisplayName 'Inventory') 'Device check' 'Inventory keys receive a friendly footer name'
    Assert-Equal (Get-BhoOperationDisplayName 'DriverCheck') 'Driver check' 'Driver operation names are friendly'
    Assert-Equal (Get-BhoOperationDisplayName 'NetworkPlan') 'Network preview' 'Preview operation names are friendly'
    Assert-Equal (Get-BhoOperationDisplayName 'NetworkPreview') 'Network preview' 'Snapshot-backed worker preview names are friendly'
    Assert-Equal (Get-BhoOperationDisplayName 'FutureOperation') 'Future Operation' 'Unknown operation keys remain recognizable'

    Write-Output ('Presentation tests passed: ' + $script:passed + ' assertions; all inputs were fake data, with no OS reads or writes.')
}
finally { Remove-Module BHopsOptimizer.Presentation -Force -ErrorAction SilentlyContinue }
