<#
.SYNOPSIS
    list-gen.exe - Professional URL List Generator CLI

.DESCRIPTION
    Command-line interface for the list-gen PowerShell module. Generates, crawls,
    validates, and exports URL lists with enterprise-grade features.

.NOTES
    Version:        4.0.0
    Author:         myTech.Today
    Repository:     https://github.com/mytech-today-now/URL-list-generator
    License:        MIT
    Requires:       PowerShell 5.1+

.PARAMETER Source
    Input source: URL, file path, 'sitemap:<url>', 'robots:<url>', 'clipboard', or 'stdin'

.PARAMETER Crawl
    Enable crawling mode (follow links recursively)

.PARAMETER MaxDepth
    Maximum crawl depth (default: 3)

.PARAMETER MaxUrls
    Maximum URLs to process (default: 1000)

.PARAMETER MaxConcurrent
    Maximum concurrent requests when crawling (default: 5)

.PARAMETER RateLimitMs
    Minimum delay between requests to same host in milliseconds (default: 100)

.PARAMETER Pattern
    Wildcard pattern to filter URLs (e.g., '*blog*', '*/api/*')

.PARAMETER RegexPattern
    Regex pattern to filter URLs

.PARAMETER ExcludePattern
    Pattern for URLs to exclude

.PARAMETER AllowedDomains
    Comma-separated list of allowed domains (default: same as start URLs)

.PARAMETER Format
    Output format: Csv, Json, Jsonl, Xml, Txt, Html, Sitemap, Excel, Markdown (default: Csv)

.PARAMETER OutputPath
    Output file path (default: stdout for Txt/Jsonl, ./urls.csv for others)

.PARAMETER Properties
    Comma-separated list of properties to export (default: all)

.PARAMETER Validate
    Validate URLs syntactically and optionally check reachability

.PARAMETER CheckReachability
    Perform HTTP HEAD request to verify URL reachability (implies -Validate)

.PARAMETER TimeoutSec
    HTTP request timeout in seconds (default: 30)

.PARAMETER UserAgent
    Custom User-Agent string

.PARAMETER Headers
    Additional HTTP headers as JSON string or hashtable

.PARAMETER LogLevel
    Logging level: Debug, Verbose, Info, Warning, Error, Critical (default: Info)

.PARAMETER LogFile
    Path to log file (enables file logging)

.PARAMETER NoColor
    Disable colored console output

.PARAMETER Progress
    Show progress bar during crawling

.PARAMETER Quiet
    Suppress non-error output

.PARAMETER WhatIf
    Show what would be done without executing

.PARAMETER Version
    Show version information and exit

.EXAMPLE
    # Generate URL list from a single page
    .\list-gen.ps1 -Source 'https://example.com' -OutputPath './urls.csv'

.EXAMPLE
    # Crawl a site with depth 2, max 500 URLs, filter for blog posts
    .\list-gen.ps1 -Source 'https://blog.example.com' -Crawl -MaxDepth 2 -MaxUrls 500 -Pattern '*blog*' -Format Json

.EXAMPLE
    # Process sitemap and export as sitemap.xml
    .\list-gen.ps1 -Source 'sitemap:https://example.com/sitemap.xml' -Format Sitemap -OutputPath './sitemap.xml'

.EXAMPLE
    # Read URLs from file, validate reachability, export to JSONL
    .\list-gen.ps1 -Source './input-urls.txt' -CheckReachability -Format Jsonl -OutputPath './validated.jsonl'

.EXAMPLE
    # Crawl with custom headers and rate limiting
    .\list-gen.ps1 -Source 'https://api.example.com' -Crawl -MaxConcurrent 3 -RateLimitMs 500 -Headers '{"Authorization":"Bearer token"}' -OutputPath './api-urls.json'

.EXAMPLE
    # Pipeline usage
    Get-Content urls.txt | .\list-gen.ps1 -Source stdin -Crawl -MaxDepth 1 -Format Csv -OutputPath ./results.csv
#>

