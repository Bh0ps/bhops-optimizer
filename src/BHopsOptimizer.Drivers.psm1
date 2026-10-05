#requires -Version 5.1
Set-StrictMode -Version 2.0

function Get-BhoManifest {
    # This is a reviewed offer, not a promise that a driver fixes latency.
    @([pscustomobject]@{
        Id = '18130bb5-2ffd-4b10-b9a3-1cd04bfcabf3'
        Title = 'MediaTek MT7922 / RZ616 - Microsoft Catalog 3.6.0.1434'
        Version = '3.6.0.1434'
        Date = '2026-07-01'
        HardwareIds = @('PCI\VEN_14C3&DEV_0616&SUBSYS_E0CD105B')
        SourceUrl = 'https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=18130bb5-2ffd-4b10-b9a3-1cd04bfcabf3'
        DownloadUrl = 'https://catalog.s.download.windowsupdate.com/c/msdownload/update/driver/drvs/2026/10/65703f07-5d21-411d-bf07-3eb830a46957_31a20943d060d3b000ffaa2897ab7878f4b82ca9.cab'
        Sha256 = '830A8A125FBDD5114C0DEE113F52C41D38730C01761BAAB78215C71024E5ECAD'
        MinBuild = 22621
        Architecture = 'AMD64'
        ClassGuid = '{4D36E972-E325-11CE-BFC1-08002BE10318}'
    })
}

function Get-BhoProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Resolve-BhoDriverAdapter {
    param([Parameter(Mandatory = $true)][string]$AdapterId)
    $wanted = [guid]::Empty
    if (-not [guid]::TryParse($AdapterId, [ref]$wanted)) { throw 'Select an adapter by its exact InterfaceGuid.' }
    $adapter = $null
    if (Get-Command Get-BhoAdapters -ErrorAction SilentlyContinue) {
        foreach ($candidate in @(Get-BhoAdapters)) {
            $candidateId = [guid]::Empty
            if ([guid]::TryParse([string](Get-BhoProperty $candidate 'Id' ''), [ref]$candidateId) -and $candidateId -eq $wanted) {
                $adapter = $candidate
                break
            }
        }
    }
    if ($null -eq $adapter) {
        $netAdapter = @(Get-CimInstance Win32_NetworkAdapter -ErrorAction Stop | Where-Object { $_.GUID -and ([guid]$_.GUID -eq $wanted) })
        if ($netAdapter.Count -ne 1) { throw 'The selected adapter could not be resolved uniquely.' }
        $device = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.DeviceID -eq $netAdapter[0].PNPDeviceID })
        if ($device.Count -ne 1) { throw 'The selected adapter has no unique Plug and Play device.' }
        $adapter = [pscustomobject]@{ Id = $wanted.ToString(); PnpInstanceId = $device[0].DeviceID; HardwareIds = @($device[0].HardwareID) }
    }
    $instance = [string](Get-BhoProperty $adapter 'PnpInstanceId' '')
    if ([string]::IsNullOrWhiteSpace($instance)) { throw 'The selected adapter has no Plug and Play instance ID.' }
    $signedDriver = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { $_.DeviceID -eq $instance })
    if ($signedDriver.Count -ne 1) { throw 'The currently installed driver could not be resolved uniquely.' }
    $ids = @(Get-BhoProperty $adapter 'HardwareIds' @())
    if ($ids.Count -eq 0) {
        $device = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.DeviceID -eq $instance })
        if ($device.Count -eq 1) { $ids = @($device[0].HardwareID) }
    }
    if ($ids.Count -eq 0) { throw 'No exact hardware IDs were available for this adapter.' }
    [pscustomobject]@{
        Id = $wanted.ToString()
        PnpInstanceId = $instance
        HardwareIds = $ids
        DriverVersion = [string]$signedDriver[0].DriverVersion
        InfName = [string]$signedDriver[0].InfName
    }
}

function Get-BhoDriverWindowsInfo {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    [pscustomobject]@{ Build = [int]$os.BuildNumber; Client = ([int]$os.ProductType -eq 1); Is64Bit = [Environment]::Is64BitOperatingSystem; Architecture = [string]$env:PROCESSOR_ARCHITECTURE }
}

