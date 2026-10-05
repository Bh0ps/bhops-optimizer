#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sourceFiles=Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object {$_.Extension -in @('.ps1','.psm1','.psd1') -and $_.FullName -notmatch '\\(work|dist|artifacts)\\'}
foreach($file in $sourceFiles){
    $errors=$null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$errors) | Out-Null
    if($errors.Count){throw ('Syntax error in '+$file.Name+': '+($errors.Message -join '; '))}
}
[xml]$null=Get-Content -LiteralPath (Join-Path $repoRoot 'src\MainWindow.xaml') -Raw -Encoding UTF8
foreach($file in @('Core.Tests.ps1','System.Tests.ps1','Drivers.Tests.ps1','Worker.Tests.ps1')){
    & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repoRoot ('tests\'+$file))
    if($LASTEXITCODE -ne 0){throw ($file+' failed.')}
}
'All Windows PowerShell 5.1 suites passed.'
