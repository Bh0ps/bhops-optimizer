#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\BHopsOptimizer.System.psm1'
Import-Module $modulePath -Force
$module = Get-Module BHopsOptimizer.System
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('bhops-system-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$script:passed = 0

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw ('Assertion failed: ' + $Message) }
    $script:passed++
}

# Replace every OS mutation boundary in the module scope. The test suite cannot
# change the real registry or power configuration, even when run as admin.
& $module {
    $script:fakeValues = @{}; $script:writes = 0; $script:undoWrites = 0
    $script:failOnceName = $null; $script:failUndoOnceName = $null; $script:fakeAdmin = $true; $script:unsafeFilesystemPaths = @()
    $script:fakeSid = 'S-1-5-21-111-222-333-1001'
    $script:activeGuid = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $script:powerGuids = @($script:activeGuid, '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
    function script:Test-BhoSystemWindowsSupport { $true }
    function script:Test-BhoSystemAdministrator { $script:fakeAdmin }
    function script:Get-BhoSystemIdentity { [pscustomobject]@{ ComputerName = 'TEST-PC'; UserSid = $script:fakeSid } }
    function script:Get-BhoSystemPathAttributes {
        param([string] $Path)
        if ($script:unsafeFilesystemPaths -contains $Path) { return [IO.FileAttributes]::ReparsePoint }
        [IO.File]::GetAttributes($Path)
    }
    function script:Read-BhoSystemRegistryValue {
        param([string] $Path, [string] $Name)
        $lookup = $Path + '|' + $Name
        if ($script:fakeValues.ContainsKey($lookup)) { return $script:fakeValues[$lookup] }
        [pscustomobject]@{ KeyExisted = $false; Existed = $false; Type = $null; Value = $null }
    }
    function script:Write-BhoSystemRegistryValue {
        param([string] $Path, [string] $Name, [string] $Type, $Value)
        $script:writes++
        $script:fakeValues[$Path + '|' + $Name] = [pscustomobject]@{ KeyExisted = $true; Existed = $true; Type = $Type; Value = $Value }
        if ($script:failOnceName -eq $Name) { $script:failOnceName = $null; throw 'Injected write-then-error failure.' }
    }
    function script:Undo-BhoSystemRegistryValue {
        param($Operation)
        $script:undoWrites++
        if ($Operation.Before.Existed) { $script:fakeValues[$Operation.Path + '|' + $Operation.Name] = $Operation.Before }
        else { $script:fakeValues.Remove($Operation.Path + '|' + $Operation.Name) }
        if ($script:failUndoOnceName -eq $Operation.Name) { $script:failUndoOnceName = $null; throw 'Injected Undo failure.' }
    }
    function script:Get-BhoSystemPowerState { [pscustomobject]@{ ActiveGuid = $script:activeGuid; AvailableGuids = $script:powerGuids } }
    function script:Set-BhoSystemPowerScheme {
        param([string] $Guid)
        if ($script:powerGuids -notcontains $Guid) { throw 'Missing mock power plan.' }
        $script:writes++; $script:activeGuid = $Guid
    }
}

try {
    $catalogue = @(Get-BhoSystemTweaks)
    Assert-True ($catalogue.Count -eq 8) 'Eight curated options are available.'
    Assert-True (@($catalogue | Where-Object { $_.Group -eq 'System' }).Count -eq 4) 'Four System options are separate from Gaming.'
    Assert-True (@($catalogue | Where-Object { $_.Group -eq 'Gaming' }).Count -eq 4) 'Four Gaming options are available.'
    Assert-True (-not ($catalogue | Where-Object Id -eq 'high-performance-power').Recommended) 'High performance is optional.'
    Assert-True (-not ($catalogue | Where-Object Id -eq 'disable-mouse-acceleration').Recommended) 'Mouse acceleration is optional.'
    $plan = @(Get-BhoSystemPlan -Ids @('show-file-extensions', 'enable-game-mode'))
    Assert-True ($plan.Count -eq 2 -and @($plan | Where-Object Changed).Count -eq 2) 'The preview detects absent values.'
    Assert-True ((& $module { $script:writes }) -eq 0) 'Preview does not mutate OS settings.'
    $preview = Invoke-BhoSystemApply -Ids @('show-file-extensions') -StateRoot $testRoot -WhatIf
    Assert-True ($preview.Success -and $null -eq $preview.BackupPath) 'WhatIf produces no backup.'
    Assert-True ((& $module { $script:writes }) -eq 0) 'WhatIf performs no mutations.'
    Assert-True (@(Get-ChildItem -LiteralPath $testRoot -Filter '*.json').Count -eq 0) 'WhatIf leaves the state folder untouched.'

    & $module {
        $script:fakeValues['HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|HideFileExt'] = [pscustomobject]@{ KeyExisted = $true; Existed = $true; Type = 'String'; Value = 'old typed value' }
    }
    $apply = Invoke-BhoSystemApply -Ids @('show-file-extensions', 'enable-game-mode') -StateRoot $testRoot -Confirm:$false
    Assert-True ($apply.Success -and $apply.ChangedCount -eq 2) 'Apply verifies two settings.'
    Assert-True (Test-Path -LiteralPath $apply.BackupPath -PathType Leaf) 'A pre-change snapshot exists.'
    $backupHash = (Get-FileHash -LiteralPath $apply.BackupPath -Algorithm SHA256).Hash
    $saved = Get-Content -LiteralPath $apply.BackupPath -Raw | ConvertFrom-Json
    Assert-True ($saved.Entries[0].Operations[0].Before.Type -eq 'String') 'The original registry type is saved.'
    Assert-True (-not $saved.Entries[1].Operations[0].Before.Existed) 'Absence is saved rather than a guessed default.'
    $inventory = @(Get-BhoSystemBackups -StateRoot $testRoot)
    Assert-True ($inventory.Count -eq 1 -and $inventory[0].Status -eq 'Applied' -and -not $inventory[0].RequiresAdmin) 'Backup inventory has state and elevation information.'
    $idempotent = Invoke-BhoSystemApply -Ids @('show-file-extensions', 'enable-game-mode') -StateRoot $testRoot -Confirm:$false
    Assert-True ($idempotent.Success -and $idempotent.ChangedCount -eq 0 -and $null -eq $idempotent.BackupPath) 'Reapplying a configured preset is a no-op.'
    $restored = Restore-BhoSystemBackup -Path $apply.BackupPath -StateRoot $testRoot -Confirm:$false
    Assert-True $restored.Success 'Undo succeeds.'
    Assert-True ((& $module { $script:fakeValues['HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|HideFileExt'].Type }) -eq 'String') 'Undo preserves the original datatype.'
    Assert-True ((& $module { $script:fakeValues['HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|HideFileExt'].Value }) -eq 'old typed value') 'Undo restores the original value.'
    Assert-True (-not (& $module { $script:fakeValues.ContainsKey('HKCU:\Software\Microsoft\GameBar|AutoGameModeEnabled') })) 'Undo removes an originally missing value.'
    Assert-True ((Get-FileHash -LiteralPath $apply.BackupPath -Algorithm SHA256).Hash -eq $backupHash) 'Undo never overwrites the immutable snapshot.'
    Assert-True ((Get-BhoSystemBackups -StateRoot $testRoot | Where-Object Path -eq $apply.BackupPath).Status -eq 'Restored') 'Status is recorded in a separate sidecar.'

    $retryApply = Invoke-BhoSystemApply -Ids @('show-file-extensions', 'enable-game-mode') -StateRoot $testRoot -Confirm:$false
    Assert-True $retryApply.Success 'The preset can be applied again after Undo.'
    & $module { $script:failUndoOnceName = 'AutoGameModeEnabled' }
    $failedUndo = Restore-BhoSystemBackup -Path $retryApply.BackupPath -StateRoot $testRoot -Confirm:$false
    Assert-True (-not $failedUndo.Success -and $failedUndo.Message -match 'before Undo were restored') 'Failed Undo rolls back to the state from before Undo.'
    Assert-True ((& $module { $script:fakeValues['HKCU:\Software\Microsoft\GameBar|AutoGameModeEnabled'].Value }) -eq 1) 'Failed Undo rollback includes the operation that failed.'
    Assert-True ((& $module { $script:fakeValues['HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|HideFileExt'].Value }) -eq 0) 'Failed Undo preserves other applied values.'
    $retryUndo = Restore-BhoSystemBackup -Path $retryApply.BackupPath -StateRoot $testRoot -Confirm:$false
    Assert-True $retryUndo.Success 'Undo can be retried using the preserved snapshot.'

    & $module { $script:failOnceName = 'AutoGameModeEnabled' }
    $failed = Invoke-BhoSystemApply -Ids @('show-file-extensions', 'enable-game-mode') -StateRoot $testRoot -Confirm:$false
    Assert-True (-not $failed.Success -and $failed.Message -match 'rolled back') 'A write-then-error failure rolls back the transaction.'
    Assert-True ((& $module { $script:fakeValues['HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced|HideFileExt'].Value }) -eq 'old typed value') 'Earlier successful changes are rolled back.'
    Assert-True (-not (& $module { $script:fakeValues.ContainsKey('HKCU:\Software\Microsoft\GameBar|AutoGameModeEnabled') })) 'The failed attempted write is rolled back too.'

    & $module { $script:powerGuids = @($script:activeGuid) }
    $powerPlan = @(Get-BhoSystemPlan -Ids @('high-performance-power'))
    Assert-True (-not $powerPlan[0].Supported -and $powerPlan[0].Reason -match 'no plan will be created') 'An unavailable High performance plan is skipped.'
    & $module { $script:powerGuids += '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'; $script:fakeAdmin = $false }
    $unprivileged = Invoke-BhoSystemApply -Ids @('high-performance-power') -StateRoot $testRoot -Confirm:$false
    Assert-True (-not $unprivileged.Success -and $null -eq $unprivileged.BackupPath) 'An unprivileged power change stops before snapshot or mutation.'
    & $module { $script:fakeAdmin = $true }
    $powerApply = Invoke-BhoSystemApply -Ids @('high-performance-power') -StateRoot $testRoot -Confirm:$false
    Assert-True $powerApply.Success 'An existing power plan can be activated.'
    Assert-True ((& $module { $script:activeGuid }) -eq '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') 'The requested GUID is active.'
    Assert-True (Get-BhoSystemBackups -StateRoot $testRoot | Where-Object Path -eq $powerApply.BackupPath).RequiresAdmin 'Power backup inventory requests elevation.'
    $powerUndo = Restore-BhoSystemBackup -Path $powerApply.BackupPath -StateRoot $testRoot -Confirm:$false
    Assert-True ($powerUndo.Success -and (& $module { $script:activeGuid }) -eq '381b4222-f694-41f0-9685-ff5bb260df2e') 'Undo restores the exact original power GUID.'

    # Mutate test-owned copies to model hostile backup files. OS boundaries stay mocked.
    $hostile = Get-Content -LiteralPath $apply.BackupPath -Raw | ConvertFrom-Json
    $hostile.Id = [guid]::NewGuid().ToString('N')
    $hostilePath = Join-Path $testRoot ('system-' + $hostile.Id + '.json')
    $hostile.Entries[0].Operations[0].Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $hostile | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $hostilePath -Encoding UTF8
    $beforeWrites = & $module { $script:writes + $script:undoWrites }
    $blocked = Restore-BhoSystemBackup -Path $hostilePath -StateRoot $testRoot -Confirm:$false
    Assert-True (-not $blocked.Success -and $blocked.Message -match 'outside the catalogue') 'Restore rejects a registry target outside the allowlist.'
    Assert-True ((& $module { $script:writes + $script:undoWrites }) -eq $beforeWrites) 'Invalid backup validation happens before mutations.'
    $hostile.Entries[0].Operations[0].Path = $saved.Entries[0].Operations[0].Path
    $hostile.Entries[0].Operations[0].Before.Type = 'ScriptBlock'
    $hostile | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $hostilePath -Encoding UTF8
    $blocked = Restore-BhoSystemBackup -Path $hostilePath -StateRoot $testRoot -Confirm:$false
    Assert-True (-not $blocked.Success -and $blocked.Message -match 'type or data') 'Restore rejects an unknown datatype.'
    $hostile = Get-Content -LiteralPath $powerApply.BackupPath -Raw | ConvertFrom-Json
    $hostile.Id = [guid]::NewGuid().ToString('N'); $hostilePath = Join-Path $testRoot ('system-' + $hostile.Id + '.json')
    $hostile.Entries[0].Operations[0].BeforeGuid = '381b4222; Invoke-Expression unsafe'
    $hostile | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $hostilePath -Encoding UTF8
    $blocked = Restore-BhoSystemBackup -Path $hostilePath -StateRoot $testRoot -Confirm:$false
    Assert-True (-not $blocked.Success -and $blocked.Message -match 'power plan') 'Restore rejects command text posing as a power GUID.'
    & $module { $script:fakeSid = 'S-1-5-21-999-999-999-1001' }
    $blocked = Restore-BhoSystemBackup -Path $apply.BackupPath -StateRoot $testRoot -Confirm:$false
    Assert-True (-not $blocked.Success -and $blocked.Message -match 'another computer or Windows user') 'Restore rejects a snapshot belonging to another Windows user.'
    & $module { $script:fakeSid = 'S-1-5-21-111-222-333-1001' }
    $outside = Restore-BhoSystemBackup -Path $apply.BackupPath -StateRoot (Join-Path $testRoot 'other') -Confirm:$false
    Assert-True (-not $outside.Success -and $outside.Message -match 'directly inside') 'Restore rejects files outside the selected state root.'
    $unknownRejected = $false
    try { $null = Get-BhoSystemPlan -Ids @('not-a-tweak') } catch { $unknownRejected = $true }
    Assert-True $unknownRejected 'Unknown IDs are rejected.'

    $statusPath = [IO.Path]::ChangeExtension($apply.BackupPath, 'status.json')
    & $module { param($unsafePath) $script:unsafeFilesystemPaths = @($unsafePath) } $statusPath
    $beforeWrites = & $module { $script:writes + $script:undoWrites }
    $blocked = Restore-BhoSystemBackup -Path $apply.BackupPath -StateRoot $testRoot -Confirm:$false
    Assert-True (-not $blocked.Success -and $blocked.Message -match 'Reparse') 'Undo rejects a linked status leaf before changing settings.'
    Assert-True ((& $module { $script:writes + $script:undoWrites }) -eq $beforeWrites) 'Unsafe Undo status paths do not cause OS mutations.'
    $missingStatus = Join-Path $testRoot ('system-' + [guid]::NewGuid().ToString('N') + '.status.json')
    & $module { param($unsafePath) $script:unsafeFilesystemPaths = @($unsafePath) } $missingStatus
    $danglingRejected = & $module {
        param($unsafePath)
        try { Assert-BhoSystemNoReparsePath -Path $unsafePath; return $false } catch { return $_.Exception.Message -match 'Reparse' }
    } $missingStatus
    Assert-True $danglingRejected 'Attribute checks reject a link even when Exists/Test-Path would report no target.'
    $lockPath = Join-Path $testRoot 'system.lock'
    & $module { param($unsafePath) $script:unsafeFilesystemPaths = @($unsafePath) } $lockPath
    $blocked = Invoke-BhoSystemApply -Ids @('show-file-extensions') -StateRoot $testRoot -Confirm:$false
    Assert-True (-not $blocked.Success -and $blocked.Message -match 'Reparse') 'Apply rejects an unsafe lock leaf.'
    Assert-True ((& $module { $script:writes + $script:undoWrites }) -eq $beforeWrites) 'Unsafe lock paths do not cause OS mutations.'
    & $module { $script:unsafeFilesystemPaths = @() }
    $outsideFolder = Join-Path $testRoot 'outside-system-state'
    $linkedRoot = Join-Path $testRoot 'linked-system-state'
    $null = New-Item -ItemType Directory -Path $outsideFolder
    $null = New-Item -ItemType Junction -Path $linkedRoot -Target $outsideFolder
    try {
        $blocked = Invoke-BhoSystemApply -Ids @('show-file-extensions') -StateRoot $linkedRoot -Confirm:$false
        Assert-True (-not $blocked.Success -and $blocked.Message -match 'Reparse') 'Apply rejects actual temporary junction ancestry.'
        Assert-True (@(Get-ChildItem -LiteralPath $outsideFolder -Force).Count -eq 0) 'A rejected linked root leaves its target untouched.'
    }
    finally { [IO.Directory]::Delete($linkedRoot) }

    Write-Output ('System tests passed: ' + $script:passed + ' assertions; all OS reads/writes were mocked.')
}
finally {
    Remove-Module BHopsOptimizer.System -Force -ErrorAction SilentlyContinue
    # The target is a freshly created exact test directory under TEMP.
    if ([IO.Path]::GetFullPath($testRoot).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