function Test-BhoDriverAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-BhoDriverUrl {
    param([Parameter(Mandatory = $true)][string]$Url)
    $uri = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { throw 'Invalid driver download URL.' }
    $hosts = @('catalog.s.download.windowsupdate.com', 'catalog.download.windowsupdate.com', 'download.windowsupdate.com')
    if ($uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or $hosts -notcontains $uri.DnsSafeHost.ToLowerInvariant()) {
        throw 'Driver downloads must use an allowlisted Microsoft Windows Update HTTPS host.'
    }
    return $uri
}

function Assert-BhoDriverSafePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'Driver storage must use an absolute local path.' }
    $resolved = [IO.Path]::GetFullPath($Path)
    if ($resolved -notmatch '^[A-Za-z]:\\') { throw 'Driver storage must use a local drive, not a UNC or device path.' }
    $current = $resolved
    while ($current) {
        try {
            $attributes = [IO.File]::GetAttributes($current)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Driver paths cannot contain symbolic links or junctions.'
            }
        } catch [IO.FileNotFoundException] {
            # New paths are allowed; existing parents are still inspected.
        } catch [IO.DirectoryNotFoundException] {
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
    return $resolved
}

function New-BhoDriverDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    [void](Assert-BhoDriverSafePath $Path)
    [void][IO.Directory]::CreateDirectory($Path)
    [void](Assert-BhoDriverSafePath $Path)
}

function Get-BhoDriverOffers {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$AdapterId)
    $adapter = Resolve-BhoDriverAdapter $AdapterId
    $windows = Get-BhoDriverWindowsInfo
    $offers = @()
    foreach ($entry in @(Get-BhoManifest)) {
        $matches = @($entry.HardwareIds | Where-Object { $adapter.HardwareIds -contains $_ })
        if ($matches.Count -eq 0) { continue }
        $compatible = $true
        $reason = 'Exact hardware ID matches. Package verification and a current driver backup are required before installation.'
        if (-not $windows.Client -or -not $windows.Is64Bit -or $windows.Architecture -ne $entry.Architecture -or $windows.Build -lt $entry.MinBuild) {
            $compatible = $false
            $reason = 'This reviewed package requires x64 Windows 11, build 22621 or later.'
        } elseif ([version]$entry.Version -le [version]$adapter.DriverVersion) {
            $compatible = $false
            $reason = 'The installed driver is already this version or newer.'
        }
        $offers += [pscustomobject]@{
            Id = $entry.Id; Title = $entry.Title; Version = $entry.Version; Date = $entry.Date
            HardwareIds = @($entry.HardwareIds); Source = 'Microsoft Update Catalog'; SourceUrl = $entry.SourceUrl
            DownloadUrl = $entry.DownloadUrl; Sha256 = $entry.Sha256; Compatible = $compatible; Reason = $reason
        }
    }
    $searchId = [string]$adapter.HardwareIds[0]
    # Prefer the exact subsystem ID without revision for a useful Catalog search.
    foreach ($id in $adapter.HardwareIds) {
        if ($id -match '^PCI\\VEN_[0-9A-F]{4}&DEV_[0-9A-F]{4}&SUBSYS_[0-9A-F]{8}$') { $searchId = $id; break }
    }
    [pscustomobject]@{
        AdapterId = $adapter.Id; InstalledVersion = $adapter.DriverVersion; HardwareIds = @($adapter.HardwareIds)
        Offers = @($offers); Source = 'Microsoft Update Catalog'
        CatalogSearchUrl = 'https://www.catalog.update.microsoft.com/Search.aspx?q=' + [uri]::EscapeDataString($searchId)
        Message = $(if ($offers.Count) { 'Reviewed offers are listed below; latency improvements are not guaranteed.' } else { 'No reviewed automatic update for this adapter. Use the exact hardware ID Catalog search or your PC/motherboard manufacturer support page.' })
    }
}

function Save-BhoDriverDownload {
    param([string]$Url, [string]$Destination)
    [void](Assert-BhoDriverSafePath $Destination)
    $next = Test-BhoDriverUrl $Url
    $oldTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $oldTls -bor [Net.SecurityProtocolType]::Tls12
        for ($redirect = 0; $redirect -le 5; $redirect++) {
            $request = [Net.HttpWebRequest]::Create($next)
            $request.AllowAutoRedirect = $false
            $request.Timeout = 60000
            $request.ReadWriteTimeout = 60000
            $response = $request.GetResponse()
            try {
                $status = [int]$response.StatusCode
                if ($status -in @(301, 302, 303, 307, 308)) {
                    if ($redirect -eq 5) { throw 'Too many driver download redirects.' }
                    $location = [string]$response.Headers['Location']
                    if (-not $location) { throw 'Driver download redirect has no destination.' }
                    $next = Test-BhoDriverUrl ((New-Object uri($next, $location)).AbsoluteUri)
                    continue
                }
                if ($status -ne 200) { throw ('Driver download failed: HTTP ' + $status) }
                $inputStream = $response.GetResponseStream()
                [void](Assert-BhoDriverSafePath $Destination)
                $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew)
                try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose(); $inputStream.Dispose() }
                return
            } finally { $response.Dispose() }
        }
    } finally { [Net.ServicePointManager]::SecurityProtocol = $oldTls }
}

