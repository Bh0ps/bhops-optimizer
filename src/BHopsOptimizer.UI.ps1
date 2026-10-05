function Get-BhoControl { param([string]$Name) return $script:Ui.Controls[$Name] }
function Write-BhoActivity {
    param([string]$Message)
    $box = Get-BhoControl 'ActivityText'
    $box.AppendText(('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $Message + [Environment]::NewLine))
    $box.ScrollToEnd()
}
function Show-BhoPage {
    param([string]$Page)
    $titles = @{
        Overview=@('Your PC, with a plan.','Inspect first. Apply supported changes. Keep an undo path.')
        Network=@('Network tuning','Selections adapt to the capabilities of your Wi-Fi adapter.')
        System=@('Windows, your way.','Reversible preferences with the original values saved.')
        Gaming=@('Ready to play.','A separate selection for Game Mode, capture, mouse, and power.')
        Diagnostics=@('Measure the connection.','Router and internet latency, tested side by side.')
        Drivers=@('Know your driver.','Exact hardware matching before automatic installation.')
        Backups=@('Every change has a way back.','Restore the values saved before an operation.')
    }
    foreach ($name in $titles.Keys) {
        (Get-BhoControl ('Page'+$name)).Visibility = if ($name -eq $Page) {'Visible'} else {'Collapsed'}
        (Get-BhoControl ('Nav'+$name)).Background = if ($name -eq $Page) {'#29415A'} else {'#141D30'}
    }
    (Get-BhoControl 'PageTitle').Text=$titles[$Page][0]
    (Get-BhoControl 'PageSubtitle').Text=$titles[$Page][1]
    (Get-BhoControl 'ContentScroll').ScrollToTop()
    $script:Ui.Page=$Page
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
        Set-BhoBusy $true ('Running '+$Operation+'…')
        Write-BhoActivity ($Operation+' started. '+ $(if($RequiresAdmin){'Administrator approval may be requested.'}else{'Read-only or current-user operation.'}))
    } catch { Set-BhoBusy $false 'Operation did not start.'; Write-BhoActivity $_.Exception.Message }
}
function Complete-BhoUiJob {
    $job=$script:Ui.Job
    if (-not $job) { return }
    if (-not $job.Process.HasExited) {
        (Get-BhoControl 'OperationStatus').Text=('Running '+$job.Operation+' — '+[int]((Get-Date)-$job.StartedAt).TotalSeconds+' seconds')
        return
    }
    $script:Ui.Job=$null
    Set-BhoBusy $false ($job.Operation+' finished.')
    try {
        if (-not (Test-Path -LiteralPath $job.ResponsePath)) { throw 'The worker ended without a response. No success is assumed; check local backups before retrying.' }
        $response=Get-Content -LiteralPath $job.ResponsePath -Raw | ConvertFrom-Json
        if (-not $response.Success) { throw $response.Error }
        if($response.Data.Success -eq $false -and $response.Data.BackupPath){Write-BhoActivity ('Recovery backup: '+$response.Data.BackupPath)}
        if($response.Data.Success -eq $false -and $response.Data.RebootRequired){Write-BhoActivity 'Windows requests a restart to finish pending driver operations.'}
        if ($response.Data.Success -eq $false) { throw $response.Data.Message }
        & $job.Callback $response.Data
        Write-BhoActivity ($job.Operation+' completed.')
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
function Format-BhoPlan {
    param([object[]]$Plan)
    return (($Plan | ForEach-Object {
        $state=if(-not $_.Supported){'SKIP'}elseif(-not $_.Changed){'ALREADY SET'}else{'CHANGE'}
        $before=if($null -eq $_.Before){'(not set)'}elseif($_.Before -is [array]){$_.Before -join ', '}else{$_.Before | ConvertTo-Json -Compress -Depth 5}
        $after=if($_.After -is [array]){$_.After -join ', '}else{$_.After | ConvertTo-Json -Compress -Depth 5}
        '['+$state+'] '+$_.Label+[Environment]::NewLine+'  '+$before+' -> '+$after+[Environment]::NewLine+'  '+$_.Reason+[Environment]::NewLine
    }) -join [Environment]::NewLine)
}
function Invoke-BhoNetworkPreview {
    try {
        $adapter=Get-BhoSelectedAdapter;$selected=Get-BhoSelectedNetworkOptions
        if (-not $selected.Count) { throw 'Choose at least one network setting.' }
        Start-BhoUiJob 'NetworkPlan' ([pscustomobject]@{AdapterId=$adapter.Id;Options=$selected}) {
            param($data)
            (Get-BhoControl 'NetworkPlanText').Text=Format-BhoPlan @($data)
            (Get-BhoControl 'NetworkPlanCard').Visibility='Visible'
        }
    } catch { Write-BhoActivity $_.Exception.Message }
}
function Invoke-BhoSystemPreview {
    param([string]$Group)
    try {
        $selected=Get-BhoSelectedSystemIds $Group
        if (-not $selected.Count) { throw 'Choose at least one setting.' }
        $script:Ui.PlanGroup=$Group
        Start-BhoUiJob 'SystemPlan' ([pscustomobject]@{Ids=$selected}) {
            param($data)
            (Get-BhoControl ($script:Ui.PlanGroup+'PlanText')).Text=Format-BhoPlan @($data)
            (Get-BhoControl ($script:Ui.PlanGroup+'PlanCard')).Visibility='Visible'
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
    if ($Data.BackupPath) { Write-BhoActivity ('Backup saved: '+$Data.BackupPath) }
    if ($Data.RebootRequired) { Write-BhoActivity 'Windows requests a PC restart to finish the driver update. Restart when your work is saved.' }
    $script:Ui.RefreshRequested=$true
}
function Add-BhoOption {
    param($Panel,[string]$Title,[string]$Description,[bool]$Checked,$Tag)
    $check=New-Object Windows.Controls.CheckBox
    $check.IsChecked=$Checked;$check.Tag=$Tag
    [Windows.Automation.AutomationProperties]::SetName($check,$Title)
    [Windows.Automation.AutomationProperties]::SetAutomationId($check,('Option_'+$(if($Tag -is [string]){$Tag}else{$Tag.Id})))
    $content=New-Object Windows.Controls.StackPanel
    $label=New-Object Windows.Controls.TextBlock;$label.Text=$Title;$label.FontWeight='SemiBold';$label.TextWrapping='Wrap'
    $detail=New-Object Windows.Controls.TextBlock;$detail.Text=$Description;$detail.TextWrapping='Wrap';$detail.Foreground='#A1AFC8';$detail.FontSize=12;$detail.Margin='0,5,0,0'
    $content.Children.Add($label) | Out-Null;$content.Children.Add($detail) | Out-Null;$check.Content=$content
    $Panel.Children.Add($check) | Out-Null
    return $check
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
        (Get-BhoControl 'OverviewAdapter').Text='No physical Wi-Fi adapter found'
        (Get-BhoControl 'OverviewAdapterDetail').Text='System and Gaming selections are still available.'
    }
    if (-not $script:Ui.SystemChecks.Count) {
        foreach ($tweak in @($Data.Tweaks)) {
            $check=Add-BhoOption (Get-BhoControl ($tweak.Group+'Options')) $tweak.Title ($tweak.Description+ $(if($tweak.RestartNote){' '+$tweak.RestartNote}else{''})) ([bool]$tweak.Recommended) $tweak
            $script:Ui.SystemChecks+=@($check)
        }
    }
    Set-BhoBackups @($Data.Backups)
}
function Set-BhoBackups {
    param([object[]]$Backups)
    (Get-BhoControl 'BackupGrid').ItemsSource=@($Backups)
    (Get-BhoControl 'OverviewBackupCount').Text=if($Backups.Count){[string]$Backups.Count+' saved operations'}else{'No changes made by this app'}
    (Get-BhoControl 'RestoreBackup').IsEnabled=$false
}
function Set-BhoAdapterDetail {
    $adapter=(Get-BhoControl 'AdapterSelector').SelectedItem
    if (-not $adapter) { return }
    $description=$adapter.Description+[Environment]::NewLine+'Driver '+$adapter.DriverVersion+'  |  '+$adapter.Status+'  |  '+$adapter.LinkSpeed
    (Get-BhoControl 'AdapterDetail').Text=$description
    (Get-BhoControl 'OverviewAdapter').Text=$adapter.Name
    (Get-BhoControl 'OverviewAdapterDetail').Text=$description
    (Get-BhoControl 'DriverInstalled').Text=$description
    $script:Ui.DriverData=$null
    (Get-BhoControl 'DriverGrid').ItemsSource=@()
    (Get-BhoControl 'InstallDriver').IsEnabled=$false
    (Get-BhoControl 'DriverStatus').Text='Check for reviewed updates for this adapter.'
}
function Set-BhoDiagnostics {
    param($Data)
    $script:Ui.Diagnostics=$Data
    (Get-BhoControl 'LatencyGrid').ItemsSource=@($Data.Results)
    (Get-BhoControl 'DiagnosticSummary').Text='Test completed — '+$Data.DurationSeconds+' seconds'
    (Get-BhoControl 'DiagnosticContext').Text=('Background received: '+[Math]::Round($Data.ReceivedBytes/1MB,2)+' MB; sent: '+[Math]::Round($Data.SentBytes/1MB,2)+' MB. RTT delta is the mean absolute change between consecutive successful replies.')
    (Get-BhoControl 'ExportDiagnostics').IsEnabled=$true
}
function Show-BhoWindow {
    param([switch]$Demo,[switch]$SmokeTest,[string]$ScreenshotPath)
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    [xml]$xaml=Get-Content -LiteralPath (Join-Path $script:AppRoot 'src\MainWindow.xaml') -Raw -Encoding UTF8
    $reader=New-Object Xml.XmlNodeReader $xaml
    $window=[Windows.Markup.XamlReader]::Load($reader)
    $workArea=[Windows.SystemParameters]::WorkArea
    $window.MinWidth=[Math]::Min(1000,[Math]::Max(800,$workArea.Width-40))
    $window.MinHeight=[Math]::Min(700,[Math]::Max(600,$workArea.Height-40))
    $window.Width=[Math]::Min(1180,$workArea.Width-40)
    $window.Height=[Math]::Min(820,$workArea.Height-40)
    $script:Ui=@{Window=$window;Controls=@{};Busy=$false;Job=$null;Page='Overview';Demo=[bool]$Demo;NetworkChecks=@();SystemChecks=@();Diagnostics=$null;RefreshRequested=$false;DriverData=$null}
    foreach ($match in [regex]::Matches($xaml.OuterXml,'x:Name="([^"]+)"')) { $name=$match.Groups[1].Value;$script:Ui.Controls[$name]=$window.FindName($name) }
    foreach ($page in @('Overview','Network','System','Gaming','Diagnostics','Drivers','Backups')) {
        $nav=Get-BhoControl ('Nav'+$page);$nav.Tag=$page;$nav.Add_Click({param($sender,$eventArgs) Show-BhoPage $sender.Tag})
    }
    foreach ($pair in @(@('OverviewNetwork','Network'),@('OverviewGaming','Gaming'),@('OverviewDiagnose','Diagnostics'),@('GamingNetwork','Network'))) {
        $button=Get-BhoControl $pair[0];$button.Tag=$pair[1];$button.Add_Click({param($sender,$eventArgs) Show-BhoPage $sender.Tag})
    }
    $networkDefinitions=@(
        @('Prefer5GHz','Prefer 5 GHz','Keep other bands available as a fallback.',$true),
        @('LowRoaming','Lower roaming on a stationary PC','Use the lowest supported roaming level, without disabling roaming.',$true),
        @('DisablePowerSaving','Disable Wi-Fi power saving','Use supported adapter settings and Windows device power permissions.',$true),
        @('MaximumTransmitPower','Use maximum transmit power','Optional; highest transmit power is not a substitute for good router placement.',$false),
        @('DisableUapsd','Disable U-APSD','Optional wireless power-save feature; test whether it helps your adapter.',$false),
        @('AcPerformance','Maximum wireless performance on AC','Change only the current power plan wireless setting when plugged in.',$false)
    )
    foreach ($item in $networkDefinitions) { $script:Ui.NetworkChecks+=@(Add-BhoOption (Get-BhoControl 'NetworkOptions') $item[1] $item[2] $item[3] $item[0]) }
    (Get-BhoControl 'NetworkRecommended').Add_Click({foreach($check in $script:Ui.NetworkChecks){$check.IsChecked=$check.Tag -in @('Prefer5GHz','LowRoaming','DisablePowerSaving')}})
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
    (Get-BhoControl 'CheckDrivers').Add_Click({try{$adapter=Get-BhoSelectedAdapter;Start-BhoUiJob 'DriverCheck' ([pscustomobject]@{AdapterId=$adapter.Id}) {param($data) $script:Ui.DriverData=$data;(Get-BhoControl 'DriverGrid').ItemsSource=@($data.Offers);(Get-BhoControl 'DriverStatus').Text=if(@($data.Offers | Where-Object Compatible).Count){'A reviewed compatible update is available.'}else{'No newer reviewed update is available.'};Write-BhoActivity ('Installed driver: '+$data.InstalledVersion)}}catch{Write-BhoActivity $_.Exception.Message}})
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
    (Get-BhoControl 'PrivilegeStatus').Text=if(Test-BhoAdministrator){'Administrator session'}else{'Elevates only when needed'}
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
    Set-BhoBusy $false 'Ready. No changes are applied on launch.'
    Show-BhoPage 'Overview'
    if($SmokeTest) {
        $script:Ui.ScreenshotPath=$ScreenshotPath
        $smokeTimer=New-Object Windows.Threading.DispatcherTimer;$smokeTimer.Interval=[TimeSpan]::FromSeconds(3)
        $smokeTimer.Add_Tick({
            if($script:Ui.Busy){return}
            if($script:Ui.ScreenshotPath){
                $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$script:Ui.Window.ActualWidth),([int]$script:Ui.Window.ActualHeight),96,96,([Windows.Media.PixelFormats]::Pbgra32)
                $bitmap.Render($script:Ui.Window)
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
