<#
.SYNOPSIS
    list-gen - Professional URL List Generator Module

.DESCRIPTION
    A production-ready PowerShell module for generating, crawling, and processing URL lists.
    Features robust HTML parsing, configurable crawling, multiple export formats, and
    comprehensive error handling. Compatible with PowerShell 5.1+ and PowerShell 7+.

.NOTES
    Version:        4.0.0
    Author:         myTech.Today
    Repository:     https://github.com/mytech-today-now/URL-list-generator
    License:        MIT
    Requires:       PowerShell 5.1+

.COMPONENT
    lib/url.ps1         - URL parsing, normalization, and regex patterns
    lib/input.ps1       - Input handling and source processing
    lib/network.ps1     - HTTP requests and crawling logic
    lib/output.ps1      - Export and formatting functions
    lib/logging.ps1     - Structured logging infrastructure

.EXAMPLE
    Import-Module ./list-gen.psd1
    Get-UrlList -Source 'https://example.com' -MaxDepth 2 | Export-UrlList -Format Csv -Path './urls.csv'

.EXAMPLE
    Invoke-UrlCrawl -StartUrl 'https://docs.microsoft.com' -Pattern '*powershell*' -MaxUrls 500
#>

#requires -Version 5.1
#requires -Modules @{ ModuleName = 'Microsoft.PowerShell.Utility'; ModuleVersion = '3.1' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Module-scoped configuration
$script:ModuleConfig = @{
    DefaultTimeoutSec     = 30
    DefaultMaxDepth       = 3
    DefaultMaxUrls        = 1000
    DefaultUserAgent      = 'list-gen/4.0.0 (+https://github.com/mytech-today-now/URL-list-generator)'
    DefaultRateLimitMs    = 100
    MaxConcurrentRequests = 5
    Encoding              = [System.Text.Encoding]::UTF8
}

# Import all library files
$libPath = Join-Path $PSScriptRoot 'lib'
$libFiles = @(
    'logging.ps1',    # Load first - other modules depend on it
    'url.ps1',        # Core URL parsing - no dependencies
    'input.ps1',      # Input processing
    'network.ps1',    # Network operations - depends on url, logging
    'output.ps1'      # Output formatting - depends on url, logging
)

foreach ($file in $libFiles) {
    $fullPath = Join-Path $libPath $file
    if (Test-Path $fullPath) {
        try {
            . $fullPath
            Write-Verbose "Loaded library: $file"
        }
        catch {
            Throw "Failed to load library '$file': $($_.Exception.Message)"
        }
    }
    else {
        Write-Warning "Library file not found: $fullPath"
    }
}

# Export public functions
Export-ModuleMember -Function @(
    'Get-UrlList',
    'Invoke-UrlCrawl',
    'Export-UrlList',
    'ConvertTo-AbsoluteUrl',
    'Test-UrlValid',
    'Select-UrlPattern'
) -Alias @(
    'gurl',
    'icur',
    'eurl'
)

# Module initialization
Write-Verbose "list-gen module v4.0.0 loaded successfully"