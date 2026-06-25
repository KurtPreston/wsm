@{
    RootModule        = 'RemoteCursorDesktops.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'b3d7c9a1-2e4f-4a6b-9c1d-7e8f0a1b2c3d'
    Author            = 'Kurt Preston'
    Description       = 'Manage one remote Cursor window per workspace, each pinned to its own named Windows virtual desktop.'
    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Open-RcdWorkspace',
        'Open-RcdAll',
        'Focus-RcdWorkspace',
        'Close-RcdWorkspace',
        'Get-RcdStatus'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @('Focus-Rcd')

    PrivateData       = @{
        PSData = @{
            Tags       = @('Cursor', 'Remote-SSH', 'VirtualDesktop', 'worktree')
            ProjectUri = 'https://github.com/KurtPreston/remote-cursor-desktops'
        }
    }
}
