#requires -Version 5.1
Set-StrictMode -Version 2.0

# This module only transforms supplied data. It never queries or changes Windows.
$script:PreviewDefinitions = @{
    'Prefer5GHz.Advanced' = @('Preferred Wi-Fi band', 'Prefer 5 GHz when it is available.')
    'LowRoaming.Advanced' = @('Roaming aggressiveness', 'Use the driver''s lowest roaming aggressiveness.')
    'DisablePowerSaving.Advanced' = @('Adapter power saving', 'Turn off power saving in the Wi-Fi driver.')
    'DisablePowerSaving.DevicePower' = @('Windows adapter power saving', 'Prevent Windows from turning off the adapter to save power.')
    'MaximumTransmitPower.Advanced' = @('Transmit power', 'Use the driver''s highest available transmit power.')
    'DisableUapsd.Advanced' = @('U-APSD power saving', 'Turn off U-APSD power saving in the Wi-Fi driver.')
    'AcPerformance' = @('Wi-Fi power while plugged in', 'Use maximum performance while plugged in; battery settings stay the same.')
    'show-file-extensions' = @('File name extensions', 'Show file extensions in File Explorer.')
    'reduce-window-animations' = @('Window and taskbar animations', 'Turn off window and taskbar animations.')
    'disable-advertising-id' = @('App advertising ID', 'Turn off this Windows user''s advertising ID.')
    'disable-tailored-experiences' = @('Personalized tips and recommendations', 'Turn off personalization based on diagnostic data.')
    'enable-game-mode' = @('Windows Game Mode', 'Turn on Windows Game Mode for this user.')
    'disable-background-capture' = @('Background game recording', 'Turn off retrospective game clips; manual recording stays available.')
    'disable-mouse-acceleration' = @('Desktop mouse acceleration', 'Turn off Enhance pointer precision and reset its thresholds.')
    'high-performance-power' = @('Active power plan', 'Switch to the existing High performance power plan.')
}

function Get-BhoPreviewField {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $field = $Object.PSObject.Properties[$Name]
    if ($null -eq $field) { return $Default }
    return $field.Value
}

function ConvertTo-BhoPlainValue {
    param($Value, [string]$EmptyLabel = 'Not set')
    if ($null -eq $Value) { return $EmptyLabel }
    if ($Value -is [bool]) { if ($Value) { return 'On' }; return 'Off' }
    if ($Value -is [array]) {
        if ($Value.Count -eq 0) { return $EmptyLabel }
        return (@($Value | ForEach-Object { ConvertTo-BhoPlainValue $_ $EmptyLabel }) -join ', ')
    }
    if ($Value -is [string] -or $Value -is [ValueType]) {
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text) -or $text -eq '<missing>') { return $EmptyLabel }
        # Registry preview syntax belongs in technical details, never in a cell.
        if ($text -match '^(?i)HK(?:CU|LM):|(?:^|;\s*)[\w*]+=[^;]*(?:\((?:DWord|QWord|String|ExpandString|MultiString|Binary|None)\)|<missing>)') { return 'Custom value' }
        if ($text -match '^-?\d+(?:\.\d+)?$') { return ('Value ' + $text) }
        return $text
    }
    return 'Custom value'
}

function ConvertTo-BhoDriverLabel {
    param([string]$Label)
    # Some drivers number their choices, e.g. "3. Prefer 5GHz". The number is
    # a menu prefix, not a second setting value. Preserve the driver's words.
    return ($Label.Trim() -replace '^\d+\s*[\.\)\:\-]\s*', '')
}

function Test-BhoPreviewValuesEqual {
    param($Left, $Right)
    $leftValues = @($Left); $rightValues = @($Right)
    if ($leftValues.Count -ne $rightValues.Count) { return $false }
    for ($i = 0; $i -lt $leftValues.Count; $i++) {
        if ([string]$leftValues[$i] -cne [string]$rightValues[$i]) { return $false }
    }
    return $true
}

