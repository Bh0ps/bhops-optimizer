#requires -Version 5.1
Set-StrictMode -Version 2.0
function Assert-BhoNoReparsePath {
    param([Parameter(Mandatory)][string]$Path)
    $current=[IO.Path]::GetFullPath($Path)
    while($current){
        try{$attributes=[IO.File]::GetAttributes($current)}
        catch [IO.FileNotFoundException]{$attributes=$null}
        catch [IO.DirectoryNotFoundException]{$attributes=$null}
        if($null -ne $attributes -and ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Worker paths cannot contain symbolic links or junctions.'}
        $parent=[IO.Path]::GetDirectoryName($current.TrimEnd([IO.Path]::DirectorySeparatorChar))
        if($parent -eq $current){break}
        $current=$parent
    }
}
function Assert-BhoWorkerPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$RequestPath,[Parameter(Mandatory)][string]$ResponsePath)
    $directory=[IO.Path]::GetFullPath((Join-Path $StateRoot 'Jobs'))
    $request=[IO.Path]::GetFullPath($RequestPath);$response=[IO.Path]::GetFullPath($ResponsePath)
    if([IO.Path]::GetDirectoryName($request) -ne $directory -or [IO.Path]::GetDirectoryName($response) -ne $directory){throw 'Worker files must be direct children of the app job directory.'}
    $requestName=[IO.Path]::GetFileName($request);$responseName=[IO.Path]::GetFileName($response)
    if($requestName -notmatch '^[a-fA-F0-9]{32}\.request\.json$' -or $responseName -notmatch '^[a-fA-F0-9]{32}\.response\.json$' -or $requestName.Substring(0,32) -ne $responseName.Substring(0,32)){throw 'Worker request and response must have the same generated job ID.'}
    foreach($path in @($StateRoot,$directory,$request,$response)){Assert-BhoNoReparsePath $path}
    if(-not [IO.File]::Exists($request)){throw 'Worker request is missing.'}
    $size=(Get-Item -LiteralPath $request -Force).Length
    if($size -lt 1 -or $size -gt 65536){throw 'Worker request size is outside the supported limit.'}
    if([IO.File]::Exists($response) -or [IO.Directory]::Exists($response)){throw 'The worker response path must not already exist.'}
    return [pscustomobject]@{RequestPath=$request;ResponsePath=$response}
}
function Write-BhoWorkerResponse {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StateRoot,[Parameter(Mandatory)][string]$RequestPath,[Parameter(Mandatory)][string]$ResponsePath,[Parameter(Mandatory)]$Response)
    $paths=Assert-BhoWorkerPaths -StateRoot $StateRoot -RequestPath $RequestPath -ResponsePath $ResponsePath
    # CreateNew refuses an existing file/link instead of replacing a destination.
    $stream=New-Object IO.FileStream($paths.ResponsePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{
        $writer=New-Object IO.StreamWriter($stream,(New-Object Text.UTF8Encoding($true)))
        try{$writer.Write(($Response | ConvertTo-Json -Depth 20));$writer.Flush()}finally{$writer.Dispose()}
    }finally{$stream.Dispose()}
}
Export-ModuleMember -Function Assert-BhoWorkerPaths,Write-BhoWorkerResponse
