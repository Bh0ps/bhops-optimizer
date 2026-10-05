#requires -Version 5.1
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot 'src\BHopsOptimizer.Worker.psm1') -Force
$testRoot=Join-Path $repoRoot ('work\worker-tests-'+[guid]::NewGuid().ToString('N'))
$jobs=Join-Path $testRoot 'Jobs'
$id=[guid]::NewGuid().ToString('N')
$request=Join-Path $jobs ($id+'.request.json');$response=Join-Path $jobs ($id+'.response.json')
$count=0
function Assert-Rejected {param([scriptblock]$Action,[string]$Label) $failed=$false;try{& $Action}catch{$failed=$true};if(-not $failed){throw ('Expected rejection: '+$Label)};$script:count++;'PASS '+$Label}
try{
    New-Item -ItemType Directory -Path $jobs -Force | Out-Null
    Set-Content -LiteralPath $request -Value '{"SchemaVersion":1}' -Encoding UTF8
    $paths=Assert-BhoWorkerPaths $testRoot $request $response
    if($paths.RequestPath -ne $request){throw 'Valid direct-child job paths were not accepted.'};$count++;'PASS valid generated job paths'
    Assert-Rejected {Assert-BhoWorkerPaths $testRoot $request (Join-Path $testRoot ($id+'.response.json'))} 'outside response directory'
    Assert-Rejected {Assert-BhoWorkerPaths $testRoot $request (Join-Path $jobs ([guid]::NewGuid().ToString('N')+'.response.json'))} 'mismatched job IDs'
    Assert-Rejected {Assert-BhoWorkerPaths $testRoot $request (Join-Path $jobs 'arbitrary.json')} 'arbitrary response filename'
    $bytes=[IO.File]::ReadAllBytes($request)
    [IO.File]::WriteAllText($request,('x'*65537))
    Assert-Rejected {Assert-BhoWorkerPaths $testRoot $request $response} 'oversized request'
    [IO.File]::WriteAllBytes($request,$bytes)
    Write-BhoWorkerResponse $testRoot $request $response ([pscustomobject]@{Success=$true;Data='test'})
    $saved=Get-Content -LiteralPath $response -Raw | ConvertFrom-Json
    if(-not $saved.Success -or $saved.Data -ne 'test'){throw 'Valid response was not written.'};$count++;'PASS structured UTF-8 response'
    $original=[IO.File]::ReadAllBytes($response)
    Assert-Rejected {Write-BhoWorkerResponse $testRoot $request $response ([pscustomobject]@{Data='overwrite'})} 'existing response cannot be overwritten'
    if([Convert]::ToBase64String([IO.File]::ReadAllBytes($response)) -ne [Convert]::ToBase64String($original)){throw 'Rejected write altered the original response.'}
    $outside=Join-Path $testRoot 'outside';New-Item -ItemType Directory -Path $outside | Out-Null
    $junction=Join-Path $testRoot 'LinkedState';New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $outside 'Jobs') | Out-Null
    $linkedRequest=Join-Path $junction ('Jobs\'+$id+'.request.json');$linkedResponse=Join-Path $junction ('Jobs\'+$id+'.response.json')
    Set-Content -LiteralPath $linkedRequest -Value '{}' -Encoding UTF8
    Assert-Rejected {Assert-BhoWorkerPaths $junction $linkedRequest $linkedResponse} 'junction ancestry rejected'
    'Worker tests passed: '+$count+' checks; only temporary test files were touched.'
}finally{
    if(Test-Path -LiteralPath (Join-Path $testRoot 'LinkedState')){[IO.Directory]::Delete((Join-Path $testRoot 'LinkedState'))}
    $resolved=[IO.Path]::GetFullPath($testRoot);$allowed=[IO.Path]::GetFullPath((Join-Path $repoRoot 'work'))+[IO.Path]::DirectorySeparatorChar
    if($resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