[CmdletBinding(DefaultParameterSetName='Default', SupportsShouldProcess=$true)]
param(
    # Input
    [Parameter(Mandatory=$true, Position=0, ParameterSetName='Default')]
    [Parameter(Mandatory=$true, Position=0, ParameterSetName='Crawl')]
    [Parameter(Mandatory=$true, Position=0, ParameterSetName='Validate')]
    [string]$Source,

    [Parameter(ParameterSetName='Crawl')]
    [switch]$Crawl,

    # Crawl settings
    [Parameter(ParameterSetName='Crawl')]
    [ValidateRange(0, 20)]
    [int]$MaxDepth = 3,

    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName='Crawl')]
    [Parameter(ParameterSetName='Validate')]
    [ValidateRange(1, 1000000)]
    [int]$MaxUrls = 1000,

    [Parameter(ParameterSetName='Crawl')]
    [ValidateRange(1, 50)]
    [int]$MaxConcurrent = 5,

    [Parameter(ParameterSetName='Crawl')]
    [ValidateRange(0, 10000)]
    [int]$RateLimitMs = 100,

    # Filtering
    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName='Crawl')]
    [Parameter(ParameterSetName='Validate')]
    [string]$Pattern,

    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName='Crawl')]
    [Parameter(ParameterSetName='Validate')]
    [string]$RegexPattern,

    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName='Crawl')]
    [Parameter(ParameterSetName='Validate')]
    [string]$ExcludePattern,

    [Parameter(ParameterSetName='Crawl')]
    [string]$AllowedDomains,

    # Output
    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName='Crawl')]
    [Parameter(ParameterSetName='Validate')]
    [ValidateSet('Csv','Json','Jsonl','Xml','Txt','Html','Sitemap','Excel','Markdown')]
    [string]$Format = 'Csv',

    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName='Crawl')]
    [Parameter(ParameterSetName='Validate')]
    [string]$OutputPath,

    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName='Crawl')]
    [Parameter(ParameterSetName='Validate')]
    [string]$Properties = '*',

    # Validation
    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName='Crawl')]
    [Parameter(ParameterSetName='Validate')]
    [switch]$Validate = $true,

    [Parameter(ParameterSetName='Validate')]
    [switch]$CheckReachability,

    # Network
    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName='Crawl')]
    [Parameter(ParameterSetName='Validate')]
    [ValidateRange(1, 300)]
    [int]$TimeoutSec = 30,

    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName='Crawl')]
    [Parameter(ParameterSetName='Validate')]
    [string]$UserAgent = 'list-gen/4.0.0',

    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName='Crawl')]
    [Parameter(ParameterSetName='Validate')]
    [string]$Headers = '{}',

    # Logging
    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName='Crawl')]
    [Parameter(ParameterSetName='Validate')]
    [ValidateSet('Debug','Verbose','Info','Warning','Error','Critical')]
    [string]$LogLevel = 'Info',

    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName='Crawl')]
    [Parameter(ParameterSetName='Validate')]
    [string]$LogFile,

    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName='Crawl')]
    [Parameter(ParameterSetName='Validate')]
    [switch]$NoColor,

    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName='Crawl')]
    [Parameter(ParameterSetName='Validate')]
    [switch]$Progress,

    [Parameter(ParameterSetName='Default')]
    [Parameter(ParameterSetName='Crawl')]
    [Parameter(ParameterSetName='Validate')]
    [switch]$Quiet,

    # Common
    [switch]$Version
)

# Show version and exit
if ($Version) {
    Write-Host "list-gen v4.0.0"
    Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
    Write-Host "Edition: $($PSVersionTable.PSEdition)"
    Write-Host "Repository: https://github.com/mytech-today-now/URL-list-generator"
    exit 0
}

# Import the module
$modulePath = Join-Path $PSScriptRoot 'list-gen.psd1'
if (-not (Test-Path $modulePath)) {
    throw "Module manifest not found: $modulePath. Run from the module root directory."
}

