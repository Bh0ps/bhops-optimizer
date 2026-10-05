@{
    RootModule = 'BHopsOptimizer.Core.psm1'
    ModuleVersion = '0.1.0'
    GUID = '5c3a6590-f303-4d25-80e2-f5b60d034cb7'
    Author = 'BHopsOptimizer contributors'
    CompanyName = 'Community'
    Copyright = '(c) BHopsOptimizer contributors. MIT License.'
    Description = 'Capability-aware, reversible Windows Wi-Fi tuning and ICMP diagnostics.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-BhoAdapters', 'Get-BhoSnapshot', 'Get-BhoTuningPlan', 'Invoke-BhoApply', 'Get-BhoBackups', 'Restore-BhoBackup', 'Measure-BhoLatency')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{ PSData = @{ Tags = @('Windows', 'WiFi', 'Gaming', 'Diagnostics'); LicenseUri = 'https://opensource.org/license/mit' } }
}