function Invoke-BhoDriverNative {
    param([string]$FilePath, [string[]]$Arguments)
    $output = @(& $FilePath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output -join [Environment]::NewLine }
}

function Expand-BhoDriverCab {
    param([string]$CabPath, [string]$Destination)
    [void](Assert-BhoDriverSafePath $CabPath)
    [void](Assert-BhoDriverSafePath $Destination)
    $result = Invoke-BhoDriverNative (Join-Path $env:windir 'System32\expand.exe') @('-F:*', $CabPath, $Destination)
    if ($result.ExitCode -ne 0) { throw 'Windows could not extract the driver CAB.' }
}

function Read-BhoDriverInf {
    param([string]$Path)
    [void](Assert-BhoDriverSafePath $Path)
    $text = [IO.File]::ReadAllText($Path)
    $versionSection = [regex]::Match($text, '(?ims)^\s*\[Version\]\s*$(.*?)(?=^\s*\[|\z)').Groups[1].Value
    if (-not $versionSection) { throw 'Driver INF has no Version section.' }
    $class = [regex]::Match($versionSection, '(?im)^\s*Class\s*=\s*([^;\r\n]+)').Groups[1].Value.Trim().Trim('"')
    $classGuid = [regex]::Match($versionSection, '(?im)^\s*ClassGuid\s*=\s*([^;\r\n]+)').Groups[1].Value.Trim().Trim('"')
    $driverVer = [regex]::Match($versionSection, '(?im)^\s*DriverVer\s*=\s*[^,\r\n]+,\s*([\d.]+)').Groups[1].Value
    $catalogs = @([regex]::Matches($versionSection, '(?im)^\s*CatalogFile(?:\.NTamd64)?\s*=\s*([^;\r\n]+)') | ForEach-Object { $_.Groups[1].Value.Trim().Trim('"') } | Select-Object -Unique)
    # Only IDs in x64 model sections qualify; an ARM-only ID elsewhere in the INF is insufficient.
    $models = @([regex]::Matches($text, '(?ims)^\s*\[[^\]\r\n]+\.NTamd64(?:\.[^\]\r\n]*)?\]\s*$(.*?)(?=^\s*\[|\z)') | ForEach-Object { $_.Groups[1].Value }) -join "`n"
    $ids = @([regex]::Matches($models, '(?im)^\s*[^;\r\n=]+\s*=\s*[^,;\r\n]+,\s*((?:PCI|USB)\\[^,;\s]+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
    [pscustomobject]@{ Path = $Path; Class = $class; ClassGuid = $classGuid; Version = $driverVer; Catalogs = $catalogs; HardwareIds = $ids; Text = $text }
}

function Find-BhoDriverPackage {
    param([string]$ExtractRoot, $Adapter, $Offer)
    [void](Assert-BhoDriverSafePath $ExtractRoot)
    $matching = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $ExtractRoot -Filter '*.inf' -File -Recurse)) {
        $inf = Read-BhoDriverInf $file.FullName
        if ($inf.Class -ne 'Net' -or $inf.ClassGuid -ne '{4D36E972-E325-11CE-BFC1-08002BE10318}') { continue }
        if (-not $inf.Version -or [version]$inf.Version -ne [version]$Offer.Version) { continue }
        if (@($inf.HardwareIds | Where-Object { $Adapter.HardwareIds -contains $_ -and $Offer.HardwareIds -contains $_ }).Count -eq 0) { continue }
        if ($inf.Catalogs.Count -ne 1 -or $inf.Text -notmatch '(?i)NTamd64') { continue }
        $matching += $inf
    }
    if ($matching.Count -ne 1) { throw 'The downloaded package must contain exactly one matching x64 Network-class INF at the offered version.' }
    $selected = $matching[0]
    $catalogName = $selected.Catalogs[0]
    if ([IO.Path]::GetFileName($catalogName) -ne $catalogName -or [IO.Path]::GetExtension($catalogName) -ne '.cat') { throw 'Unsafe INF catalog path.' }
    $catalog = Join-Path ([IO.Path]::GetDirectoryName($selected.Path)) $catalogName
    [void](Assert-BhoDriverSafePath $catalog)
    if (-not (Test-Path -LiteralPath $catalog -PathType Leaf)) { throw 'The INF-referenced signature catalog is missing.' }
    [pscustomobject]@{ InfPath = $selected.Path; CatalogPath = $catalog; Inf = $selected }
}