try {
    Import-Module $modulePath -Force -ErrorAction Stop
}
catch {
    Write-Error "Failed to import list-gen module: $($_.Exception.Message)"
    exit 1
}

# Configure logging
$logParams = @{ Level = $LogLevel; EnableColors = -not $NoColor }
if ($LogFile) {
    $logParams.EnableFile = $true
    $logParams.FilePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogFile)
}
Set-LogConfig @logParams

Log-Info -Message "Starting list-gen v4.0.0 - Source: $Source, Crawl: $Crawl, Format: $Format" -Category 'Main'

# Parse headers
$parsedHeaders = @{}
try {
    if ($Headers -match '^\s*\{') {
        $parsedHeaders = $Headers | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    else {
        $parsedHeaders = ConvertFrom-StringData -StringData $Headers -ErrorAction Stop
    }
}
catch {
    Log-Warning -Message "Failed to parse headers: {0}. Using empty headers." -Args $_.Exception.Message -Category 'Main'
}

# Parse allowed domains
$allowedDomainsList = if ($AllowedDomains) { $AllowedDomains -split ',' | ForEach-Object { $_.Trim() } } else { @() }

# Parse properties
$propList = if ($Properties -eq '*') { @('*') } else { $Properties -split ',' | ForEach-Object { $_.Trim() } }

# Determine output path
if (-not $OutputPath) {
    $OutputPath = switch ($Format) {
        'Txt'      { '' }  # stdout
        'Jsonl'    { '' }  # stdout
        'Sitemap'  { 'sitemap.xml' }
        default    { "urls.$($Format.ToLower())" }
    }
}
elseif ($OutputPath -ne '') {
    $OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
}

# Progress tracking
$processedCount = 0
$startTime = Get-Date

$progressAction = if ($Progress -and -not $Quiet) {
    {
        param($Current, $Total, $Url, $Depth)
        $percent = if ($Total -gt 0) { [Math]::Min(100, [int]($Current / $Total * 100)) } else { 0 }
        $elapsed = (Get-Date) - $startTime
        $status = "Processed: $Current | Depth: $Depth | Elapsed: $($elapsed.ToString('hh\:mm\:ss'))"
        Write-Progress -Activity 'list-gen' -Status $status -PercentComplete $percent -CurrentOperation $Url
    }
} else { $null }

$discoveredAction = if (-not $Quiet) {
    {
        param($Url, $Depth, $SourceUrl)
        if ($Depth -le 1) {  # Only log first level discoveries verbosely
            Log-Verbose -Message "Discovered: {0} (depth {1}, from {2})" -Args $Url, $Depth, $SourceUrl -Category 'Crawl'
        }
    }
} else { $null }

try {
    $results = @()

    if ($Crawl -or $PSCmdlet.ParameterSetName -eq 'Crawl') {
        # Crawl mode
        Log-Info -Message "Crawl mode: MaxDepth=$MaxDepth, MaxUrls=$MaxUrls, MaxConcurrent=$MaxConcurrent, RateLimit=$RateLimitMs ms" -Category 'Crawl'

        $results = Invoke-UrlCrawl -StartUrl @($Source) -MaxDepth $MaxDepth -MaxUrls $MaxUrls `
            -MaxConcurrent $MaxConcurrent -RateLimitMs $RateLimitMs -Pattern $Pattern `
            -RegexPattern $RegexPattern -ExcludePattern $ExcludePattern -AllowedDomains $allowedDomainsList `
            -TimeoutSec $TimeoutSec -UserAgent $UserAgent -Headers $parsedHeaders `
            -OnProgress $progressAction -OnUrlDiscovered $discoveredAction

        # Apply post-crawl filtering if needed
        if ($Pattern -or $RegexPattern -or $ExcludePattern) {
            $results = $results | Select-UrlPattern -Pattern $Pattern -Regex:$([bool]$RegexPattern) |
                Where-Object { -not ($ExcludePattern -and $_ -like $ExcludePattern) }
        }
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Validate') {
        # Validation mode
        Log-Info -Message "Validation mode: CheckReachability=$CheckReachability" -Category 'Validate'

        $inputUrls = Get-UrlInput -Source $Source -MaxUrls $MaxUrls -Validate:$false
        $validUrls = $inputUrls | Where-Object { $_.IsValid } | Select-Object -ExpandProperty Url

        $results = $validUrls | ForEach-Object {
            Test-UrlValid -Url $_ -CheckReachability:$CheckReachability -TimeoutSec $TimeoutSec -AllowedSchemes @('http','https')
        } | Where-Object { $_.IsValid } | Select-Object -ExpandProperty Url
    }
    else {
        # Default: extract from source
        Log-Info -Message "Extraction mode" -Category 'Extract'

        $inputResults = Get-UrlInput -Source $Source -MaxUrls $MaxUrls -Validate:$Validate

        # Filter valid URLs
        $validInput = $inputResults | Where-Object { $_.IsValid }
        $results = $validInput | Select-Object -ExpandProperty Url

        # Apply pattern filters
        if ($Pattern -or $RegexPattern -or $ExcludePattern) {
            $results = $results | Select-UrlPattern -Pattern $Pattern -Regex:$([bool]$RegexPattern) |
                Where-Object { -not ($ExcludePattern -and $_ -like $ExcludePattern) }
        }

        # If source is a single URL and not a file/sitemap, also extract from the page
        if ($Source -match '^https?://' -and $Source -notlike 'sitemap:*' -and $Source -notlike 'robots:*') {
            Log-Verbose -Message "Fetching page content for link extraction: {0}" -Args $Source -Category 'Extract'
            $html = Invoke-WebRequestSafe -Url $Source -TimeoutSec $TimeoutSec
            if ($html) {
                $extracted = Extract-UrlsFromHtml -Html $html -BaseUrl $Source -ResolveRelative
                $extractedUrls = $extracted | Select-Object -ExpandProperty Url

                # Apply same filters
                if ($Pattern -or $RegexPattern -or $ExcludePattern) {
                    $extractedUrls = $extractedUrls | Select-UrlPattern -Pattern $Pattern -Regex:$([bool]$RegexPattern) |
                        Where-Object { -not ($ExcludePattern -and $_ -like $ExcludePattern) }
                }

                $results += $extractedUrls
                $results = $results | Select-Object -Unique
            }
        }
    }

    # Limit results
    if ($MaxUrls -gt 0 -and $results.Count -gt $MaxUrls) {
        $results = $results[0..($MaxUrls-1)]
    }

    Log-Info -Message "Processing complete: {0} URLs" -Args $results.Count -Category 'Main'

    # Export results
    if ($results.Count -gt 0) {
        if ($Format -in @('Txt', 'Jsonl') -and -not $OutputPath) {
            # Stream to stdout
            foreach ($url in $results) {
                if ($Format -eq 'Jsonl') {
                    [pscustomobject]@{ Url = $url; Timestamp = (Get-Date).ToString('o') } | ConvertTo-Json -Compress | Write-Host
                }
                else {
                    Write-Host $url
                }
            }
        }
        else {
            $exportParams = @{
                InputObject = $results
                Format      = $Format
                Properties  = $propList
            }
            if ($OutputPath) { $exportParams.Path = $OutputPath }
            Export-UrlList @exportParams
        }
    }
    else {
        Log-Warning -Message "No URLs found matching criteria" -Category 'Main'
        if (-not $Quiet) { Write-Warning "No URLs found matching criteria" }
    }

    if ($Progress) { Write-Progress -Activity 'list-gen' -Completed -Status 'Complete' }

    exit 0
}
catch {
    Log-Error -Message "Fatal error: {0}" -Args $_.Exception.Message -Exception $_ -Category 'Main'
    if ($Progress) { Write-Progress -Activity 'list-gen' -Completed -Status 'Error' }
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    # Cleanup HttpClient if used
    if ($script:HttpClient) {
        $script:HttpClient.Dispose()
        $script:HttpClient = $null
    }
}