function ConvertTo-BhoAdvancedValue {
    param($Value, $Property, [bool]$IsCurrent, [string]$Reason)
    $items = @($Value)
    if ($null -eq $Value -or $items.Count -eq 0) { return 'Unavailable' }
    $values = @(Get-BhoPreviewField $Property 'ValidRegistryValues' @())
    $labels = @(Get-BhoPreviewField $Property 'ValidDisplayValues' @())
    $validMap = $values.Count -gt 0 -and $values.Count -eq $labels.Count
    if ($validMap) {
        $seen = @{}
        for ($i = 0; $i -lt $values.Count; $i++) {
            $key = [string]$values[$i]
            if ($seen.ContainsKey($key) -or [string]::IsNullOrWhiteSpace((ConvertTo-BhoDriverLabel ([string]$labels[$i])))) { $validMap = $false; break }
            $seen[$key] = $true
        }
    }
    if ($validMap) {
        $result = @()
        foreach ($item in $items) {
            $matches = @()
            for ($i = 0; $i -lt $values.Count; $i++) { if ([string]$values[$i] -ceq [string]$item) { $matches += $i } }
            if ($matches.Count -ne 1) { $validMap = $false; break }
            $result += ConvertTo-BhoDriverLabel ([string]$labels[$matches[0]])
        }
        if ($validMap) { return ($result -join ', ') }
    }
    # DisplayValue is trustworthy for the current value only when this property
    # still describes the value captured by the plan. Never reuse it for After.
    if ($IsCurrent -and $null -ne $Property -and (Test-BhoPreviewValuesEqual $Value (Get-BhoPreviewField $Property 'RegistryValue' @()))) {
        $display = [string](Get-BhoPreviewField $Property 'DisplayValue' '')
        if (-not [string]::IsNullOrWhiteSpace($display)) { return (ConvertTo-BhoDriverLabel $display) }
    }
    # Get-BhoTuningPlan records the selected driver label in its reason. This
    # provides an accurate proposed label when a snapshot was not supplied.
    if (-not $IsCurrent -and $Reason -match '^Resolved from the driver''s paired value and display-label capabilities: (.+)$') {
        return (ConvertTo-BhoDriverLabel $Matches[1])
    }
    return (ConvertTo-BhoPlainValue $Value 'Unavailable')
}

function Get-BhoRegistryPreviewParts {
    param($Value)
    $parts = @{}
    if ($Value -isnot [string]) { return $parts }
    foreach ($token in ([string]$Value -split ';\s*')) {
        if ($token -notmatch '^([A-Za-z0-9_]+)=(.*)$') { continue }
        $name = $Matches[1]; $data = $Matches[2]
        if ($parts.ContainsKey($name)) { return @{} }
        $type = ''; $missing = $data -eq '<missing>'
        if ($data -match '^(.*) \((DWord|QWord|String|ExpandString|MultiString|Binary|None)\)$') {
            $data = $Matches[1]; $type = $Matches[2]
        }
        $parts[$name] = [pscustomobject]@{ Value = $data; Type = $type; Missing = $missing }
    }
    return $parts
}

function ConvertTo-BhoPreferenceState {
    param($Parts, [string]$Name, [string]$ExpectedType, [string]$ZeroLabel = 'Off', [string]$OneLabel = 'On')
    if (-not $Parts.ContainsKey($Name)) { return 'Unavailable' }
    $part = $Parts[$Name]
    if ($part.Missing) { return 'Not set' }
    if ($part.Type -cne $ExpectedType) { return 'Custom value' }
    if ($part.Value -ceq '0') { return $ZeroLabel }
    if ($part.Value -ceq '1') { return $OneLabel }
    return 'Custom value'
}

function ConvertTo-BhoPowerPlanName {
    param($Value)
    $text = ([string]$Value).Trim().Trim([char[]]'{}').ToLowerInvariant()
    switch ($text) {
        '' { return 'Unavailable' }
        '381b4222-f694-41f0-9685-ff5bb260df2e' { return 'Balanced' }
        '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' { return 'High performance' }
        'a1841308-3541-4fab-bc81-f71556f20b4a' { return 'Power saver' }
        'e9a42b02-d5df-448d-aa00-03f14749eb61' { return 'Ultimate performance' }
        default {
            if ($text -match '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$') { return 'Custom power plan' }
            return (ConvertTo-BhoPlainValue $Value 'Unavailable')
        }
    }
}

