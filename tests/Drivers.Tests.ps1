#requires -Version 5.1
# Dependency-free safety tests. All downloads, signatures, OS discovery and PnPUtil calls are faked.
$ErrorActionPreference = 'Stop'
$module = Import-Module (Join-Path $PSScriptRoot '..\src\BHopsOptimizer.Drivers.psm1') -Force -PassThru
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('bhops-driver-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$script:Passed = 0

function Assert-BhoDriverTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Test-BhoDriverCase {
    param([string]$Name, [scriptblock]$Body)
    & $module { param($root)
        $script:DriverTest = @{
            Adapter = [pscustomobject]@{ Id = '01234567-89ab-cdef-0123-456789abcdef'; PnpInstanceId = 'PCI\TEST\INSTANCE'; HardwareIds = @('PCI\VEN_14C3&DEV_0616&SUBSYS_E0CD105B'); DriverVersion = '3.6.0.1425'; InfName = 'oem42.inf' }
            Windows = [pscustomobject]@{ Build = 26200; Client = $true; Is64Bit = $true; Architecture = 'AMD64' }
            Admin = $true; DownloadCalls = 0; SignatureCalls = 0; InstallCalls = 0; ExportCalls = 0
            Events = New-Object 'System.Collections.Generic.List[string]'
            WrongClass = $false; WrongId = $false; WrongVersion = $false; DuplicateInf = $false; ArmOnlyMatch = $false
            SignatureFails = $false; ExportFails = $false; InstallExit = 0; RemainOld = $false
            CorruptDownload = $false; MutateBeforeInstall = $false; ResolveCalls = 0
            Root = $root
        }
    } $fixtureRoot
    & $Body
    $script:Passed++
    Write-Output ('PASS ' + $Name)
}

& $module {
    $script:RealManifest = ${function:Get-BhoManifest}
    $script:RealUrlCheck = ${function:Test-BhoDriverUrl}
    $script:RealSignatureCheck = ${function:Test-BhoDriverPackageSignature}
    function script:Resolve-BhoDriverAdapter {
        param([string]$AdapterId)
        $script:DriverTest.ResolveCalls++
        if ($AdapterId -ne $script:DriverTest.Adapter.Id) { throw 'Unknown test adapter.' }
        if ($script:DriverTest.MutateBeforeInstall -and $script:DriverTest.ResolveCalls -ge 3) { $script:DriverTest.Adapter.InfName = 'oem99.inf' }
        $script:DriverTest.Adapter | Select-Object Id, PnpInstanceId, HardwareIds, DriverVersion, InfName
    }
    function script:Get-BhoDriverWindowsInfo { $script:DriverTest.Windows }
    function script:Test-BhoDriverAdministrator { $script:DriverTest.Admin }
    function script:Get-BhoManifest {
        $entry = @(& $script:RealManifest)[0]
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $entry.Sha256 = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes('fixture'))).Replace('-', '') }
        finally { $sha.Dispose() }
        @($entry)
    }
    function script:Save-BhoDriverDownload {
        param([string]$Url, [string]$Destination)
        $script:DriverTest.DownloadCalls++
        $script:DriverTest.Events.Add('download')
        $text = 'fixture'
        if ($script:DriverTest.CorruptDownload) { $text = 'tampered' }
        [IO.File]::WriteAllText($Destination, $text, (New-Object Text.UTF8Encoding($false)))
    }
    function script:Expand-BhoDriverCab {
        param([string]$CabPath, [string]$Destination)
        $class = 'Net'; $guid = '{4D36E972-E325-11CE-BFC1-08002BE10318}'
        if ($script:DriverTest.WrongClass) { $class = 'Bluetooth'; $guid = '{E0CBF06C-CD8B-4647-BB8A-263B43F0F974}' }
        $id = 'PCI\VEN_14C3&DEV_0616&SUBSYS_E0CD105B'
        if ($script:DriverTest.WrongId) { $id = 'PCI\VEN_14C3&DEV_0616&SUBSYS_E0DE105B' }
        # MediaTek's real INF uses leading zeros; compare versions numerically.
        $version = '3.06.00.1434'
        if ($script:DriverTest.WrongVersion) { $version = '3.6.2.1427' }
        $content = @"
[Version]
Signature="`$WINDOWS NT`$"
Class=$class
ClassGuid=$guid
DriverVer=07/01/2026,$version
CatalogFile=fixture.cat
[Manufacturer]
%MediaTek%=MediaTek,NTamd64.10.0
[MediaTek.NTamd64.10.0]
%Device%=Install,$id
"@
        if ($script:DriverTest.ArmOnlyMatch) {
            $content = $content.Replace($id, 'PCI\VEN_14C3&DEV_0616&SUBSYS_E0DE105B')
            $content += "`r`n[MediaTek.NTarm64.10.0]`r`n%Device%=Install,$id`r`n"
        }
        [IO.File]::WriteAllText((Join-Path $Destination 'fixture.inf'), $content)
        [IO.File]::WriteAllText((Join-Path $Destination 'fixture.cat'), 'fake signature')
        [IO.File]::WriteAllText((Join-Path $Destination 'fixture.sys'), 'fake driver')
        if ($script:DriverTest.DuplicateInf) { [IO.File]::WriteAllText((Join-Path $Destination 'duplicate.inf'), $content) }
        # A different-class INF in the same directory must never be passed to PnPUtil.
        [IO.File]::WriteAllText((Join-Path $Destination 'unrelated.inf'), ($content.Replace('Class=Net', 'Class=Bluetooth')))
        [IO.File]::WriteAllText((Join-Path $Destination 'installer.exe'), 'never run')
    }
    function script:Test-BhoDriverPackageSignature {
        param($Package)
        $script:DriverTest.SignatureCalls++
        $script:DriverTest.Events.Add('signature')
        if ($script:DriverTest.SignatureFails) { throw 'Invalid Microsoft catalog signature or INF membership.' }
        $true
    }
    function script:Invoke-BhoDriverNative {
        param([string]$FilePath, [string[]]$Arguments)
        if ([IO.Path]::GetFileName($FilePath) -ne 'pnputil.exe') { throw 'Unexpected native command in test.' }
        if ($Arguments[0] -eq '/export-driver') {
            $script:DriverTest.ExportCalls++
            $script:DriverTest.Events.Add('export')
            if ($script:DriverTest.ExportFails) { return [pscustomobject]@{ ExitCode = 5; Output = 'Export failed.' } }
            [IO.File]::WriteAllText((Join-Path $Arguments[2] 'old-driver.inf'), 'previous driver')
            return [pscustomobject]@{ ExitCode = 0; Output = 'Exported.' }
        }
        if ($Arguments[0] -ne '/add-driver' -or $Arguments.Count -ne 3 -or $Arguments[2] -ne '/install') { throw 'Unsafe PnPUtil arguments.' }
        $script:DriverTest.InstallCalls++
        $script:DriverTest.Events.Add('install')
        if ([IO.Path]::GetFileName($Arguments[1]) -ne 'fixture.inf') { throw 'PnPUtil received an unrelated INF.' }
        $stage = [IO.Path]::GetDirectoryName($Arguments[1])
        if (@(Get-ChildItem -LiteralPath $stage -Filter '*.inf' -File -Recurse).Count -ne 1) { throw 'More than the selected INF was staged.' }
        if (Test-Path -LiteralPath (Join-Path $stage 'installer.exe')) { throw 'An executable installer was staged.' }
        if ($script:DriverTest.InstallExit -eq 0 -and -not $script:DriverTest.RemainOld) { $script:DriverTest.Adapter.DriverVersion = '3.6.0.1434' }
        return [pscustomobject]@{ ExitCode = $script:DriverTest.InstallExit; Output = 'Simulated package validation/install.' }
    }
}

