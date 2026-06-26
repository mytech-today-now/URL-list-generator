@{
    # Module manifest for list-gen
    # Version: 3.1.0 (Parameter alias fix, quality improvements)
    RootModule        = 'list-gen.psm1'
    ModuleVersion     = '3.1.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'myTech.Today'
    CompanyName       = 'myTech.Today'
    Copyright         = '(c) 2024-2025 myTech.Today. All rights reserved.'
    Description       = 'Web Directory URL List Generator - Extracts file URLs from web directory listings'
    PowerShellVersion = '7.0'
    CompatiblePSEditions = @('Core')

    # Modules that must be imported into the global environment prior to importing this module
    RequiredModules   = @()

    # Assemblies that must be loaded prior to importing this module
    RequiredAssemblies = @()

    # Script files (.ps1) that are run in the caller's environment prior to importing this module
    ScriptsToProcess  = @()

    # Type files (.ps1xml) to be loaded when importing this module
    TypesToProcess    = @()

    # Format files (.ps1xml) to be loaded when importing this module
    FormatsToProcess  = @()

    # Modules to import as nested modules of this module
    NestedModules     = @(
        'lib/logging.ps1'
        'lib/network.ps1'
        'lib/url.ps1'
        'lib/input.ps1'
        'lib/output.ps1'
    )

    # Functions to export from this module (explicit list for clarity and control)
    FunctionsToExport = @(
        'Invoke-ListGen'
        'Invoke-ListGenCLI'
        'Normalize-Url'
        'Test-IsFileUrl'
        'Extract-FileUrls'
        'Resolve-RelativeUrl'
        'Should-IncludeUrl'
        'Get-UrlFileName'
        'Parse-InputFile'
        'Parse-CommandLineEntries'
        'Parse-InteractiveInput'
        'Validate-AndNormalizeEntries'
        'Initialize-Log'
        'Write-Log'
        'Write-DebugLog'
        'Write-InfoLog'
        'Write-WarnLog'
        'Write-ErrorLog'
        'Set-NetworkConfig'
        'Get-NetworkConfig'
        'Invoke-WebRequestWithRetry'
        'Invoke-HttpClientRequest'
        'Test-CertificatePin'
        'Get-DefaultOutputDir'
        'Get-DefaultLogDir'
        'Test-OutputDirectory'
        'New-OutputFilePath'
        'Write-UrlListToFile'
        'New-ProcessingResult'
        'Process-DirectoryEntry'
    )

    # Cmdlets to export from this module
    CmdletsToExport   = @()

    # Variables to export from this module
    VariablesToExport = @(
        'ScriptVersion'
        'ScriptName'
    )

    # Aliases to export from this module
    AliasesToExport   = @(
        'list-gen'
    )

    # List of all files packaged with this module
    FileList          = @(
        'list-gen.psm1'
        'lib/logging.ps1'
        'lib/network.ps1'
        'lib/url.ps1'
        'lib/input.ps1'
        'lib/output.ps1'
        'README.md'
        'LICENSE'
    )

    # Private data to pass to the module specified in RootModule
    PrivateData = @{
        PSData = @{
            Tags         = @('web', 'scraping', 'url', 'directory', 'download', 'pwsh', 'cli', 'automation')
            LicenseUri   = 'https://github.com/mytech-today-now/PowerShellScripts/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/mytech-today-now/PowerShellScripts/tree/main/URL-list-generator'
            ReleaseNotes = @'
## v3.1.0 - Parameter Alias Fix & Quality Improvements
- **Fixed**: Parameter alias conflict for `LogDir` (was `logdir`, now `ld`) in both CLI and programmatic API
- **Enhanced**: Consistent alias `ld` for `LogDir` across `Invoke-ListGenCLI` and `Invoke-ListGen`
- **Improved**: Input validation with stricter `ValidateNotNullOrEmpty` usage
- **Enhanced**: Error logging now correctly passes `Exception` objects (fixes Write-ErrorLog conversion error)
- **Added**: Environment variable `LIST_GEN_LOG_LEVEL` for default log level configuration
- **Improved**: Module version updated to 3.1.0 across all files
- **Enhanced**: Cross-platform path handling refinements
- **Fixed**: PSScriptAnalyzer warnings (unused parameters, naming consistency)

## v3.0.1 - Manifest Fix & Quality Improvements
- **Fixed**: Removed invalid `Platforms` manifest key causing import failure on PowerShell 7.0-7.1
- **Enhanced**: Explicit function exports in manifest for better control and documentation
- **Added**: `AliasToExport` for `list-gen` shortcut
- **Improved**: Parameter validation, error handling, and logging consistency across all functions
- **Added**: `WhatIf` and `Confirm` support to programmatic `Invoke-ListGen` function
- **Enhanced**: Cross-platform path handling with $IsWindows/$IsLinux/$IsMacOS automatic variables
- **Improved**: Output encoding defaults (UTF8NoBOM consistently)
- **Added**: Environment variable configuration support (LIST_GEN_*)
- **Fixed**: PSScriptAnalyzer warnings (unused parameters, naming, etc.)
- **Added**: Comprehensive inline documentation with .SYNOPSIS, .DESCRIPTION, .PARAMETER, .EXAMPLE

## v3.0.0 - Complete Rewrite (Security-First Architecture)
- **Security**: Eliminated all Invoke-Expression usage; bundled local logging module with optional secure download (SHA256 verification)
- **Architecture**: Transformed monolith into proper module with lib/ directory, module manifest, and thin entry point
- **TLS**: Added proper TLS validation and certificate pinning for all network calls
- **Parameters**: Full CmdletBinding with multiple parameter sets (Interactive, InputUrls, InputFile), -Help support
- **Error Handling**: Comprehensive try/catch, retry logic (3 attempts with exponential backoff), redirect following
- **Cross-Platform**: Uses $HOME / $env:XDG_* paths; works on Windows, Linux, macOS with PowerShell 7+
- **Logging**: Early initialization, structured JSONL output, log levels (DEBUG/INFO/WARN/ERROR), no swallowed exceptions
- **URL Handling**: Robust normalization using System.Uri (handles extensions, query strings, fragments, auto-HTTPS)
- **Output**: Pipeline-friendly PSCustomObject results, duplicate handling with millisecond timestamps/hashes
- **Validation**: Output directory writability checks, path validation, parameter validation attributes
- **Testing**: Pester test suite with unit and integration tests
- **Documentation**: Comprehensive README with installation, usage, examples, and architecture overview
'@
        }
    }
}