function Initialize-BhoCatalogVerifier {
    if ('BHopsOptimizer.DriverTrust' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
namespace BHopsOptimizer {
 public static class DriverTrust {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct CatalogInfo { public uint Size,Version; public string CatalogPath,MemberTag,MemberPath; public IntPtr File,Hash; public uint HashSize; public IntPtr CatalogContext,Admin; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  struct TrustData { public uint Size; public IntPtr Policy,Sip; public uint Ui,Revocation,Choice; public IntPtr Info; public uint State; public IntPtr StateData; public string Url; public uint Flags,Context; public IntPtr Settings; }
  [DllImport("wintrust.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CryptCATAdminAcquireContext2(out IntPtr admin, IntPtr subsystem, string algorithm, IntPtr policy, uint flags);
  [DllImport("wintrust.dll", SetLastError=true)] static extern bool CryptCATAdminCalcHashFromFileHandle2(IntPtr admin, IntPtr file, ref uint size, byte[] hash, uint flags);
  [DllImport("wintrust.dll")] static extern bool CryptCATAdminReleaseContext(IntPtr admin, uint flags);
  [DllImport("wintrust.dll", CharSet=CharSet.Unicode)] static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);
  public static bool VerifyMember(string catalog, string member) {
   foreach(string algorithm in new string[]{"SHA256","SHA1"}) {
    IntPtr admin=IntPtr.Zero, info=IntPtr.Zero, hashPtr=IntPtr.Zero;
    TrustData data=new TrustData(); bool initialized=false;
    try {
     if(!CryptCATAdminAcquireContext2(out admin,IntPtr.Zero,algorithm,IntPtr.Zero,0)) continue;
     using(FileStream stream=File.Open(member,FileMode.Open,FileAccess.Read,FileShare.Read)) {
      uint size=0; IntPtr handle=stream.SafeFileHandle.DangerousGetHandle();
      if(!CryptCATAdminCalcHashFromFileHandle2(admin,handle,ref size,null,0) || size==0) continue;
      byte[] hash=new byte[size]; if(!CryptCATAdminCalcHashFromFileHandle2(admin,handle,ref size,hash,0)) continue;
      hashPtr=Marshal.AllocHGlobal((int)size); Marshal.Copy(hash,0,hashPtr,(int)size);
      CatalogInfo cat=new CatalogInfo(); cat.Size=(uint)Marshal.SizeOf(typeof(CatalogInfo)); cat.CatalogPath=catalog; cat.MemberPath=member; cat.MemberTag=BitConverter.ToString(hash).Replace("-",""); cat.File=handle; cat.Hash=hashPtr; cat.HashSize=size; cat.Admin=admin;
      info=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(CatalogInfo))); Marshal.StructureToPtr(cat,info,false);
      data.Size=(uint)Marshal.SizeOf(typeof(TrustData)); data.Ui=2; data.Choice=2; data.Info=info; data.State=1; data.Flags=0x1000;
      Guid action=new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE"); initialized=true;
      int result=WinVerifyTrust(new IntPtr(-1),ref action,ref data);
      data.State=2; WinVerifyTrust(new IntPtr(-1),ref action,ref data); initialized=false;
      if(result==0) return true;
     }
    } finally {
     if(initialized) { data.State=2; Guid action=new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE"); WinVerifyTrust(new IntPtr(-1),ref action,ref data); }
     if(info!=IntPtr.Zero) { Marshal.DestroyStructure(info,typeof(CatalogInfo)); Marshal.FreeHGlobal(info); }
     if(hashPtr!=IntPtr.Zero) Marshal.FreeHGlobal(hashPtr);
     if(admin!=IntPtr.Zero) CryptCATAdminReleaseContext(admin,0);
    }
   }
   return false;
  }
 }
}
'@ -ErrorAction Stop
}

function Test-BhoDriverPackageSignature {
    param($Package)
    [void](Assert-BhoDriverSafePath $Package.CatalogPath)
    [void](Assert-BhoDriverSafePath $Package.InfPath)
    $signature = Get-AuthenticodeSignature -LiteralPath $Package.CatalogPath -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) { throw 'The driver catalog does not have a valid Windows trust signature.' }
    $subject = $signature.SignerCertificate.Subject
    if ($subject -notmatch '(?i)(?:^|,\s*)O=Microsoft Corporation(?:,|$)' -and $subject -notmatch '(?i)(?:^|,\s*)CN=Microsoft Windows Hardware Compatibility Publisher(?:,|$)') {
        throw 'The driver catalog was not signed by an accepted Microsoft publisher.'
    }
    Initialize-BhoCatalogVerifier
    if (-not [BHopsOptimizer.DriverTrust]::VerifyMember($Package.CatalogPath, $Package.InfPath)) { throw 'The selected INF is not verified as a member of its signed Microsoft catalog.' }
    return $true
}

function New-BhoDriverStage {
    param($Package, [string]$StageRoot)
    $source = [IO.Path]::GetDirectoryName($Package.InfPath)
    [void](Assert-BhoDriverSafePath $source)
    [void](Assert-BhoDriverSafePath $StageRoot)
    # Copy the package data, but only the selected INF. Never run package installers.
    foreach ($file in @(Get-ChildItem -LiteralPath $source -File -Recurse)) {
        if ($file.Extension -eq '.inf' -and $file.FullName -ne $Package.InfPath) { continue }
        if ($file.Extension -notin @('.inf', '.cat', '.sys', '.dll', '.bin', '.dat', '.firmware')) { continue }
        $relative = $file.FullName.Substring($source.Length).TrimStart('\', '/')
        $target = Join-Path $StageRoot $relative
        $parent = [IO.Path]::GetDirectoryName($target)
        New-BhoDriverDirectory $parent
        [void](Assert-BhoDriverSafePath $file.FullName)
        [void](Assert-BhoDriverSafePath $target)
        $sourceStream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $targetStream = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $sourceStream.CopyTo($targetStream) } finally { $targetStream.Dispose() }
        } finally { $sourceStream.Dispose() }
    }
    Join-Path $StageRoot ([IO.Path]::GetFileName($Package.InfPath))
}