function Invoke-BhoTestDriverInstall {
    param([switch]$WhatIf)
    Invoke-BhoDriverInstall -AdapterId '01234567-89ab-cdef-0123-456789abcdef' -OfferId '18130bb5-2ffd-4b10-b9a3-1cd04bfcabf3' -StateRoot $fixtureRoot -WhatIf:$WhatIf -Confirm:$false
}

try {
    Test-BhoDriverCase 'exact hardware match and Catalog discovery URL' {
        $result = Get-BhoDriverOffers -AdapterId '01234567-89ab-cdef-0123-456789abcdef'
        Assert-BhoDriverTest ($result.Offers.Count -eq 1 -and $result.Offers[0].Compatible) 'Expected reviewed compatible offer.'
        Assert-BhoDriverTest ($result.CatalogSearchUrl.Contains('SUBSYS_E0CD105B')) 'Catalog search lost subsystem ID.'
    }
    Test-BhoDriverCase 'unsupported adapters get an exact-ID handoff' {
        & $module { $script:DriverTest.Adapter.HardwareIds = @('PCI\VEN_8086&DEV_2725&SUBSYS_00248086') }
        $result = Get-BhoDriverOffers -AdapterId '01234567-89ab-cdef-0123-456789abcdef'
        Assert-BhoDriverTest ($result.Offers.Count -eq 0 -and $result.CatalogSearchUrl.Contains('SUBSYS_00248086')) 'Unknown adapter offered a universal driver.'
    }
    Test-BhoDriverCase 'WhatIf makes no download, backup or installation' {
        $result = Invoke-BhoTestDriverInstall -WhatIf
        $counts = & $module { @($script:DriverTest.DownloadCalls, $script:DriverTest.ExportCalls, $script:DriverTest.InstallCalls) }
        Assert-BhoDriverTest ($result.Success -and $result.WhatIf -and ($counts | Measure-Object -Sum).Sum -eq 0) 'WhatIf had side effects.'
    }
    Test-BhoDriverCase 'old Windows build blocks installation' {
        & $module { $script:DriverTest.Windows.Build = 22000 }
        $result = Invoke-BhoTestDriverInstall
        Assert-BhoDriverTest (-not $result.Success -and $result.Message.Contains('22621')) 'Unsupported Windows build accepted.'
    }
    Test-BhoDriverCase 'ARM64 blocks the reviewed x64 package' {
        & $module { $script:DriverTest.Windows.Architecture = 'ARM64' }
        $result = Invoke-BhoTestDriverInstall
        Assert-BhoDriverTest (-not $result.Success) 'Wrong CPU architecture accepted.'
    }
    Test-BhoDriverCase 'equal or newer installed versions prevent downgrade' {
        & $module { $script:DriverTest.Adapter.DriverVersion = '3.6.0.1434' }
        $result = Invoke-BhoTestDriverInstall
        Assert-BhoDriverTest (-not $result.Success -and $result.Message.Contains('newer')) 'An equal-version update was installed.'
    }
    Test-BhoDriverCase 'administrator requirement blocks before download' {
        & $module { $script:DriverTest.Admin = $false }
        $result = Invoke-BhoTestDriverInstall
        $downloads = & $module { $script:DriverTest.DownloadCalls }
        Assert-BhoDriverTest (-not $result.Success -and $downloads -eq 0) 'Non-admin install downloaded or changed drivers.'
    }
    Test-BhoDriverCase 'hash mismatch prevents backup and installation' {
        & $module { $script:DriverTest.CorruptDownload = $true }
        $result = Invoke-BhoTestDriverInstall
        $installs = & $module { $script:DriverTest.InstallCalls }
        Assert-BhoDriverTest (-not $result.Success -and $result.Message.Contains('SHA-256') -and $installs -eq 0) 'Tampered CAB was accepted.'
    }
    foreach ($guard in @('WrongClass', 'WrongId', 'WrongVersion', 'DuplicateInf', 'ArmOnlyMatch')) {
        Test-BhoDriverCase ('INF guard: ' + $guard) {
            & $module { param($guard) $script:DriverTest[$guard] = $true } $guard
            $result = Invoke-BhoTestDriverInstall
            $installs = & $module { $script:DriverTest.InstallCalls }
            Assert-BhoDriverTest (-not $result.Success -and $installs -eq 0) 'An incompatible or ambiguous INF was accepted.'
        }
    }
    Test-BhoDriverCase 'catalog signature or membership failure blocks installation' {
        & $module { $script:DriverTest.SignatureFails = $true }
        $result = Invoke-BhoTestDriverInstall
        $installs = & $module { $script:DriverTest.InstallCalls }
        Assert-BhoDriverTest (-not $result.Success -and $installs -eq 0) 'Untrusted package was installed.'
    }
    Test-BhoDriverCase 'failed current-driver export blocks installation' {
        & $module { $script:DriverTest.ExportFails = $true }
        $result = Invoke-BhoTestDriverInstall
        $installs = & $module { $script:DriverTest.InstallCalls }
        Assert-BhoDriverTest (-not $result.Success -and $installs -eq 0 -and $result.Message.Contains('Exporting')) 'Install ran without backup.'
    }
    Test-BhoDriverCase 'changed current driver stops a stale install' {
        & $module { $script:DriverTest.MutateBeforeInstall = $true }
        $result = Invoke-BhoTestDriverInstall
        $installs = & $module { $script:DriverTest.InstallCalls }
        Assert-BhoDriverTest (-not $result.Success -and $installs -eq 0 -and $result.Message.Contains('changed')) 'Device state change was ignored.'
    }
    Test-BhoDriverCase 'verified staged exact INF, backup, then install' {
        $result = Invoke-BhoTestDriverInstall
        $events = @(& $module { $script:DriverTest.Events.ToArray() })
        Assert-BhoDriverTest ($result.Success -and $result.InstalledVersion -eq '3.6.0.1434') $result.Message
        Assert-BhoDriverTest (Test-Path -LiteralPath (Join-Path $result.BackupPath 'backup.json')) 'Backup receipt was not written.'
        Assert-BhoDriverTest ($events[-2] -eq 'export' -and $events[-1] -eq 'install') 'Install occurred before backup.'
    }
    Test-BhoDriverCase 'PnPUtil validation failure is returned safely' {
        & $module { $script:DriverTest.InstallExit = 13 }
        $result = Invoke-BhoTestDriverInstall
        Assert-BhoDriverTest (-not $result.Success -and $result.BackupPath -and $result.Message.Contains('exit 13')) 'Package rejection was hidden.'
    }
    Test-BhoDriverCase '3010 preserves reboot requirement with the old active driver' {
        & $module { $script:DriverTest.InstallExit = 3010 }
        $result = Invoke-BhoTestDriverInstall
        Assert-BhoDriverTest ($result.Success -and $result.RebootRequired -and $result.InstalledVersion -eq '3.6.0.1425') 'Exit 3010 was incorrectly inferred from active version.'
    }
    Test-BhoDriverCase 'successful add without driver activation is explicit' {
        & $module { $script:DriverTest.RemainOld = $true }
        $result = Invoke-BhoTestDriverInstall
        Assert-BhoDriverTest (-not $result.Success -and $result.Message.Contains('kept')) 'A staged but inactive driver was reported installed.'
    }
    Test-BhoDriverCase 'strict HTTPS host allowlist rejects attacker URLs' {
        foreach ($url in @('http://download.windowsupdate.com/a.cab', 'https://download.windowsupdate.com.evil.test/a.cab', 'https://user:password@download.windowsupdate.com/a.cab', 'https://download.windowsupdate.com:444/a.cab', 'https://example.com/a.cab')) {
            $blocked = & $module { param($url) try { [void](& $script:RealUrlCheck $url); $false } catch { $true } } $url
            Assert-BhoDriverTest $blocked ('Unsafe URL accepted: ' + $url)
        }
    }
    Test-BhoDriverCase 'real signature guard rejects unsigned catalogs and other publishers' {
        & $module {
            function script:Get-AuthenticodeSignature {
                param([string]$LiteralPath)
                $script:SignatureFixture
            }
            $package = [pscustomobject]@{ CatalogPath = (Join-Path $script:DriverTest.Root 'trust-fixture.cat'); InfPath = (Join-Path $script:DriverTest.Root 'trust-fixture.inf') }
            foreach ($signature in @(
                [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null },
                [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Other Publisher, O=Other Corporation' } }
            )) {
                $script:SignatureFixture = $signature
                $rejected = $false
                try { [void](& $script:RealSignatureCheck $package) } catch { $rejected = $true }
                if (-not $rejected) { throw 'The real signature guard accepted an unsigned or non-Microsoft catalog.' }
            }
        }
    }
    foreach ($location in @('StateRoot', 'driver-work', 'driver-backups')) {
        Test-BhoDriverCase ('junction guard: ' + $location) {
            $caseRoot = Join-Path $fixtureRoot ('path-case-' + [guid]::NewGuid().ToString('N'))
            $targetRoot = Join-Path $fixtureRoot ('junction-target-' + [guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($targetRoot)
            if ($location -eq 'StateRoot') { $link = $caseRoot }
            else { [void][IO.Directory]::CreateDirectory($caseRoot); $link = Join-Path $caseRoot $location }
            # Junction creation does not require administrator privileges and has the same ReparsePoint guard as symlinks.
            New-Item -ItemType Junction -Path $link -Value $targetRoot -ErrorAction Stop | Out-Null
            try {
                $result = Invoke-BhoDriverInstall -AdapterId '01234567-89ab-cdef-0123-456789abcdef' -OfferId '18130bb5-2ffd-4b10-b9a3-1cd04bfcabf3' -StateRoot $caseRoot -Confirm:$false
                $counts = & $module { @($script:DriverTest.ExportCalls, $script:DriverTest.InstallCalls) }
                Assert-BhoDriverTest (-not $result.Success -and $result.Message.Contains('junctions')) 'Driver storage followed a junction.'
                Assert-BhoDriverTest (($counts | Measure-Object -Sum).Sum -eq 0) 'A driver operation ran through a junction.'
                Assert-BhoDriverTest (@(Get-ChildItem -LiteralPath $targetRoot -Force).Count -eq 0) 'A file was written through the junction.'
            } finally {
                $safePrefix = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\') + '\'
                if (-not [IO.Path]::GetFullPath($link).StartsWith($safePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test junction cleanup path.' }
                # Non-recursive deletion removes this verified junction itself, never its target tree.
                [IO.Directory]::Delete($link)
            }
        }
    }
    Test-BhoDriverCase 'driver storage rejects relative, UNC and device paths' {
        foreach ($path in @('relative-state', '\\server\share\state', '\\?\C:\state')) {
            $result = Invoke-BhoDriverInstall -AdapterId '01234567-89ab-cdef-0123-456789abcdef' -OfferId '18130bb5-2ffd-4b10-b9a3-1cd04bfcabf3' -StateRoot $path -Confirm:$false
            Assert-BhoDriverTest (-not $result.Success -and $result.Message.Contains('local')) ('Unsafe storage path was accepted: ' + $path)
        }
    }
    Write-Output ('Driver safety tests passed: ' + $script:Passed)
} finally {
    Remove-Module $module -Force -ErrorAction SilentlyContinue
    # Only remove the unique, verified test workspace beneath the OS temporary directory.
    $absolute = [IO.Path]::GetFullPath($fixtureRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($absolute.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($absolute).StartsWith('bhops-driver-tests-')) {
        Remove-Item -LiteralPath $absolute -Recurse -Force
    }
}
