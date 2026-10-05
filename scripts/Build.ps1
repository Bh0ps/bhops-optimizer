#requires -Version 5.1
[CmdletBinding()]
param([string]$Version='0.1.0',[string]$OutputDirectory)
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
$dist=if($OutputDirectory){[IO.Path]::GetFullPath($OutputDirectory)}else{Join-Path $repoRoot 'dist'}
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$stage=Join-Path $repoRoot ('work\build-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $stage 'src') -Force | Out-Null
try {
    Copy-Item -LiteralPath (Join-Path $repoRoot 'BHopsOptimizer.ps1') -Destination $stage
    Copy-Item -Path (Join-Path $repoRoot 'src\*') -Destination (Join-Path $stage 'src')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination $stage
    $payload=Join-Path $dist 'BHopsOptimizer.payload.zip'
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $payload -Force
    $compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if(-not(Test-Path -LiteralPath $compiler)){throw 'The .NET Framework C# compiler is unavailable. Run the PowerShell source directly.'}
    $automation=Get-ChildItem -LiteralPath (Join-Path $env:SystemRoot 'Microsoft.NET\assembly\GAC_MSIL\System.Management.Automation') -Recurse -Filter 'System.Management.Automation.dll' | Select-Object -First 1
    if(-not $automation){throw 'Windows PowerShell 5.1 automation assembly is unavailable.'}
    $exe=Join-Path $dist 'BHopsOptimizer.exe'
    & $compiler /nologo /target:winexe /platform:x64 /optimize+ /warn:4 ('/out:'+$exe) ('/resource:'+$payload+',BHopsOptimizer.payload.zip') ('/reference:'+$automation.FullName) /reference:System.Windows.Forms.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll (Join-Path $PSScriptRoot 'Launcher.cs')
    if($LASTEXITCODE -ne 0){throw 'Launcher compilation failed.'}
    $portable=Join-Path $stage 'portable'
    New-Item -ItemType Directory -Path $portable -Force | Out-Null
    Copy-Item -LiteralPath $exe,(Join-Path $repoRoot 'LICENSE') -Destination $portable
    if(Test-Path -LiteralPath (Join-Path $repoRoot 'README.md')){Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination $portable}
    if(Test-Path -LiteralPath (Join-Path $repoRoot 'docs')){Copy-Item -LiteralPath (Join-Path $repoRoot 'docs') -Destination $portable -Recurse}
    $zip=Join-Path $dist ('BHopsOptimizer-v'+$Version+'-win-x64.zip')
    Compress-Archive -Path (Join-Path $portable '*') -DestinationPath $zip -Force
    $hashes=foreach($path in @($exe,$zip)){ $hash=Get-FileHash -LiteralPath $path -Algorithm SHA256; $hash.Hash.ToLowerInvariant()+'  '+[IO.Path]::GetFileName($path) }
    $hashes | Set-Content -LiteralPath (Join-Path $dist 'SHA256SUMS.txt') -Encoding ASCII
    [pscustomobject]@{Executable=$exe;Archive=$zip;Checksums=(Join-Path $dist 'SHA256SUMS.txt');Version=$Version}
} finally {
    $resolved=[IO.Path]::GetFullPath($stage)
    $allowed=[IO.Path]::GetFullPath((Join-Path $repoRoot 'work'))+[IO.Path]::DirectorySeparatorChar
    if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
