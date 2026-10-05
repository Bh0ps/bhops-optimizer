function Get-BhoControl { param([string]$Name) return $script:Ui.Controls[$Name] }
function Set-BhoTextControl { param([string]$Name,[string]$Text) $control=Get-BhoControl $Name;if($control){$control.Text=$Text} }
function Write-BhoActivity {
    param([string]$Message,[switch]$DetailOnly)
    $box = Get-BhoControl 'ActivityText'
    $box.AppendText(((Get-Date -Format 'HH:mm:ss') + '  ' + $Message + [Environment]::NewLine))
    $box.ScrollToEnd()
    if(-not $script:Ui.Busy -and -not $DetailOnly){(Get-BhoControl 'OperationStatus').Text=$Message}
}
function Show-BhoPage {
    param([string]$Page)
    $titles = @{
        Overview=@('Overview','Device status and recent measurements.')
        Network=@('Network','Wi-Fi settings for a stationary PC.')
        System=@('System','Windows preferences.')
        Gaming=@('Gaming','Game Mode, recording, mouse and power.')
        Diagnostics=@('Diagnostics','Router and internet latency.')
        Drivers=@('Drivers','Reviewed updates for your adapter.')
        Backups=@('Backups','Restore an earlier configuration.')
    }
    foreach ($name in $titles.Keys) {
        (Get-BhoControl ('Page'+$name)).Visibility = if ($name -eq $Page) {'Visible'} else {'Collapsed'}
        (Get-BhoControl ('Nav'+$name)).Background = if ($name -eq $Page) {$script:Ui.Window.FindResource('AccentSoft')} else {[Windows.Media.Brushes]::Transparent}
        $icon=Get-BhoControl ('NavIcon'+$name)
        if($icon){$icon.Stroke=if($name -eq $Page){$script:Ui.Window.FindResource('AccentBrush')}else{$script:Ui.Window.FindResource('TextMuted')}}
    }
    (Get-BhoControl 'PageTitle').Text=$titles[$Page][0]
    (Get-BhoControl 'PageSubtitle').Text=$titles[$Page][1]
    (Get-BhoControl 'ContentScroll').ScrollToTop()
    $script:Ui.Page=$Page
    if([Windows.SystemParameters]::ClientAreaAnimation){
        $fade=[Windows.Media.Animation.DoubleAnimation]::new(0.4,1,[Windows.Duration]::new([TimeSpan]::FromMilliseconds(160)))
        (Get-BhoControl ('Page'+$Page)).BeginAnimation([Windows.UIElement]::OpacityProperty,$fade)
    }
}
function Set-BhoBusy {
    param([bool]$Busy,[string]$Message='Ready.')
    $script:Ui.Busy=$Busy
    (Get-BhoControl 'BusyProgress').Visibility=if($Busy){'Visible'}else{'Hidden'}
    (Get-BhoControl 'OperationStatus').Text=$Message
    foreach ($name in @('NetworkApply','NetworkPreview','SystemApply','SystemPreview','GamingApply','GamingPreview','RunDiagnostics','CheckDrivers','RefreshBackups','NetworkRecommended','AdapterSelector')) {
        (Get-BhoControl $name).IsEnabled=-not $Busy -and -not ($script:Ui.Demo -and $name -match 'Apply')
    }
    (Get-BhoControl 'InstallDriver').IsEnabled=(-not $Busy -and -not $script:Ui.Demo -and $null -ne (Get-BhoControl 'DriverGrid').SelectedItem -and [bool](Get-BhoControl 'DriverGrid').SelectedItem.Compatible)
    (Get-BhoControl 'RestoreBackup').IsEnabled=(-not $Busy -and -not $script:Ui.Demo -and $null -ne (Get-BhoControl 'BackupGrid').SelectedItem)
    foreach($check in @($script:Ui.NetworkChecks)+@($script:Ui.SystemChecks)){$check.IsEnabled=-not $Busy}
}
function Start-BhoUiJob {
    param([string]$Operation,[object]$Arguments,[scriptblock]$Completed,[bool]$RequiresAdmin=$false)
    if ($script:Ui.Busy) { return }
    if ($script:Ui.Demo) { Write-BhoActivity 'Demo preview: no system or network operations are performed.'; return }
    $jobDirectory=Join-Path $StateRoot 'Jobs'
    New-Item -ItemType Directory -Path $jobDirectory -Force | Out-Null
    $id=[guid]::NewGuid().ToString('N')
    $requestPath=Join-Path $jobDirectory ($id+'.request.json')
    $responsePath=Join-Path $jobDirectory ($id+'.response.json')
    [pscustomobject]@{SchemaVersion=1;Operation=$Operation;RequesterSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Arguments=$Arguments} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $requestPath -Encoding UTF8
    $processArgs=@('-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File',('"'+(Join-Path $script:AppRoot 'BHopsOptimizer.ps1')+'"'),'-Action','Worker','-StateRoot',('"'+$StateRoot+'"'),'-RequestPath',('"'+$requestPath+'"'),'-ResponsePath',('"'+$responsePath+'"'))
    try {
        $start=@{FilePath=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe');ArgumentList=$processArgs;WindowStyle='Hidden';PassThru=$true;ErrorAction='Stop'}
        if ($RequiresAdmin -and -not (Test-BhoAdministrator)) { $start.Verb='RunAs' }
        $process=Start-Process @start
        $script:Ui.Job=[pscustomobject]@{Process=$process;ResponsePath=$responsePath;Callback=$Completed;Operation=$Operation;StartedAt=Get-Date}
        $display=Get-BhoOperationDisplayName $Operation
        Set-BhoBusy $true ($display+' in progress…')
        Write-BhoActivity ($display+' started.'+ $(if($RequiresAdmin){' Administrator approval may be requested.'}else{''}))
    } catch { Set-BhoBusy $false 'Operation did not start.'; Write-BhoActivity $_.Exception.Message }
}
function Complete-BhoUiJob {
    $job=$script:Ui.Job
    if (-not $job) { return }
    if (-not $job.Process.HasExited) {
        (Get-BhoControl 'OperationStatus').Text=((Get-BhoOperationDisplayName $job.Operation)+' · '+[int]((Get-Date)-$job.StartedAt).TotalSeconds+' s')
        return
    }
    $script:Ui.Job=$null
    Set-BhoBusy $false ((Get-BhoOperationDisplayName $job.Operation)+' finished.')
    try {
        if (-not (Test-Path -LiteralPath $job.ResponsePath)) { throw 'The worker ended without a response. No success is assumed; check local backups before retrying.' }
        $response=Get-Content -LiteralPath $job.ResponsePath -Raw | ConvertFrom-Json
        if (-not $response.Success) { throw $response.Error }
        if($response.Data.Success -eq $false -and $response.Data.BackupPath){Write-BhoActivity ('Recovery backup: '+$response.Data.BackupPath) -DetailOnly}
        if($response.Data.Success -eq $false -and $response.Data.RebootRequired){Write-BhoActivity 'Windows requests a restart to finish pending driver operations.'}
        if ($response.Data.Success -eq $false) { throw $response.Data.Message }
        & $job.Callback $response.Data
        Write-BhoActivity ((Get-BhoOperationDisplayName $job.Operation)+' complete.') -DetailOnly
    } catch { (Get-BhoControl 'OperationStatus').Text='Operation needs attention.'; Write-BhoActivity ('ERROR: '+$_.Exception.Message) }
    finally { $job.Process.Dispose() }
}
function Get-BhoSelectedAdapter {
    $selected=(Get-BhoControl 'AdapterSelector').SelectedItem
    if (-not $selected) { throw 'Select a physical Wi-Fi adapter in Network first.' }
    return $selected
}
function Get-BhoSelectedNetworkOptions { return @($script:Ui.NetworkChecks | Where-Object IsChecked | ForEach-Object Tag) }
function Get-BhoSelectedSystemIds { param([string]$Group) return @($script:Ui.SystemChecks | Where-Object {$_.IsChecked -and $_.Tag.Group -eq $Group} | ForEach-Object {$_.Tag.Id}) }
function Set-BhoPreview {
    param([string]$Group,[object[]]$Plan,$Snapshot)
    $rows=@(ConvertTo-BhoPreviewRows -Plan $Plan -Snapshot $Snapshot)
    (Get-BhoControl ($Group+'PlanRows')).ItemsSource=$rows
    $changes=@($rows | Where-Object {$_.Supported -and $_.Changed}).Count
    $configured=@($rows | Where-Object {$_.Supported -and -not $_.Changed}).Count
    $skipped=@($rows | Where-Object {-not $_.Supported}).Count
    $parts=@()
    if($changes){$parts+=([string]$changes+$(if($changes -eq 1){' change'}else{' changes'}))}
    if($configured){$parts+=([string]$configured+' already configured')}
    if($skipped){$parts+=([string]$skipped+' unavailable')}
    (Get-BhoControl ($Group+'PlanSummary')).Text=if($parts.Count){$parts -join ' · '}else{'Nothing selected'}
    (Get-BhoControl ($Group+'PlanCard')).Visibility='Visible'
    if($script:Ui.Page -eq $Group -and -not $script:Ui.Demo){$script:Ui.Window.UpdateLayout();(Get-BhoControl ($Group+'PlanCard')).BringIntoView()}
    $script:Ui.PreviewSelections[$Group]=if($Group -eq 'Network'){@(Get-BhoSelectedNetworkOptions) -join ','}else{@(Get-BhoSelectedSystemIds $Group) -join ','}
}
function Invoke-BhoNetworkPreview {
    try {
        $adapter=Get-BhoSelectedAdapter;$selected=Get-BhoSelectedNetworkOptions
        if (-not $selected.Count) { throw 'Choose at least one network setting.' }
        if($script:Ui.Demo){$demo=Get-BhoDemoNetworkPlan $selected;Set-BhoPreview 'Network' $demo.Plan $demo.Snapshot;Write-BhoActivity 'Sample preview ready.';return}
        Start-BhoUiJob 'NetworkPreview' ([pscustomobject]@{AdapterId=$adapter.Id;Options=$selected}) {
            param($data)
            Set-BhoPreview 'Network' @($data.Plan) $data.Snapshot
        }
    } catch { Write-BhoActivity $_.Exception.Message }
}
function Invoke-BhoSystemPreview {
    param([string]$Group)
    try {
        $selected=Get-BhoSelectedSystemIds $Group
        if (-not $selected.Count) { throw 'Choose at least one setting.' }
        if($script:Ui.Demo){Set-BhoPreview $Group @(Get-BhoDemoSystemPlan $selected);Write-BhoActivity 'Sample preview ready.';return}
        $script:Ui.PlanGroup=$Group
        Start-BhoUiJob 'SystemPlan' ([pscustomobject]@{Ids=$selected}) {
            param($data)
            Set-BhoPreview $script:Ui.PlanGroup @($data)
        }
    } catch { Write-BhoActivity $_.Exception.Message }
}
function Confirm-BhoApply {
    param([string]$Message)
    return [Windows.MessageBox]::Show($script:Ui.Window,$Message,'Apply selected changes','YesNo','Question') -eq 'Yes'
}
function Show-BhoApplyResult {
    param($Data)
    Write-BhoActivity $Data.Message
    if ($Data.BackupPath) { Write-BhoActivity ('Backup saved: '+$Data.BackupPath) -DetailOnly }
    if ($Data.RebootRequired) { Write-BhoActivity 'Windows requests a PC restart to finish the driver update. Restart when your work is saved.' }
    $script:Ui.RefreshRequested=$true
}
function Add-BhoOption {
    param($Panel,[string]$Title,[string]$Description,[bool]$Checked,$Tag)
    $check=New-Object Windows.Controls.CheckBox
    $check.IsChecked=$Checked;$check.Tag=$Tag
    [Windows.Automation.AutomationProperties]::SetName($check,$Title)
    [Windows.Automation.AutomationProperties]::SetAutomationId($check,('Option_'+$(if($Tag -is [string]){$Tag}else{$Tag.Id})))
    $check.Style=$script:Ui.Window.FindResource('OptionRow')
    $label=New-Object Windows.Controls.TextBlock;$label.Text=$Title;$label.TextWrapping='Wrap'
    $check.Content=$label
    $tipText=New-Object Windows.Controls.TextBlock;$tipText.Text=$Description;$tipText.TextWrapping='Wrap';$tipText.MaxWidth=360
    $check.ToolTip=$tipText
    [Windows.Controls.ToolTipService]::SetShowDuration($check,20000)
    [Windows.Automation.AutomationProperties]::SetHelpText($check,$Description)
    $check.Add_Click({param($sender,$eventArgs)
        $group=if($sender.Tag -is [string]){'Network'}else{$sender.Tag.Group}
        (Get-BhoControl ($group+'PlanCard')).Visibility='Collapsed'
        $script:Ui.PreviewSelections.Remove($group)
    })
    $Panel.Children.Add($check) | Out-Null
    return $check
}
function Initialize-BhoVisualAssets {
    $assets=Join-Path $script:AppRoot 'assets'
    $brand=Get-Content -LiteralPath (Join-Path $assets 'brand.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $icons=Get-Content -LiteralPath (Join-Path $assets 'icons.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach($page in @('Overview','Network','System','Gaming','Diagnostics','Drivers','Backups')){
        $icon=Get-BhoControl ('NavIcon'+$page)
        $geometry=[Windows.Media.Geometry]::Parse($icons.$page);$geometry.Freeze();$icon.Data=$geometry
    }
    foreach($pair in @(@('QuickIconNetwork','Network'),@('QuickIconGaming','Gaming'),@('QuickIconDiagnostics','Diagnostics'),@('ActivityChevron','ChevronRight'))){
        $icon=Get-BhoControl $pair[0]
        if($icon){$geometry=[Windows.Media.Geometry]::Parse($icons.($pair[1]));$geometry.Freeze();$icon.Data=$geometry}
    }
    $mark=Get-BhoControl 'BrandMark'
    $mark.Data=[Windows.Media.Geometry]::Parse($brand.mark);$mark.Fill=$null
    $mark.Stroke=$script:Ui.Window.FindResource('AccentBrush');$mark.StrokeThickness=[double]$brand.strokeWidth
    $mark.StrokeStartLineCap='Round';$mark.StrokeEndLineCap='Round';$mark.StrokeLineJoin='Round'
    $stream=[IO.File]::OpenRead((Join-Path $assets 'app-icon.png'))
    try{$frame=[Windows.Media.Imaging.BitmapFrame]::Create($stream,[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad);$frame.Freeze();$script:Ui.Window.Icon=$frame}finally{$stream.Dispose()}
    Set-BhoTextControl 'VersionLabel' ('v'+$script:AppVersion)
}
function Get-BhoDemoNetworkPlan {
    param([string[]]$Options)
    $definitions=@(
        @('Prefer5GHz','Preferred Wi-Fi band','PreferredBand',@('0','1','2'),@('Auto','Prefer 2.4 GHz','Prefer 5 GHz'),'0','2'),
        @('LowRoaming','Roaming aggressiveness','RoamIndicateTh',@('1','2','3'),@('Lowest','Medium','Highest'),'2','1'),
        @('DisablePowerSaving','Adapter power saving','LowPowerEnable',@('0','1'),@('Disabled','Enabled'),'0','0'),
        @('MaximumTransmitPower','Transmit power','TransmitPower',@('1','2','3'),@('Low','Medium','Highest'),'3','3'),
        @('DisableUapsd','U-APSD power saving','UAPSDEnable',@('0','1'),@('Disabled','Enabled'),'1','0')
    )
    $properties=@();$plan=@()
    foreach($item in $definitions){
        $properties+=@([pscustomobject]@{RegistryKeyword=$item[2];RegistryValue=@($item[5]);ValidRegistryValues=$item[3];ValidDisplayValues=$item[4]})
        if($Options -contains $item[0]){$plan+=@([pscustomobject]@{Id=$item[0]+'.Advanced';Label=$item[1];Kind='Advanced';Keyword=$item[2];Before=@($item[5]);After=@($item[6]);Supported=$true;Changed=$item[5] -ne $item[6];Reason='Sample adapter capabilities.'})}
    }
    if($Options -contains 'DisablePowerSaving'){$plan+=@([pscustomobject]@{Id='DisablePowerSaving.DevicePower';Label='Windows adapter power saving';Kind='DevicePower';Keyword='Enabled';Before=$false;After=$false;Supported=$true;Changed=$false;Reason='Sample device power setting.'})}
    if($Options -contains 'AcPerformance'){$plan+=@([pscustomobject]@{Id='AcPerformance';Label='Wi-Fi power while plugged in';Kind='AcPower';Before=2;After=0;Supported=$true;Changed=$true;Reason='Battery settings are preserved.'})}
    return [pscustomobject]@{Plan=$plan;Snapshot=[pscustomobject]@{Properties=$properties}}
}
function Get-BhoDemoSystemPlan {
    param([string[]]$Ids)
    $values=@{
        'show-file-extensions'=@('HideFileExt=1 (DWord)','HideFileExt=0 (DWord)')
        'reduce-window-animations'=@('MinAnimate=1 (String); TaskbarAnimations=1 (DWord)','MinAnimate=0 (String); TaskbarAnimations=0 (DWord)')
        'disable-advertising-id'=@('Enabled=1 (DWord)','Enabled=0 (DWord)')
        'disable-tailored-experiences'=@('TailoredExperiencesWithDiagnosticDataEnabled=1 (DWord)','TailoredExperiencesWithDiagnosticDataEnabled=0 (DWord)')
        'enable-game-mode'=@('AutoGameModeEnabled=1 (DWord)','AutoGameModeEnabled=1 (DWord)')
        'disable-background-capture'=@('HistoricalCaptureEnabled=1 (DWord)','HistoricalCaptureEnabled=0 (DWord)')
        'disable-mouse-acceleration'=@('MouseSpeed=1 (String); MouseThreshold1=6 (String); MouseThreshold2=10 (String)','MouseSpeed=0 (String); MouseThreshold1=0 (String); MouseThreshold2=0 (String)')
        'high-performance-power'=@('381b4222-f694-41f0-9685-ff5bb260df2e','8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
    }
    foreach($id in $Ids){$pair=$values[$id];[pscustomobject]@{Id=$id;Label=$id;Before=$pair[0];After=$pair[1];Supported=$true;Changed=$pair[0] -ne $pair[1];Reason='Sample Windows preference.'}}
}
function Set-BhoInventory {
    param($Data)
    $script:Ui.Adapters=@($Data.Adapters | Where-Object IsWifi)
    $selector=Get-BhoControl 'AdapterSelector'
    $previous=$selector.SelectedValue
    $selector.ItemsSource=$script:Ui.Adapters
    if ($previous -and ($script:Ui.Adapters.Id -contains $previous)) { $selector.SelectedValue=$previous }
    elseif ($script:Ui.Adapters.Count) { $active=@($script:Ui.Adapters | Where-Object Status -eq 'Up');$selector.SelectedItem=if($active.Count){$active[0]}else{$script:Ui.Adapters[0]} }
    if (-not $script:Ui.Adapters.Count) {
        (Get-BhoControl 'OverviewAdapter').Text='No Wi-Fi adapter'
        (Get-BhoControl 'OverviewAdapterDetail').Text='System and Gaming are available.'
        Set-BhoTextControl 'OverviewLink' '—';Set-BhoTextControl 'OverviewDriver' '—';Set-BhoTextControl 'OverviewConnection' 'Unavailable'
    }
    if (-not $script:Ui.SystemChecks.Count) {
        foreach ($tweak in @($Data.Tweaks)) {
            $titles=@{'show-file-extensions'='Show file extensions';'reduce-window-animations'='Reduce animations';'disable-advertising-id'='Disable advertising ID';'disable-tailored-experiences'='Disable personalized tips';'enable-game-mode'='Enable Game Mode';'disable-background-capture'='Disable background recording';'disable-mouse-acceleration'='Disable mouse acceleration';'high-performance-power'='High performance power plan'}
            $check=Add-BhoOption (Get-BhoControl ($tweak.Group+'Options')) $titles[$tweak.Id] ($tweak.Description+ $(if($tweak.RestartNote){[Environment]::NewLine+$tweak.RestartNote}else{''})) ([bool]$tweak.Recommended) $tweak
            $script:Ui.SystemChecks+=@($check)
        }
    }
    Set-BhoBackups @($Data.Backups)
}
function Set-BhoBackups {
    param([object[]]$Backups)
    (Get-BhoControl 'BackupGrid').ItemsSource=@($Backups)
    (Get-BhoControl 'OverviewBackupCount').Text=if($Backups.Count){[string]$Backups.Count+' saved'}else{'None yet'}
    (Get-BhoControl 'RestoreBackup').IsEnabled=$false
    $empty=Get-BhoControl 'BackupEmpty'
    if($empty){$empty.Visibility=if($Backups.Count){'Collapsed'}else{'Visible'};(Get-BhoControl 'BackupGrid').Visibility=if($Backups.Count){'Visible'}else{'Collapsed'}}
}
function Set-BhoAdapterDetail {
    $adapter=(Get-BhoControl 'AdapterSelector').SelectedItem
    if (-not $adapter) { return }
    $description=$adapter.Description+[Environment]::NewLine+'Driver '+$adapter.DriverVersion+' · '+$adapter.LinkSpeed
    (Get-BhoControl 'AdapterDetail').Text=$adapter.Description
    (Get-BhoControl 'OverviewAdapter').Text=$adapter.Name
    (Get-BhoControl 'OverviewAdapterDetail').Text=$adapter.Description
    (Get-BhoControl 'DriverInstalled').Text=$description
    Set-BhoTextControl 'OverviewLink' $adapter.LinkSpeed
    Set-BhoTextControl 'OverviewDriver' $adapter.DriverVersion
    Set-BhoTextControl 'OverviewConnection' $(if($adapter.Status -eq 'Up'){'Connected'}else{$adapter.Status})
    (Get-BhoControl 'NetworkPlanCard').Visibility='Collapsed';$script:Ui.PreviewSelections.Remove('Network')
    $script:Ui.DriverData=$null
    (Get-BhoControl 'DriverGrid').ItemsSource=@()
    (Get-BhoControl 'InstallDriver').IsEnabled=$false
    (Get-BhoControl 'DriverStatus').Text='Not checked'
}
function Set-BhoDriverData {
    param($Data)
    $script:Ui.DriverData=$Data
    $offers=@($Data.Offers)
    foreach($offer in $offers){
        $status=if($offer.Compatible){'Available'}elseif([version]$offer.Version -le [version]$Data.InstalledVersion){'Current'}else{'Unavailable'}
        $offer | Add-Member -NotePropertyName ShortStatus -NotePropertyValue $status -Force
    }
    (Get-BhoControl 'DriverGrid').ItemsSource=$offers
    (Get-BhoControl 'DriverStatus').Text=if(@($offers | Where-Object Compatible).Count){'Update available'}elseif($offers.Count){'No compatible update available'}else{'No reviewed update'}
    (Get-BhoControl 'DriverStatus').ToolTip=$Data.Message
    $empty=Get-BhoControl 'DriverEmpty'
    if($empty){$empty.Visibility=if($offers.Count){'Collapsed'}else{'Visible'};(Get-BhoControl 'DriverGrid').Visibility=if($offers.Count){'Visible'}else{'Collapsed'}}
    Write-BhoActivity ('Driver check complete · '+$Data.InstalledVersion)
}
function Set-BhoDiagnostics {
    param($Data)
    $script:Ui.Diagnostics=$Data
    (Get-BhoControl 'LatencyGrid').ItemsSource=@($Data.Results)
    (Get-BhoControl 'DiagnosticSummary').Text='Last test · '+$Data.DurationSeconds+' s'
    $received=if($null -ne $Data.ReceivedBytes){[string][Math]::Round($Data.ReceivedBytes/1MB,1)+' MB received'}else{'Received traffic unavailable'}
    $sent=if($null -ne $Data.SentBytes){[string][Math]::Round($Data.SentBytes/1MB,1)+' MB sent'}else{'Sent traffic unavailable'}
    (Get-BhoControl 'DiagnosticContext').Text=('Traffic during test: '+$received+' · '+$sent)
    (Get-BhoControl 'ExportDiagnostics').IsEnabled=$true
    $first=@($Data.Results)[0]
    Set-BhoTextControl 'OverviewLatencyCaption' $(if($first.Target -in @('1.1.1.1','8.8.8.8')){'Endpoint latency'}else{'Router latency'})
    Set-BhoTextControl 'OverviewLatency' $(if($null -ne $first.MeanMs){'{0:0.#} ms' -f [double]$first.MeanMs}else{'No replies'})
    Set-BhoTextControl 'OverviewLoss' ('{0:0.#}%' -f [double]$first.LossPercent)
    Set-BhoTextControl 'OverviewTestNote' ('Last test · '+$first.Target+$(if($script:Ui.Demo){' · sample'}else{' · '+(Get-Date -Format 'HH:mm')}))
}
function Show-BhoWindow {
    param([switch]$Demo,[switch]$SmokeTest,[string]$ScreenshotPath,[string]$PreviewPage='Overview')
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    [xml]$xaml=Get-Content -LiteralPath (Join-Path $script:AppRoot 'src\MainWindow.xaml') -Raw -Encoding UTF8
    $reader=New-Object Xml.XmlNodeReader $xaml
    $window=[Windows.Markup.XamlReader]::Load($reader)
    $workArea=[Windows.SystemParameters]::WorkArea
    $window.MinWidth=[Math]::Min(900,[Math]::Max(700,$workArea.Width-40))
    $window.MinHeight=[Math]::Min(620,[Math]::Max(500,$workArea.Height-40))
    $window.Width=[Math]::Min(1100,$workArea.Width-40)
    $window.Height=[Math]::Min(780,$workArea.Height-40)
    $script:Ui=@{Window=$window;Controls=@{};Busy=$false;Job=$null;Page='Overview';Demo=[bool]$Demo;NetworkChecks=@();SystemChecks=@();Diagnostics=$null;RefreshRequested=$false;DriverData=$null;PreviewSelections=@{}}
    foreach ($match in [regex]::Matches($xaml.OuterXml,'x:Name="([^"]+)"')) { $name=$match.Groups[1].Value;$script:Ui.Controls[$name]=$window.FindName($name) }
    Initialize-BhoVisualAssets
    $window.Content.Background=$window.FindResource('AppBackground')
    (Get-BhoControl 'ActivityToggle').Add_Click({
        $panel=Get-BhoControl 'ActivityPanel';$opening=$panel.Visibility -ne 'Visible';$panel.Visibility=if($opening){'Visible'}else{'Collapsed'}
        (Get-BhoControl 'ActivityChevron').RenderTransform=[Windows.Media.RotateTransform]::new($(if($opening){90}else{0}),12,12)
        if($opening -and [Windows.SystemParameters]::ClientAreaAnimation){$fade=[Windows.Media.Animation.DoubleAnimation]::new(0,1,[Windows.Duration]::new([TimeSpan]::FromMilliseconds(140)));$panel.BeginAnimation([Windows.UIElement]::OpacityProperty,$fade)}
    })
    foreach ($page in @('Overview','Network','System','Gaming','Diagnostics','Drivers','Backups')) {
        $nav=Get-BhoControl ('Nav'+$page);$nav.Tag=$page;$nav.Add_Click({param($sender,$eventArgs) Show-BhoPage $sender.Tag})
    }
    foreach ($pair in @(@('OverviewNetwork','Network'),@('OverviewGaming','Gaming'),@('OverviewDiagnose','Diagnostics'),@('GamingNetwork','Network'))) {
        $button=Get-BhoControl $pair[0];$button.Tag=$pair[1];$button.Add_Click({param($sender,$eventArgs) Show-BhoPage $sender.Tag})
    }
    $networkDefinitions=@(
        @('Prefer5GHz','Prefer 5 GHz','Keep other bands available as a fallback.',$true),
        @('LowRoaming','Reduce roaming','Use the lowest supported roaming level on a stationary PC, without disabling roaming.',$true),
        @('DisablePowerSaving','Disable Wi-Fi power saving','Use supported adapter settings and Windows device power permissions.',$true),
        @('MaximumTransmitPower','Use maximum transmit power','Optional; highest transmit power is not a substitute for good router placement.',$false),
        @('DisableUapsd','Disable U-APSD','Optional wireless power-save feature; test whether it helps your adapter.',$false),
        @('AcPerformance','Maximum performance on AC','Change only the current power plan wireless setting when plugged in.',$false)
    )
    foreach ($item in $networkDefinitions) { $script:Ui.NetworkChecks+=@(Add-BhoOption (Get-BhoControl 'NetworkOptions') $item[1] $item[2] $item[3] $item[0]) }
    (Get-BhoControl 'NetworkRecommended').Add_Click({foreach($check in $script:Ui.NetworkChecks){$check.IsChecked=$check.Tag -in @('Prefer5GHz','LowRoaming','DisablePowerSaving')};(Get-BhoControl 'NetworkPlanCard').Visibility='Collapsed';$script:Ui.PreviewSelections.Remove('Network')})
    (Get-BhoControl 'AdapterSelector').Add_SelectionChanged({Set-BhoAdapterDetail})
    (Get-BhoControl 'NetworkPreview').Add_Click({Invoke-BhoNetworkPreview})
    (Get-BhoControl 'NetworkApply').Add_Click({
        try {
            $adapter=Get-BhoSelectedAdapter;$selected=Get-BhoSelectedNetworkOptions
            if(-not $selected.Count){throw 'Choose at least one network setting.'}
            if(Confirm-BhoApply ('Apply '+$selected.Count+' selected options to '+$adapter.Name+'?'+[Environment]::NewLine+'Original values will be saved first. Wi-Fi may briefly disconnect.')) {
                Start-BhoUiJob 'NetworkApply' ([pscustomobject]@{AdapterId=$adapter.Id;Options=$selected;DryRun=$false}) {param($data) Show-BhoApplyResult $data} $true
            }
        } catch {Write-BhoActivity $_.Exception.Message}
    })
    foreach($group in @('System','Gaming')) {
        $preview=Get-BhoControl ($group+'Preview');$preview.Tag=$group;$preview.Add_Click({param($sender,$eventArgs) Invoke-BhoSystemPreview $sender.Tag})
        $apply=Get-BhoControl ($group+'Apply');$apply.Tag=$group;$apply.Add_Click({
            param($sender,$eventArgs)
            try {
                $selected=Get-BhoSelectedSystemIds $sender.Tag
                if(-not $selected.Count){throw 'Choose at least one setting.'}
                $requiresAdmin=@($script:Ui.SystemChecks | Where-Object {$_.IsChecked -and $_.Tag.Id -in $selected -and $_.Tag.RequiresAdmin}).Count -gt 0
                if(Confirm-BhoApply ('Apply '+$selected.Count+' selected '+$sender.Tag.ToLower()+' settings? Original values will be saved first.')) {
                    Start-BhoUiJob 'SystemApply' ([pscustomobject]@{Ids=$selected;DryRun=$false}) {param($data) Show-BhoApplyResult $data} $requiresAdmin
                }
            } catch {Write-BhoActivity $_.Exception.Message}
        })
    }
    (Get-BhoControl 'RunDiagnostics').Add_Click({try{$adapter=Get-BhoSelectedAdapter;$count=[int](Get-BhoControl 'SampleSelector').SelectedItem.Tag;Start-BhoUiJob 'Diagnostics' ([pscustomobject]@{AdapterId=$adapter.Id;Samples=$count}) {param($data) Set-BhoDiagnostics $data}}catch{Write-BhoActivity $_.Exception.Message}})
    (Get-BhoControl 'ExportDiagnostics').Add_Click({
        if(-not $script:Ui.Diagnostics){return}
        $dialog=New-Object Microsoft.Win32.SaveFileDialog;$dialog.Filter='JSON diagnostic report (*.json)|*.json';$dialog.FileName='BHops-latency-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.json'
        if($dialog.ShowDialog($script:Ui.Window)){$script:Ui.Diagnostics | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $dialog.FileName -Encoding UTF8;Write-BhoActivity ('Report saved: '+$dialog.FileName)}
    })
    (Get-BhoControl 'CheckDrivers').Add_Click({try{
        $adapter=Get-BhoSelectedAdapter
        if($script:Ui.Demo){Set-BhoDriverData ([pscustomobject]@{InstalledVersion='3.6.0.1434';CatalogSearchUrl='https://www.catalog.update.microsoft.com/';Message='Sample reviewed driver.';Offers=@([pscustomobject]@{Title='MediaTek MT7922 Wi-Fi';Version='3.6.0.1434';Compatible=$false;Reason='Sample: the installed driver is already this version.'})});return}
        Start-BhoUiJob 'DriverCheck' ([pscustomobject]@{AdapterId=$adapter.Id}) {param($data)Set-BhoDriverData $data}
    }catch{Write-BhoActivity $_.Exception.Message}})
    (Get-BhoControl 'DriverGrid').Add_SelectionChanged({(Get-BhoControl 'InstallDriver').IsEnabled=(-not $script:Ui.Busy -and -not $script:Ui.Demo -and $null -ne (Get-BhoControl 'DriverGrid').SelectedItem -and [bool](Get-BhoControl 'DriverGrid').SelectedItem.Compatible)})
    (Get-BhoControl 'InstallDriver').Add_Click({
        try{$adapter=Get-BhoSelectedAdapter;$offer=(Get-BhoControl 'DriverGrid').SelectedItem;if(-not $offer -or -not $offer.Compatible){throw 'Select a newer compatible reviewed update.'}
            if(Confirm-BhoApply ('Install '+$offer.Version+' for '+$adapter.Name+'? The current driver will be exported first. Wi-Fi can reconnect and Windows may request a restart.')) {Start-BhoUiJob 'DriverInstall' ([pscustomobject]@{AdapterId=$adapter.Id;OfferId=$offer.Id;DryRun=$false}) {param($data)Show-BhoApplyResult $data} $true}
        }catch{Write-BhoActivity $_.Exception.Message}
    })
    (Get-BhoControl 'OpenCatalog').Add_Click({if($script:Ui.DriverData.CatalogSearchUrl){Start-Process $script:Ui.DriverData.CatalogSearchUrl}else{Start-Process 'https://www.catalog.update.microsoft.com/'}})
    (Get-BhoControl 'OpenDeviceManager').Add_Click({Start-Process (Join-Path $env:SystemRoot 'System32\devmgmt.msc')})
    (Get-BhoControl 'RefreshBackups').Add_Click({Start-BhoUiJob 'Backups' ([pscustomobject]@{}) {param($data)Set-BhoBackups @($data)}})
    (Get-BhoControl 'BackupGrid').Add_SelectionChanged({(Get-BhoControl 'RestoreBackup').IsEnabled=(-not $script:Ui.Busy -and -not $script:Ui.Demo -and $null -ne (Get-BhoControl 'BackupGrid').SelectedItem)})
    (Get-BhoControl 'RestoreBackup').Add_Click({
        $record=(Get-BhoControl 'BackupGrid').SelectedItem
        if(-not $record){return}
        if(Confirm-BhoApply ('Restore the '+$record.Type.ToLower()+' values saved on '+$record.CreatedAt+'? A network restore may reconnect Wi-Fi.')) {
            $op=if($record.Type -eq 'Network'){'NetworkRestore'}else{'SystemRestore'}
            Start-BhoUiJob $op ([pscustomobject]@{BackupPath=$record.Path;DryRun=$false}) {param($data)Show-BhoApplyResult $data} ([bool]$record.RequiresAdmin)
        }
    })
    (Get-BhoControl 'OpenStateFolder').Add_Click({New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null;Start-Process explorer.exe -ArgumentList ('"'+$StateRoot+'"')})
    (Get-BhoControl 'OpenRepository').Add_Click({Start-Process 'https://github.com/Bh0ps/bhops-optimizer'})
    $timer=New-Object Windows.Threading.DispatcherTimer;$timer.Interval=[TimeSpan]::FromMilliseconds(400)
    $timer.Add_Tick({
        Complete-BhoUiJob
        if($script:Ui.RefreshRequested -and -not $script:Ui.Busy){$script:Ui.RefreshRequested=$false;Start-BhoUiJob 'Inventory' ([pscustomobject]@{}) {param($data)Set-BhoInventory $data}}
    })
    $script:Ui.Timer=$timer
    $window.Add_Closing({param($sender,$eventArgs)if($script:Ui.Busy){$eventArgs.Cancel=$true;Write-BhoActivity 'Wait for the current operation to finish before closing.'}else{$script:Ui.Timer.Stop()}})
    if($Demo) {
        (Get-BhoControl 'DemoBanner').Visibility='Visible'
        $fakeAdapter=[pscustomobject]@{Id='00000000-0000-0000-0000-000000000001';Name='Gaming Wi-Fi';Description='MediaTek Wi-Fi 6E MT7922';DriverVersion='3.6.0.1434';Status='Up';LinkSpeed='866.7 Mbps';IsWifi=$true}
        Set-BhoInventory ([pscustomobject]@{Adapters=@($fakeAdapter);Tweaks=@(Get-BhoSystemTweaks);Backups=@()})
        Set-BhoDiagnostics ([pscustomobject]@{DurationSeconds=25.2;ReceivedBytes=3200000;SentBytes=400000;Results=@([pscustomobject]@{Target='Router';MeanMs=5.0;P95Ms=7;MaxMs=11;LossPercent=0;MeanSuccessiveRttDifferenceMs=1.18},[pscustomobject]@{Target='Internet A';MeanMs=22.5;P95Ms=34;MaxMs=44;LossPercent=0;MeanSuccessiveRttDifferenceMs=5.72})})
        Write-BhoActivity 'Demo preview loaded. Sample data is clearly marked; apply and restore are disabled.'
    } else { $window.Add_ContentRendered({Start-BhoUiJob 'Inventory' ([pscustomobject]@{}) {param($data)Set-BhoInventory $data}}) }
    Set-BhoBusy $false 'Ready'
    Show-BhoPage $PreviewPage
    if($Demo -and $PreviewPage -eq 'Network'){Invoke-BhoNetworkPreview}
    if($Demo -and $PreviewPage -in @('System','Gaming')){Invoke-BhoSystemPreview $PreviewPage}
    if($SmokeTest) {
        $script:Ui.ScreenshotPath=$ScreenshotPath
        $smokeTimer=New-Object Windows.Threading.DispatcherTimer;$smokeTimer.Interval=[TimeSpan]::FromSeconds(3)
        $smokeTimer.Add_Tick({
            if($script:Ui.Busy){return}
            if($script:Ui.ScreenshotPath){
                $visual=$script:Ui.Window.Content
                $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap ([int][Math]::Ceiling($visual.ActualWidth)),([int][Math]::Ceiling($visual.ActualHeight)),96,96,([Windows.Media.PixelFormats]::Pbgra32)
                $bitmap.Render($visual)
                $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder;$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                $stream=[IO.File]::Create($script:Ui.ScreenshotPath);try{$encoder.Save($stream)}finally{$stream.Dispose()}
            }
            $script:Ui.SmokeTimer.Stop();$script:Ui.Window.Close()
        })
        $script:Ui.SmokeTimer=$smokeTimer;$smokeTimer.Start()
    }
    $timer.Start()
    $window.ShowDialog() | Out-Null
}
