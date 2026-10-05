#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName PresentationCore,WindowsBase
$brand=Get-Content -LiteralPath (Join-Path $repoRoot 'assets\brand.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$geometry=[Windows.Media.Geometry]::Parse($brand.mark)
$accent=[Windows.Media.BrushConverter]::new().ConvertFromString($brand.accent)
$background=[Windows.Media.BrushConverter]::new().ConvertFromString($brand.background)
$frames=@()
foreach($size in @(16,24,32,48,64,128,256)){
    $visual=[Windows.Media.DrawingVisual]::new()
    $context=$visual.RenderOpen()
    try{
        $context.PushTransform([Windows.Media.ScaleTransform]::new($size/64.0,$size/64.0))
        $context.DrawRoundedRectangle($background,$null,[Windows.Rect]::new(0,0,64,64),12,12)
        if($brand.style -eq 'stroke'){
            $pen=[Windows.Media.Pen]::new($accent,[double]$brand.strokeWidth)
            $pen.StartLineCap=[Windows.Media.PenLineCap]::Round;$pen.EndLineCap=[Windows.Media.PenLineCap]::Round;$pen.LineJoin=[Windows.Media.PenLineJoin]::Round
            $context.DrawGeometry($null,$pen,$geometry)
        }else{$context.DrawGeometry($accent,$null,$geometry)}
        $context.Pop()
    }finally{$context.Close()}
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($size,$size,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $memory=[IO.MemoryStream]::new()
    try{$encoder.Save($memory);$bytes=$memory.ToArray()}finally{$memory.Dispose()}
    $frames+=@([pscustomobject]@{Size=$size;Bytes=$bytes})
    if($size -eq 256){[IO.File]::WriteAllBytes((Join-Path $repoRoot 'assets\app-icon.png'),$bytes)}
}
$iconPath=Join-Path $repoRoot 'assets\app.ico'
$stream=[IO.File]::Open($iconPath,[IO.FileMode]::Create,[IO.FileAccess]::Write)
$writer=[IO.BinaryWriter]::new($stream)
try{
    $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$frames.Count)
    $offset=6+16*$frames.Count
    foreach($frame in $frames){
        $dimension=if($frame.Size -eq 256){0}else{$frame.Size}
        $writer.Write([byte]$dimension);$writer.Write([byte]$dimension);$writer.Write([byte]0);$writer.Write([byte]0)
        $writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$frame.Bytes.Length);$writer.Write([uint32]$offset)
        $offset+=$frame.Bytes.Length
    }
    foreach($frame in $frames){$writer.Write([byte[]]$frame.Bytes)}
}finally{$writer.Dispose();$stream.Dispose()}
'Brand icon generated from editable vector geometry: '+$iconPath