function ConvertTo-BhoSystemValue {
    param([string]$Id, $Value)
    if ($Id -eq 'high-performance-power') { return (ConvertTo-BhoPowerPlanName $Value) }
    $parts = Get-BhoRegistryPreviewParts $Value
    switch ($Id) {
        'show-file-extensions' { return (ConvertTo-BhoPreferenceState $parts 'HideFileExt' 'DWord' 'Shown' 'Hidden') }
        'disable-advertising-id' { return (ConvertTo-BhoPreferenceState $parts 'Enabled' 'DWord') }
        'disable-tailored-experiences' { return (ConvertTo-BhoPreferenceState $parts 'TailoredExperiencesWithDiagnosticDataEnabled' 'DWord') }
        'enable-game-mode' { return (ConvertTo-BhoPreferenceState $parts 'AutoGameModeEnabled' 'DWord') }
        'disable-background-capture' { return (ConvertTo-BhoPreferenceState $parts 'HistoricalCaptureEnabled' 'DWord') }
        'reduce-window-animations' {
            $window = ConvertTo-BhoPreferenceState $parts 'MinAnimate' 'String'
            $taskbar = ConvertTo-BhoPreferenceState $parts 'TaskbarAnimations' 'DWord'
            if ($window -ceq $taskbar) { return $window }
            return ('Windows: ' + $window + '; taskbar: ' + $taskbar)
        }
        'disable-mouse-acceleration' {
            $speed = ConvertTo-BhoPreferenceState $parts 'MouseSpeed' 'String'
            if ($parts.ContainsKey('MouseSpeed') -and $parts['MouseSpeed'].Type -ceq 'String' -and $parts['MouseSpeed'].Value -ceq '2') { $speed = 'On' }
            if ($speed -eq 'Off') {
                $threshold1 = ConvertTo-BhoPreferenceState $parts 'MouseThreshold1' 'String'
                $threshold2 = ConvertTo-BhoPreferenceState $parts 'MouseThreshold2' 'String'
                if ($threshold1 -ne 'Off' -or $threshold2 -ne 'Off') { return 'Off (custom thresholds)' }
            }
            return $speed
        }
        default { return (ConvertTo-BhoPlainValue $Value 'Unavailable') }
    }
}

function ConvertTo-BhoTechnicalValue {
    param($Value)
    if ($null -eq $Value) { return '<not available>' }
    if ($Value -is [array]) { if ($Value.Count -eq 0) { return '<empty>' }; return ($Value -join ', ') }
    if ($Value -is [string] -or $Value -is [ValueType]) { return [string]$Value }
    return (ConvertTo-Json -InputObject $Value -Compress -Depth 15)
}

