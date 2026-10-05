#requires -Version 5.1
Set-StrictMode -Version 2.0

# Definitions are data owned by this module. A backup never supplies a command,
# registry target, or desired value outside this catalogue.
function Get-BhoSystemDefinitions {
    $explorer = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    $commonSource = 'https://github.com/ChrisTitusTech/winutil/blob/main/config/tweaks.json'
    @(
        [pscustomobject]@{
            Id = 'show-file-extensions'; Group = 'System'; Title = 'Show file name extensions'
            Description = 'Show complete file names in File Explorer. This is a usability preference.'
            Recommended = $true; RequiresAdmin = $false; RestartNote = 'Close and reopen File Explorer, or sign out if needed.'
            SourceUrls = @('https://github.com/microsoft/winget-dsc/blob/main/resources/Microsoft.Windows.Developer/Microsoft.Windows.Developer.psm1')
            Operations = @([pscustomobject]@{ Kind = 'Registry'; Path = $explorer; Name = 'HideFileExt'; Type = 'DWord'; Value = 0 })
        }
        [pscustomobject]@{
            Id = 'reduce-window-animations'; Group = 'System'; Title = 'Reduce window and taskbar animations'
            Description = 'Turn off minimize/maximize and taskbar animations. Other visual effects are preserved.'
            Recommended = $false; RequiresAdmin = $false; RestartNote = 'Sign out and back in to load the animation preferences.'
            SourceUrls = @($commonSource)
            Operations = @(
                [pscustomobject]@{ Kind = 'Registry'; Path = 'HKCU:\Control Panel\Desktop\WindowMetrics'; Name = 'MinAnimate'; Type = 'String'; Value = '0' }
                [pscustomobject]@{ Kind = 'Registry'; Path = $explorer; Name = 'TaskbarAnimations'; Type = 'DWord'; Value = 0 }
            )
        }
        [pscustomobject]@{
            Id = 'disable-advertising-id'; Group = 'System'; Title = 'Turn off app advertising ID'
            Description = 'Disable the current Windows user advertising-ID preference. This is a privacy preference, with no FPS promise.'
            Recommended = $false; RequiresAdmin = $false; RestartNote = 'Reopen affected apps.'
            SourceUrls = @($commonSource, 'https://support.microsoft.com/en-us/windows/privacy/general-privacy-settings-in-windows')
            Operations = @([pscustomobject]@{ Kind = 'Registry'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name = 'Enabled'; Type = 'DWord'; Value = 0 })
        }
        [pscustomobject]@{
            Id = 'disable-tailored-experiences'; Group = 'System'; Title = 'Turn off tailored experiences'
            Description = 'Stop using diagnostic data for personalized tips, ads and recommendations. This is a privacy preference.'
            Recommended = $false; RequiresAdmin = $false; RestartNote = 'Reopen Settings; Windows may need a new sign-in.'
            SourceUrls = @($commonSource, 'https://learn.microsoft.com/en-us/windows/privacy/configure-windows-diagnostic-data-in-your-organization')
            Operations = @([pscustomobject]@{ Kind = 'Registry'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; Name = 'TailoredExperiencesWithDiagnosticDataEnabled'; Type = 'DWord'; Value = 0 })
        }
        [pscustomobject]@{
            Id = 'enable-game-mode'; Group = 'Gaming'; Title = 'Enable Windows Game Mode'
            Description = 'Enable the Windows Game Mode preference for the current user. Results depend on the game and hardware.'
            Recommended = $true; RequiresAdmin = $false; RestartNote = 'Restart running games.'
            SourceUrls = @('https://learn.microsoft.com/en-us/windows/apps/develop/settings/settings-windows-11')
            Operations = @([pscustomobject]@{ Kind = 'Registry'; Path = 'HKCU:\Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Type = 'DWord'; Value = 1 })
        }
        [pscustomobject]@{
            Id = 'disable-background-capture'; Group = 'Gaming'; Title = 'Turn off background game recording'
            Description = 'Turn off Game Bar Record what happened. You lose retrospective clips; manual recording remains available.'
            Recommended = $true; RequiresAdmin = $false; RestartNote = 'Close Game Bar and restart running games.'
            SourceUrls = @('https://github.com/FunkyFr3sh/GameDVR_Config/blob/master/GameDVR_ConfigForm.cs')
            Operations = @([pscustomobject]@{ Kind = 'Registry'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'HistoricalCaptureEnabled'; Type = 'DWord'; Value = 0 })
        }
        [pscustomobject]@{
            Id = 'disable-mouse-acceleration'; Group = 'Gaming'; Title = 'Turn off desktop mouse acceleration'
            Description = 'Disable Enhance pointer precision for the desktop pointer. Games using raw mouse input, including CS2, may ignore it.'
            Recommended = $false; RequiresAdmin = $false; RestartNote = 'Sign out and back in to load the pointer preferences.'
            SourceUrls = @('https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-systemparametersinfoa', $commonSource)
            Operations = @(
                [pscustomobject]@{ Kind = 'Registry'; Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseSpeed'; Type = 'String'; Value = '0' }
                [pscustomobject]@{ Kind = 'Registry'; Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold1'; Type = 'String'; Value = '0' }
                [pscustomobject]@{ Kind = 'Registry'; Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold2'; Type = 'String'; Value = '0' }
            )
        }
        [pscustomobject]@{
            Id = 'high-performance-power'; Group = 'Gaming'; Title = 'Use an existing High performance power plan'
            Description = 'Switch to High performance if that standard plan already exists. It may increase heat, fan noise and battery use; benchmark first.'
            Recommended = $false; RequiresAdmin = $true; RestartNote = 'Effective immediately. The original active plan is saved for Undo.'
            SourceUrls = @('https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options')
            Operations = @([pscustomobject]@{ Kind = 'PowerScheme'; Guid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' })
        }
    )
}

function Get-BhoSystemTweaks {
    [CmdletBinding()]
    param()
    Get-BhoSystemDefinitions | Select-Object Id, Group, Title, Description, Recommended, RequiresAdmin, RestartNote, SourceUrls
}

function Test-BhoSystemWindowsSupport {
    [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and [Environment]::OSVersion.Version.Build -ge 10240
}

function Test-BhoSystemAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    finally { $identity.Dispose() }
}

function Get-BhoSystemIdentity {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { [pscustomobject]@{ ComputerName = [Environment]::MachineName; UserSid = $identity.User.Value } }
    finally { $identity.Dispose() }
}

function Read-BhoSystemRegistryValue {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Name)
    $subkey = $Path.Substring(6)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey, $false)
    try {
        if ($null -eq $key) { return [pscustomobject]@{ KeyExisted = $false; Existed = $false; Type = $null; Value = $null } }
        if ($key.GetValueNames() -notcontains $Name) { return [pscustomobject]@{ KeyExisted = $true; Existed = $false; Type = $null; Value = $null } }
        [pscustomobject]@{
            KeyExisted = $true; Existed = $true; Type = $key.GetValueKind($Name).ToString()
            Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    }
    finally { if ($null -ne $key) { $key.Dispose() } }
}

function ConvertTo-BhoSystemRegistryData {
    param([string] $Type, $Value)
    switch ($Type) {
        'DWord' { return [int]$Value }
        'QWord' { return [long]$Value }
        'Binary' { return ,([byte[]]$Value) }
        'None' { return ,([byte[]]$Value) }
        'MultiString' { return ,([string[]]$Value) }
        default { return [string]$Value }
    }
}

function Write-BhoSystemRegistryValue {
    param([string] $Path, [string] $Name, [string] $Type, $Value)
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Path.Substring(6))
    try {
        $data = ConvertTo-BhoSystemRegistryData -Type $Type -Value $Value
        $key.SetValue($Name, $data, [Microsoft.Win32.RegistryValueKind]::$Type)
    }
    finally { if ($null -ne $key) { $key.Dispose() } }
}

function Undo-BhoSystemRegistryValue {
    param($Operation)
    if ($Operation.Before.Existed) {
        Write-BhoSystemRegistryValue -Path $Operation.Path -Name $Operation.Name -Type $Operation.Before.Type -Value $Operation.Before.Value
        return
    }
    $subkey = $Operation.Path.Substring(6)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($subkey, $true)
    $deleteEmptyKey = $false
    try {
        if ($null -eq $key) { return }
        $key.DeleteValue($Operation.Name, $false)
        # Only an empty leaf created by this operation may be removed. Never
        # recursively delete a registry key or touch other values/subkeys.
        $deleteEmptyKey = -not $Operation.Before.KeyExisted -and $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0
    }
    finally { if ($null -ne $key) { $key.Dispose() } }
    if ($deleteEmptyKey) { [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKey($subkey, $false) }
}

function Invoke-BhoSystemPowerCfg {
    param([string[]] $Arguments)
    $exe = Join-Path $env:SystemRoot 'System32\powercfg.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Windows powercfg.exe is unavailable.' }
    $output = @(& $exe @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ('powercfg failed: ' + ($output -join ' ')) }
    $output -join "`n"
}

function Get-BhoSystemPowerState {
    $pattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    $active = Invoke-BhoSystemPowerCfg -Arguments @('/getactivescheme')
    $list = Invoke-BhoSystemPowerCfg -Arguments @('/list')
    $activeMatch = [regex]::Match($active, $pattern)
    if (-not $activeMatch.Success) { throw 'The active power plan GUID could not be read.' }
    [pscustomobject]@{
        ActiveGuid = $activeMatch.Value.ToLowerInvariant()
        AvailableGuids = @([regex]::Matches($list, $pattern) | ForEach-Object { $_.Value.ToLowerInvariant() } | Select-Object -Unique)
    }
}

function Set-BhoSystemPowerScheme {
    param([string] $Guid)
    if ($Guid -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { throw 'Invalid power plan GUID.' }
    $state = Get-BhoSystemPowerState
    if ($state.AvailableGuids -notcontains $Guid) { throw 'The saved power plan no longer exists. No plan was created.' }
    $null = Invoke-BhoSystemPowerCfg -Arguments @('/setactive', $Guid)
    if ((Get-BhoSystemPowerState).ActiveGuid -ne $Guid) { throw 'Windows did not activate the requested power plan.' }
}

function Test-BhoSystemRegistryData {
    param([string] $Type, $Value)
    switch ($Type) {
        'String' { return $Value -is [string] -and $Value.Length -le 65536 }
        'ExpandString' { return $Value -is [string] -and $Value.Length -le 65536 }
        'DWord' { return ($Value -is [int] -or $Value -is [long]) -and $Value -ge [int]::MinValue -and $Value -le [int]::MaxValue }
        'QWord' { return $Value -is [int] -or $Value -is [long] }
        'Binary' { $items = @($Value); return $items.Count -le 65536 -and @($items | Where-Object { ($_ -isnot [int] -and $_ -isnot [long] -and $_ -isnot [byte]) -or $_ -lt 0 -or $_ -gt 255 }).Count -eq 0 }
        'None' { $items = @($Value); return $items.Count -le 65536 -and @($items | Where-Object { ($_ -isnot [int] -and $_ -isnot [long] -and $_ -isnot [byte]) -or $_ -lt 0 -or $_ -gt 255 }).Count -eq 0 }
        'MultiString' { $items = @($Value); return $items.Count -le 1024 -and @($items | Where-Object { $_ -isnot [string] -or $_.Length -gt 65536 }).Count -eq 0 }
        default { return $false }
    }
}

function Test-BhoSystemRegistryEqual {
    param($Before, $Operation)
    if (-not $Before.Existed -or $Before.Type -ne $Operation.Type) { return $false }
    (ConvertTo-Json -InputObject $Before.Value -Compress -Depth 5) -ceq (ConvertTo-Json -InputObject $Operation.Value -Compress -Depth 5)
}

function New-BhoSystemPlan {
    param([string[]] $Ids)
    $definitions = @(Get-BhoSystemDefinitions)
    if (@($Ids).Count -eq 0) { throw 'Select at least one System or Gaming option.' }
    foreach ($id in @($Ids | Select-Object -Unique)) {
        $definition = @($definitions | Where-Object { $_.Id -ceq $id })
        if ($definition.Count -ne 1) { throw ('Unknown System/Gaming option: ' + $id) }
        $definition = $definition[0]
        $operations = @(); $supported = $true; $reason = ''; $beforeText = @(); $afterText = @()
        if (-not (Test-BhoSystemWindowsSupport)) { $supported = $false; $reason = 'Requires Windows 10 or Windows 11.' }
        else {
            try {
                foreach ($op in $definition.Operations) {
                    if ($op.Kind -eq 'Registry') {
                        $before = Read-BhoSystemRegistryValue -Path $op.Path -Name $op.Name
                        if ($before.Existed -and -not (Test-BhoSystemRegistryData -Type $before.Type -Value $before.Value)) { throw ('Unsupported existing registry data for ' + $op.Name) }
                        $changed = -not (Test-BhoSystemRegistryEqual -Before $before -Operation $op)
                        $operations += [pscustomobject]@{ Kind = 'Registry'; Path = $op.Path; Name = $op.Name; Type = $op.Type; Value = $op.Value; Before = $before; Changed = $changed }
                        $valueText = '<missing>'
                        if ($before.Existed) { $valueText = [string]$before.Value + ' (' + $before.Type + ')' }
                        $beforeText += ($op.Name + '=' + $valueText); $afterText += ($op.Name + '=' + [string]$op.Value + ' (' + $op.Type + ')')
                    }
                    else {
                        $power = Get-BhoSystemPowerState
                        if ($power.AvailableGuids -notcontains $op.Guid) { throw 'High performance is not an existing power plan on this PC; no plan will be created.' }
                        $operations += [pscustomobject]@{ Kind = 'PowerScheme'; Guid = $op.Guid; BeforeGuid = $power.ActiveGuid; Changed = $power.ActiveGuid -ne $op.Guid }
                        $beforeText += $power.ActiveGuid; $afterText += $op.Guid
                    }
                }
            }
            catch { $supported = $false; $reason = $_.Exception.Message; $operations = @() }
        }
        $changed = $supported -and @($operations | Where-Object { $_.Changed }).Count -gt 0
        if ($supported -and -not $changed) { $reason = 'Already configured.' }
        [pscustomobject]@{ Id = $id; Label = $definition.Title; Supported = $supported; Changed = $changed; Before = $beforeText -join '; '; After = $afterText -join '; '; Reason = $reason; RequiresAdmin = $definition.RequiresAdmin; RestartNote = $definition.RestartNote; Operations = $operations }
    }
}

function Get-BhoSystemPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string[]] $Ids)
    New-BhoSystemPlan -Ids $Ids | Select-Object Id, Label, Supported, Changed, Before, After, Reason
}

function Get-BhoSystemStateRoot {
    param([string] $StateRoot)
    if ([string]::IsNullOrWhiteSpace($StateRoot)) { $StateRoot = Join-Path $env:ProgramData 'BHopsOptimizer\System' }
    [IO.Path]::GetFullPath($StateRoot)
}

function Get-BhoSystemPathAttributes {
    param([string] $Path)
    [IO.File]::GetAttributes($Path)
}

function Assert-BhoSystemNoReparsePath {
    param([string] $Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($cursor)) {
        try { $attributes = Get-BhoSystemPathAttributes -Path $cursor }
        catch {
            $cause = $_.Exception.GetBaseException()
            if ($cause -isnot [IO.FileNotFoundException] -and $cause -isnot [IO.DirectoryNotFoundException]) { throw }
            $attributes = $null
        }
        # GetAttributes checks the link itself, including a link whose target
        # does not exist. An Exists/Test-Path precheck could miss that case.
        if ($null -ne $attributes -and ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Reparse points are not allowed in a System data path.' }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Assert-BhoSystemSafeFile {
    param([string] $Path, [string] $StateRoot)
    $root = Get-BhoSystemStateRoot -StateRoot $StateRoot
    $full = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetDirectoryName($full).TrimEnd('\') -ine $root.TrimEnd('\')) { throw 'The backup must be directly inside the selected System state folder.' }
    if ([IO.Path]::GetFileName($full) -notmatch '^system-[0-9a-f]{32}\.json$') { throw 'Invalid System backup filename.' }
    Assert-BhoSystemNoReparsePath -Path $full
    $full
}

function Write-BhoSystemBackupStatus {
    param([string] $Path, [ValidateSet('Pending', 'Applied', 'RolledBack', 'RollbackFailed', 'Restored', 'RestoreFailed')] [string] $Status)
    $statusPath = [IO.Path]::ChangeExtension($Path, 'status.json')
    Assert-BhoSystemNoReparsePath -Path $statusPath
    $json = [pscustomobject]@{ Status = $Status; UpdatedAt = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress
    [IO.File]::WriteAllText($statusPath, $json, [Text.UTF8Encoding]::new($false))
}

function Get-BhoSystemBackupStatus {
    param([string] $Path)
    $statusPath = [IO.Path]::ChangeExtension($Path, 'status.json')
    try { Assert-BhoSystemNoReparsePath -Path $statusPath } catch { return 'Unknown' }
    if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) { return 'Pending' }
    try {
        $status = (Get-Content -LiteralPath $statusPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop).Status
        if ($status -in @('Pending', 'Applied', 'RolledBack', 'RollbackFailed', 'Restored', 'RestoreFailed')) { return $status }
    }
    catch { }
    'Unknown'
}

function Read-BhoSystemBackup {
    param([string] $Path, [string] $StateRoot)
    $full = Assert-BhoSystemSafeFile -Path $Path -StateRoot $StateRoot
    $file = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -gt 1048576) { throw 'Invalid backup size or file type.' }
    $backup = Get-Content -LiteralPath $full -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($backup.SchemaVersion -ne 1 -or $backup.Component -cne 'System' -or $backup.Id -notmatch '^[0-9a-f]{32}$') { throw 'Unsupported System backup format.' }
    if ([IO.Path]::GetFileName($full) -cne ('system-' + $backup.Id + '.json')) { throw 'Backup ID and filename do not match.' }
    $identity = Get-BhoSystemIdentity
    if ($backup.ComputerName -cne $identity.ComputerName -or $backup.UserSid -cne $identity.UserSid) { throw 'This backup belongs to another computer or Windows user.' }
    $parsedDate = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$backup.CreatedAt, [ref]$parsedDate)) { throw 'Invalid backup date.' }
    $definitions = @(Get-BhoSystemDefinitions); $seenEntries = @{}; $seenOperations = @{}
    if (@($backup.Entries).Count -lt 1 -or @($backup.Entries).Count -gt $definitions.Count) { throw 'Invalid backup entry count.' }
    foreach ($entry in $backup.Entries) {
        $definition = @($definitions | Where-Object { $_.Id -ceq $entry.Id })
        if ($definition.Count -ne 1 -or $seenEntries.ContainsKey([string]$entry.Id)) { throw 'Unknown or duplicate backup option.' }
        $seenEntries[[string]$entry.Id] = $true
        if (@($entry.Operations).Count -lt 1 -or @($entry.Operations).Count -gt $definition[0].Operations.Count) { throw 'Invalid backup operation count.' }
        foreach ($op in $entry.Operations) {
            if ($op.Kind -ceq 'Registry') {
                $allowed = @($definition[0].Operations | Where-Object { $_.Kind -ceq 'Registry' -and $_.Path -ceq $op.Path -and $_.Name -ceq $op.Name -and $_.Type -ceq $op.Type -and $_.Value -ceq $op.Value })
                if ($allowed.Count -ne 1) { throw 'The backup contains a registry operation outside the catalogue.' }
                $operationId = $op.Path + '|' + $op.Name
                if ($op.Before.Existed -isnot [bool] -or $op.Before.KeyExisted -isnot [bool]) { throw 'Invalid registry existence flags.' }
                if ($op.Before.Existed) {
                    if (-not $op.Before.KeyExisted -or -not (Test-BhoSystemRegistryData -Type $op.Before.Type -Value $op.Before.Value)) { throw 'Invalid saved registry type or data.' }
                }
                elseif ($null -ne $op.Before.Type -or $null -ne $op.Before.Value) { throw 'Missing registry values must have null type and data.' }
            }
            elseif ($op.Kind -ceq 'PowerScheme') {
                $allowed = @($definition[0].Operations | Where-Object { $_.Kind -ceq 'PowerScheme' -and $_.Guid -ceq $op.Guid })
                if ($allowed.Count -ne 1 -or $op.BeforeGuid -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { throw 'Invalid saved power plan.' }
                $operationId = 'PowerScheme'
            }
            else { throw 'Unknown backup operation type.' }
            if ($seenOperations.ContainsKey($operationId)) { throw 'Duplicate backup operation.' }
            $seenOperations[$operationId] = $true
        }
    }
    $backup
}

function Invoke-BhoSystemUndoOperation {
    param($Operation)
    if ($Operation.Kind -eq 'Registry') {
        Undo-BhoSystemRegistryValue -Operation $Operation
        $actual = Read-BhoSystemRegistryValue -Path $Operation.Path -Name $Operation.Name
        if ($actual.Existed -ne $Operation.Before.Existed) { throw ('Undo verification failed for ' + $Operation.Name) }
        if ($Operation.Before.Existed) {
            $expected = [pscustomobject]@{ Type = $Operation.Before.Type; Value = $Operation.Before.Value }
            if (-not (Test-BhoSystemRegistryEqual -Before $actual -Operation $expected)) { throw ('Undo verification failed for ' + $Operation.Name) }
        }
    }
    else { Set-BhoSystemPowerScheme -Guid $Operation.BeforeGuid }
}

function Invoke-BhoSystemApply {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)] [string[]] $Ids, [string] $StateRoot)
    $backupPath = $null; $attempted = @(); $lock = $null; $changedCount = 0; $skipped = @()
    try {
        $plan = @(New-BhoSystemPlan -Ids $Ids)
        $skipped = @($plan | Where-Object { -not $_.Supported -or -not $_.Changed } | Select-Object Id, Reason)
        $changes = @($plan | Where-Object { $_.Supported -and $_.Changed })
        if ($changes.Count -eq 0) { return [pscustomobject]@{ Success = $true; BackupPath = $null; ChangedCount = 0; Skipped = $skipped; Message = 'No changes are needed.' } }
        if (-not $PSCmdlet.ShouldProcess(($changes.Label -join ', '), 'Back up and apply selected System/Gaming options')) {
            return [pscustomobject]@{ Success = $true; BackupPath = $null; ChangedCount = 0; Skipped = $skipped; Message = 'Preview only; no settings or backup files were changed.' }
        }
        if (@($changes | Where-Object { $_.RequiresAdmin }).Count -gt 0 -and -not (Test-BhoSystemAdministrator)) { throw 'Run as administrator to change the system power plan.' }
        $root = Get-BhoSystemStateRoot -StateRoot $StateRoot
        $id = [guid]::NewGuid().ToString('N')
        $backupPath = Join-Path $root ('system-' + $id + '.json')
        $null = Assert-BhoSystemSafeFile -Path $backupPath -StateRoot $root
        $null = New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop
        $lockPath = Join-Path $root 'system.lock'
        Assert-BhoSystemNoReparsePath -Path $lockPath
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        # Re-read under the lock: the preview is never used as a stale snapshot.
        $plan = @(New-BhoSystemPlan -Ids $Ids)
        $skipped = @($plan | Where-Object { -not $_.Supported -or -not $_.Changed } | Select-Object Id, Reason)
        $changes = @($plan | Where-Object { $_.Supported -and $_.Changed })
        if ($changes.Count -eq 0) { $backupPath = $null; return [pscustomobject]@{ Success = $true; BackupPath = $null; ChangedCount = 0; Skipped = $skipped; Message = 'No changes are needed.' } }
        $identity = Get-BhoSystemIdentity
        $entries = @($changes | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Label = $_.Label; Operations = @($_.Operations | Where-Object { $_.Changed }) } })
        $backup = [pscustomobject]@{ SchemaVersion = 1; Component = 'System'; Id = $id; CreatedAt = [DateTime]::UtcNow.ToString('o'); ComputerName = $identity.ComputerName; UserSid = $identity.UserSid; Entries = $entries }
        $json = ConvertTo-Json -InputObject $backup -Depth 15
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
        if ($bytes.Length -gt 1048576) { throw 'The snapshot exceeds the safe backup size limit. No settings were changed.' }
        $null = Assert-BhoSystemSafeFile -Path $backupPath -StateRoot $root
        $stream = [IO.File]::Open($backupPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try {
            $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        Write-BhoSystemBackupStatus -Path $backupPath -Status Pending
        foreach ($entry in $entries) {
            foreach ($op in $entry.Operations) {
                # Include the attempted write so a write-then-error can be undone.
                $attempted += $op
                if ($op.Kind -eq 'Registry') {
                    Write-BhoSystemRegistryValue -Path $op.Path -Name $op.Name -Type $op.Type -Value $op.Value
                    if (-not (Test-BhoSystemRegistryEqual -Before (Read-BhoSystemRegistryValue -Path $op.Path -Name $op.Name) -Operation $op)) { throw ('Registry verification failed for ' + $op.Name) }
                }
                else { Set-BhoSystemPowerScheme -Guid $op.Guid }
            }
            $changedCount++
        }
        Write-BhoSystemBackupStatus -Path $backupPath -Status Applied
        [pscustomobject]@{ Success = $true; BackupPath = $backupPath; ChangedCount = $changedCount; Skipped = $skipped; Message = 'Selected settings applied and verified. Keep the backup for Undo.'; RestartNotes = @($changes.RestartNote | Select-Object -Unique) }
    }
    catch {
        $failure = $_.Exception.Message; $rollbackErrors = @()
        for ($index = $attempted.Count - 1; $index -ge 0; $index--) {
            try { Invoke-BhoSystemUndoOperation -Operation $attempted[$index] }
            catch { $rollbackErrors += $_.Exception.Message }
        }
        if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            try {
                $status = 'RolledBack'; if ($rollbackErrors.Count -gt 0) { $status = 'RollbackFailed' }
                Write-BhoSystemBackupStatus -Path $backupPath -Status $status
            }
            catch { $rollbackErrors += $_.Exception.Message }
        }
        $message = 'Apply failed: ' + $failure
        if ($attempted.Count -gt 0 -and $rollbackErrors.Count -eq 0) { $message += ' Attempted changes were rolled back.' }
        if ($rollbackErrors.Count -gt 0) { $message += ' Undo needs attention: ' + ($rollbackErrors -join '; ') }
        [pscustomobject]@{ Success = $false; BackupPath = $backupPath; ChangedCount = 0; Skipped = $skipped; Message = $message }
    }
    finally { if ($null -ne $lock) { $lock.Dispose() } }
}

