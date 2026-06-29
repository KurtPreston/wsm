@{
    RootModule        = 'Docent.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = 'b3d7c9a1-2e4f-4a6b-9c1d-7e8f0a1b2c3d'
    Author            = 'Kurt Preston'
    Description       = 'docent - a cross-platform local daemon that receives {host,path,name} webhooks and brings the matching remote Cursor workspace into focus on this machine.'
    PowerShellVersion = '7.0'

    FunctionsToExport = @(
        'Start-DocentServer',
        'Open-DocentWorkspace',
        'Open-DocentUrl',
        'Focus-DocentWorkspace',
        'Close-DocentWorkspace',
        'Get-DocentStatus',
        'Install-DocentHooks',
        'Invoke-DocentDoctor',
        'Initialize-Docent'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('Focus-Docent')

    PrivateData       = @{
        PSData = @{
            Tags       = @('Cursor', 'Remote-SSH', 'VirtualDesktop', 'webhook', 'grove')
            ProjectUri = 'https://github.com/KurtPreston/docent'
        }
    }
}
