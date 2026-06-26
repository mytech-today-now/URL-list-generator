@{
    # Module manifest for 'list-gen'
    RootModule        = 'list-gen.psm1'
    ModuleVersion     = '4.0.0'
    GUID              = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author            = 'myTech.Today'
    CompanyName       = 'myTech.Today'
    Copyright         = '(c) 2024 myTech.Today. All rights reserved.'
    Description       = 'Production-ready URL list generator with robust HTML parsing, crawling, and export capabilities.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')


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

    # Functions to export from this module
    FunctionsToExport = @(
        'Get-UrlList',
        'Invoke-UrlCrawl',
        'Export-UrlList',
        'ConvertTo-AbsoluteUrl',
        'Test-UrlValid',
        'Select-UrlPattern'
    )

    # Cmdlets to export from this module
    CmdletsToExport   = @()

    # Variables to export from this module
    VariablesToExport = @()

    # Aliases to export from this module
    AliasesToExport   = @(
        'gurl',
        'icur',
        'eurl'
    )

    # Private data to pass to the module specified in RootModule/ModuleToProcess
    PrivateData = @{
        PSData = @{
            Tags         = @('url', 'crawler', 'scraper', 'html', 'seo', 'sitemap')
            LicenseUri   = 'https://opensource.org/licenses/MIT'
            ProjectUri   = 'https://github.com/mytech-today-now/URL-list-generator'
            ReleaseNotes = 'v4.0.0 - Complete rewrite with robust regex, cross-platform support, and production hardening'
        }
    }

    # HelpInfo URI for online help
    HelpInfoUri       = 'https://github.com/mytech-today-now/URL-list-generator/blob/main/docs/help.md'

    # Default command prefix
    DefaultCommandPrefix = ''
}