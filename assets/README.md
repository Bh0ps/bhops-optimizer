# BHops brand and icons

Original vector icons drawn for BHops Optimizer. The assets use the project's MIT license.

The brand uses an original connection pulse mark: two network endpoints joined by an angular signal hop. Electric blue `#6494FF` on charcoal `#101216` is the primary treatment. `brand.json` is the shared geometry and color source; `logo.svg` contains the standalone mark and `wordmark.svg` pairs it with BHops and the OPTIMIZER subtitle in Segoe UI.

The mark has a 64×64 canvas, no fill, and a 5-unit stroke with rounded caps and joins. Preserve the complete canvas when scaling it. At 16 px, the stroke remains 1.25 px wide; at larger sizes, preserve the same geometry and stroke ratio. The SVGs are editable, original artwork under the project's MIT license.

`icons.json` maps stable PascalCase keys to WPF-compatible path geometry. `icons.svg` is an editable SVG symbol sprite with matching kebab-case IDs. Each icon uses a `0 0 24 24` coordinate system, a 1.7-unit stroke, rounded caps and joins, and no fill. The small circular subpaths in Gaming and Info act as dots when stroked.

`icons-preview.png` shows the set rendered by WPF at 48×48 and 24×24 for visual inspection.

Use a 24×24 view box for navigation and 18×18 or 20×20 for actions. Give the icon a fixed-size container to preserve alignment. Use the same stroke and geometry for hover or selected states; change the brush color and surrounding surface. Avoid glow or double outlines at small sizes.

## WPF

Load the geometry once and cache it for repeated elements:

```powershell
$iconData = Get-Content -LiteralPath "$PSScriptRoot\..\assets\icons.json" -Raw | ConvertFrom-Json
$geometry = [System.Windows.Media.Geometry]::Parse($iconData.Network)
$geometry.Freeze()
```

Put the Path in a 24×24 Canvas inside a Viewbox. `Stretch="None"` preserves the native coordinates; the Viewbox controls its displayed size.

```xml
<Viewbox Width="22" Height="22" Stretch="Uniform">
  <Canvas Width="24" Height="24">
    <Path Data="{Binding IconGeometry}"
          Fill="{x:Null}" Stroke="{Binding IconBrush}" StrokeThickness="1.7"
          StrokeStartLineCap="Round" StrokeEndLineCap="Round"
          StrokeLineJoin="Round" />
  </Canvas>
</Viewbox>
```

For inline SVG, include the sprite once and reference a symbol:

```html
<svg width="24" height="24" aria-hidden="true">
  <use href="#icon-network" />
</svg>
```

The interface should provide text labels or accessible names; the artwork itself is decorative.