function Get-BhoSystemBackups {
    [CmdletBinding()]
    param([string] $StateRoot)
    $root = Get-BhoSystemStateRoot -StateRoot $StateRoot
    Assert-BhoSystemNoReparsePath -Path $root
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter 'system-*.json' -File -ErrorAction Stop | Sort-Object LastWriteTimeUtc -Descending)) {
        if ($file.Name -notmatch '^system-[0-9a-f]{32}\.json$') { continue }
        try {
            $backup = Read-BhoSystemBackup -Path $file.FullName -StateRoot $root
            $requiresAdmin = @($backup.Entries | ForEach-Object { $_.Operations } | Where-Object { $_.Kind -eq 'PowerScheme' }).Count -gt 0
            [pscustomobject]@{ Id = $backup.Id; Path = $file.FullName; CreatedAt = $backup.CreatedAt; Status = Get-BhoSystemBackupStatus -Path $file.FullName; RequiresAdmin = $requiresAdmin }
        }
        catch { Write-Verbose ('Ignored invalid or foreign System backup: ' + $file.Name) }
    }
}

function Restore-BhoSystemBackup {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)] [string] $Path, [string] $StateRoot)
    $lock = $null; $attempted = @(); $currentOperations = @(); $validatedPath = $null
    try {
        $root = Get-BhoSystemStateRoot -StateRoot $StateRoot
        $validatedPath = Assert-BhoSystemSafeFile -Path $Path -StateRoot $root
        $backup = Read-BhoSystemBackup -Path $validatedPath -StateRoot $root
        Assert-BhoSystemNoReparsePath -Path ([IO.Path]::ChangeExtension($validatedPath, 'status.json'))
        if (-not (Test-BhoSystemWindowsSupport)) { throw 'Requires Windows 10 or Windows 11.' }
        if (-not $PSCmdlet.ShouldProcess($validatedPath, 'Restore the saved System/Gaming settings')) { return [pscustomobject]@{ Success = $true; Message = 'Preview only; no settings were changed.' } }
        $allOperations = @($backup.Entries | ForEach-Object { $_.Operations })
        if (@($allOperations | Where-Object { $_.Kind -eq 'PowerScheme' }).Count -gt 0 -and -not (Test-BhoSystemAdministrator)) { throw 'Run as administrator to restore the system power plan.' }
        $lockPath = Join-Path $root 'system.lock'
        Assert-BhoSystemNoReparsePath -Path $lockPath
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $backup = Read-BhoSystemBackup -Path $validatedPath -StateRoot $root
        $allOperations = @($backup.Entries | ForEach-Object { $_.Operations })
        # Capture the pre-Undo state for failure rollback; do not alter the saved backup.
        foreach ($op in $allOperations) {
            if ($op.Kind -eq 'Registry') {
                $before = Read-BhoSystemRegistryValue -Path $op.Path -Name $op.Name
                if ($before.Existed -and -not (Test-BhoSystemRegistryData -Type $before.Type -Value $before.Value)) { throw 'The current registry data cannot be safely backed up for Undo.' }
                $currentOperations += [pscustomobject]@{ Kind = 'Registry'; Path = $op.Path; Name = $op.Name; Before = $before }
            }
            else {
                $power = Get-BhoSystemPowerState
                if ($power.AvailableGuids -notcontains $op.BeforeGuid) { throw 'The original power plan no longer exists. No plan was created.' }
                $currentOperations += [pscustomobject]@{ Kind = 'PowerScheme'; BeforeGuid = $power.ActiveGuid }
            }
        }
        for ($index = $allOperations.Count - 1; $index -ge 0; $index--) {
            $attempted += $currentOperations[$index]
            Invoke-BhoSystemUndoOperation -Operation $allOperations[$index]
        }
        Write-BhoSystemBackupStatus -Path $validatedPath -Status Restored
        [pscustomobject]@{ Success = $true; Message = 'Saved settings restored. Sign out or restart games where the selected options require it.' }
    }
    catch {
        $failure = $_.Exception.Message; $rollbackErrors = @()
        for ($index = $attempted.Count - 1; $index -ge 0; $index--) {
            try { Invoke-BhoSystemUndoOperation -Operation $attempted[$index] }
            catch { $rollbackErrors += $_.Exception.Message }
        }
        if ($attempted.Count -gt 0 -and $null -ne $validatedPath) {
            try { Write-BhoSystemBackupStatus -Path $validatedPath -Status RestoreFailed }
            catch { $rollbackErrors += $_.Exception.Message }
        }
        $message = 'Undo failed: ' + $failure
        if ($attempted.Count -gt 0 -and $rollbackErrors.Count -eq 0) { $message += ' The settings from before Undo were restored.' }
        if ($rollbackErrors.Count -gt 0) { $message += ' Rollback needs attention: ' + ($rollbackErrors -join '; ') }
        [pscustomobject]@{ Success = $false; Message = $message }
    }
    finally { if ($null -ne $lock) { $lock.Dispose() } }
}

Export-ModuleMember -Function Get-BhoSystemTweaks, Get-BhoSystemPlan, Invoke-BhoSystemApply, Get-BhoSystemBackups, Restore-BhoSystemBackup