function ConvertTo-BhoPreviewRows {
    <#
    .SYNOPSIS
    Converts network or System/Gaming plans into read-only UI row models.
    .DESCRIPTION
    Accepts Get-BhoTuningPlan or Get-BhoSystemPlan output. Snapshot is optional
    and supplies the driver's actual value-label pairs for network properties.
    RawBefore, RawAfter and TechnicalDetail preserve evidence separately from
    the readable cells. The input plan and snapshot are never modified.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)][AllowEmptyCollection()][object[]]$Plan,
        $Snapshot = $null
    )
    process {
        foreach ($entry in $Plan) {
            if ($null -eq $entry) { continue }
            $id = [string](Get-BhoPreviewField $entry 'Id' '')
            $kind = [string](Get-BhoPreviewField $entry 'Kind' '')
            $keyword = [string](Get-BhoPreviewField $entry 'Keyword' '')
            $reason = [string](Get-BhoPreviewField $entry 'Reason' '')
            $before = Get-BhoPreviewField $entry 'Before'
            $after = Get-BhoPreviewField $entry 'After'
            $supported = [bool](Get-BhoPreviewField $entry 'Supported' $false)
            $changed = $supported -and [bool](Get-BhoPreviewField $entry 'Changed' $false)
            $title = [string](Get-BhoPreviewField $entry 'Label' $id)
            $detail = $reason
            if ($script:PreviewDefinitions.ContainsKey($id)) {
                $title = $script:PreviewDefinitions[$id][0]
                $detail = $script:PreviewDefinitions[$id][1]
            }
            if ([string]::IsNullOrWhiteSpace($title)) { $title = 'Setting' }
            $property = $null
            if ($kind -eq 'Advanced' -or $id -like '*.Advanced') {
                if ($keyword) {
                    $properties = @((Get-BhoPreviewField $Snapshot 'Properties' @()) | Where-Object { ([string](Get-BhoPreviewField $_ 'RegistryKeyword' '')) -ieq $keyword })
                    if ($properties.Count -eq 1) { $property = $properties[0] }
                }
                $current = ConvertTo-BhoAdvancedValue $before $property $true $reason
                $proposed = ConvertTo-BhoAdvancedValue $after $property $false $reason
            }
            elseif ($kind -eq 'DevicePower' -or $id -like '*.DevicePower') {
                $current = ConvertTo-BhoPlainValue $before 'Unavailable'
                $proposed = ConvertTo-BhoPlainValue $after 'Unavailable'
            }
            elseif ($kind -eq 'AcPower' -or $id -eq 'AcPerformance') {
                $powerNames = @{ '0' = 'Maximum performance'; '1' = 'Low power saving'; '2' = 'Medium power saving'; '3' = 'Maximum power saving' }
                $current = ConvertTo-BhoPlainValue $before 'Unavailable'
                $proposed = ConvertTo-BhoPlainValue $after 'Unavailable'
                if ($null -ne $before -and $powerNames.ContainsKey([string]$before)) { $current = $powerNames[[string]$before] }
                if ($null -ne $after -and $powerNames.ContainsKey([string]$after)) { $proposed = $powerNames[[string]$after] }
            }
            else {
                $current = ConvertTo-BhoSystemValue $id $before
                $proposed = ConvertTo-BhoSystemValue $id $after
            }
            if (-not $supported) {
                $status = 'Skipped'; $statusKey = 'skipped'; $proposed = 'No change'
                $detail = if ($reason) { $reason } else { 'This setting is unavailable on this PC.' }
            }
            elseif (-not $changed) {
                $status = 'Already configured'; $statusKey = 'unchanged'
                $detail = 'This setting already matches the selected value.'
            }
            else { $status = 'Will change'; $statusKey = 'change' }
            $tooltip = $detail
            if ($reason -and $reason -cne $detail) { $tooltip += [Environment]::NewLine + $reason }
            $technical = @('Setting ID: ' + $id)
            if ($kind) { $technical += ('Kind: ' + $kind) }
            if ($keyword) { $technical += ('Driver property: ' + $keyword) }
            $displayName = [string](Get-BhoPreviewField $property 'DisplayName' '')
            if ($displayName) { $technical += ('Driver label: ' + $displayName) }
            $technical += ('Stored current value: ' + (ConvertTo-BhoTechnicalValue $before))
            $technical += ('Stored proposed value: ' + (ConvertTo-BhoTechnicalValue $after))
            if ($reason) { $technical += ('Reason: ' + $reason) }
            [pscustomobject]@{
                Id = $id; Title = $title; Current = $current; Proposed = $proposed
                Status = $status; StatusKey = $statusKey; Changed = $changed; Supported = $supported
                Detail = $detail; Reason = $reason; Tooltip = $tooltip
                TechnicalDetail = $technical -join [Environment]::NewLine
                RawBefore = $before; RawAfter = $after
            }
        }
    }
}

function Get-BhoOperationDisplayName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Operation)
    switch ($Operation) {
        'Inventory' { return 'Device check' }
        'Adapters' { return 'Device check' }
        'Snapshot' { return 'Adapter check' }
        'NetworkPlan' { return 'Network preview' }
        'NetworkPreview' { return 'Network preview' }
        'NetworkApply' { return 'Network changes' }
        'SystemPlan' { return 'Settings preview' }
        'SystemApply' { return 'Settings changes' }
        'Diagnostics' { return 'Latency test' }
        'DriverCheck' { return 'Driver check' }
        'DriverSearch' { return 'Driver check' }
        'DriverInstall' { return 'Driver installation' }
        'Backups' { return 'Backup check' }
        'NetworkRestore' { return 'Network restore' }
        'SystemRestore' { return 'Settings restore' }
        default { return ($Operation -creplace '(?<=[a-z])(?=[A-Z])', ' ') }
    }
}

Export-ModuleMember -Function ConvertTo-BhoPreviewRows, Get-BhoOperationDisplayName