function New-BhoDriverResult {
    param([bool]$Success, [string]$InstalledVersion, $BackupPath, [bool]$RebootRequired, [string]$Message, [bool]$WhatIf = $false)
    [pscustomobject]@{ Success = $Success; InstalledVersion = $InstalledVersion; BackupPath = $BackupPath; RebootRequired = $RebootRequired; Message = $Message; WhatIf = $WhatIf }
}

function Invoke-BhoDriverInstall {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][string]$AdapterId,
        [Parameter(Mandatory = $true)][string]$OfferId,
        [string]$StateRoot = (Join-Path $env:ProgramData 'BHopsOptimizer')
    )
    $installed = ''
    $backup = $null
    $reboot = $false
    try {
        $adapter = Resolve-BhoDriverAdapter $AdapterId
        $installed = $adapter.DriverVersion
        $inventory = Get-BhoDriverOffers $AdapterId
        $offer = @($inventory.Offers | Where-Object { $_.Id -eq $OfferId })
        if ($offer.Count -ne 1) { throw 'This offer is not a reviewed exact hardware match for the selected adapter.' }
        $offer = $offer[0]
        if (-not $offer.Compatible) { throw $offer.Reason }
        [void](Test-BhoDriverUrl $offer.DownloadUrl)
        if (-not $PSCmdlet.ShouldProcess($adapter.PnpInstanceId, ('Verify, back up, and install Microsoft driver ' + $offer.Version))) {
            return New-BhoDriverResult $true $installed $null $false 'No changes made. Would verify the package, export the current driver, and install the reviewed newer driver.' ([bool]$WhatIfPreference)
        }
        if (-not (Test-BhoDriverAdministrator)) { throw 'Run BHops Optimizer as administrator to export and install a driver.' }
        if (-not $adapter.InfName -or $adapter.InfName -notmatch '^oem\d+\.inf$') { throw 'The current driver has no exportable OEM INF; installation was stopped to preserve rollback.' }
        $root = Assert-BhoDriverSafePath $StateRoot
        $runId = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
        $work = Join-Path (Join-Path $root 'driver-work') $runId
        $extract = Join-Path $work 'extracted'
        $stage = Join-Path $work 'selected-package'
        New-BhoDriverDirectory $extract
        New-BhoDriverDirectory $stage
        $cab = Join-Path $work 'package.cab'
        Save-BhoDriverDownload $offer.DownloadUrl $cab
        [void](Assert-BhoDriverSafePath $cab)
        $hash = (Get-FileHash -LiteralPath $cab -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($offer.Sha256 -and $hash -ne $offer.Sha256) { throw 'The driver download SHA-256 did not match the reviewed manifest.' }
        Expand-BhoDriverCab $cab $extract
        $package = Find-BhoDriverPackage $extract $adapter $offer
        [void](Test-BhoDriverPackageSignature $package)
        $selectedInf = New-BhoDriverStage $package $stage
        $stagedPackage = Find-BhoDriverPackage $stage $adapter $offer
        [void](Test-BhoDriverPackageSignature $stagedPackage)
        # Re-resolve immediately before backup/install to prevent stale device/version decisions.
        $fresh = Resolve-BhoDriverAdapter $AdapterId
        if ($fresh.PnpInstanceId -ne $adapter.PnpInstanceId -or $fresh.InfName -ne $adapter.InfName -or $fresh.DriverVersion -ne $installed) { throw 'The adapter or installed driver changed during verification. Refresh before retrying.' }
        if (@($offer.HardwareIds | Where-Object { $fresh.HardwareIds -contains $_ }).Count -eq 0) { throw 'The adapter hardware IDs changed during verification.' }
        $backup = Join-Path (Join-Path (Join-Path $root 'driver-backups') $adapter.Id) $runId
        New-BhoDriverDirectory $backup
        $pnputil = Join-Path $env:windir 'System32\pnputil.exe'
        $export = Invoke-BhoDriverNative $pnputil @('/export-driver', $adapter.InfName, $backup)
        [void](Assert-BhoDriverSafePath $backup)
        if ($export.ExitCode -ne 0 -or @(Get-ChildItem -LiteralPath $backup -Filter '*.inf' -File -Recurse).Count -eq 0) { throw 'Exporting the current driver failed. The new driver was not installed.' }
        $receipt = [pscustomobject]@{ AdapterId = $adapter.Id; PnpInstanceId = $adapter.PnpInstanceId; HardwareIds = $adapter.HardwareIds; PreviousVersion = $installed; PreviousInf = $adapter.InfName; RequestedVersion = $offer.Version; OfferId = $offer.Id; SourceUrl = $offer.SourceUrl; Sha256 = $hash; BackupPath = $backup; CreatedUtc = [DateTime]::UtcNow.ToString('o') }
        $receiptPath = Join-Path $backup 'backup.json'
        [void](Assert-BhoDriverSafePath $receiptPath)
        $receiptStream = [IO.File]::Open($receiptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = (New-Object Text.UTF8Encoding($true)).GetBytes(($receipt | ConvertTo-Json -Depth 5))
            $receiptStream.Write($bytes, 0, $bytes.Length)
        } finally { $receiptStream.Dispose() }
        # PnPUtil validates catalog/package integrity again. An exact INF path avoids installing other drivers in the CAB.
        [void](Assert-BhoDriverSafePath $selectedInf)
        [void](Assert-BhoDriverSafePath $backup)
        $install = Invoke-BhoDriverNative $pnputil @('/add-driver', $selectedInf, '/install')
        $reboot = ($install.ExitCode -eq 3010)
        if ($install.ExitCode -notin @(0, 3010)) { throw ('Windows rejected the driver package (PnPUtil exit ' + $install.ExitCode + '). The previous driver backup is available.') }
        $after = Resolve-BhoDriverAdapter $AdapterId
        $installed = $after.DriverVersion
        if ($reboot) { return New-BhoDriverResult $true $installed $backup $true 'Windows accepted the driver and requires a restart. Save your work and restart when convenient; BHops Optimizer will not restart automatically.' }
        if ([version]$installed -lt [version]$offer.Version) { return New-BhoDriverResult $false $installed $backup $false 'Windows validated and added the package but kept the currently active driver. No driver was removed; refresh after a manual restart or inspect Windows driver ranking.' }
        return New-BhoDriverResult $true $installed $backup $false 'The verified Microsoft driver is installed. The previous driver was exported for rollback. Retest latency; driver updates do not guarantee a jitter fix.'
    } catch {
        return New-BhoDriverResult $false $installed $backup $reboot $_.Exception.Message
    }
}

Export-ModuleMember -Function Get-BhoDriverOffers, Invoke-BhoDriverInstall
