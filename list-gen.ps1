<#
.SYNOPSIS
    list-gen v3.0.1 - Web Directory URL List Generator

.DESCRIPTION
    Extracts file URLs from web directory listings and generates text files
    containing the full URLs of all files found. Supports multiple input sources,
    comprehensive logging, cross-platform operation, and enterprise-grade security.

.NOTES
    Author: myTech.Today
    Version: 3.0.1
    Requires: PowerShell 7.0+
    Module: list-gen (installed or local)
#>

#requires -Version 7.0
Set-StrictMode -Version Latest

# Script metadata
$ScriptVersion = '3.0.1'
$ScriptName    = 'list-gen'

# Ensure module is available
$modulePath = Split-Path $PSCommandPath -Parent
$moduleManifest = Join-Path $modulePath 'list-gen.psd1'

if (-not (Test-Path $moduleManifest)) {
    Write-Error "Module manifest not found: $moduleManifest"
    exit 1
}

# Import the module (loads all nested modules)
try {
    Import-Module -Name $moduleManifest -ErrorAction Stop -DisableNameChecking
}
catch {
    Write-Error "Failed to import list-gen module: $($_.Exception.Message)"
    exit 1
}

<#
.SYNOPSIS
    Command-line interface for list-gen module.

.DESCRIPTION
    Processes directory URLs from multiple input sources and generates
    file URL lists. Supports direct URLs, input files, and interactive input.

.PARAMETER Url
    One or more directory URLs to process (positional, remaining arguments).

.PARAMETER InputFile
    Path to file containing URLs to process. Supports .txt, .md, .rtf, .json.

.PARAMETER Interactive
    Run in interactive mode, prompting for URLs.

.PARAMETER OutputDir
    Output directory for generated files. Default: ~/Downloads.

.PARAMETER LogDir
    Log directory. Default: platform-appropriate location.

.PARAMETER LogLevel
    Minimum log level. Default: INFO.

.PARAMETER TimeoutSec
    Request timeout in seconds. Default: 60.

.PARAMETER MaxRetries
    Maximum retry attempts for failed requests. Default: 3.

.PARAMETER NoRedirects
    Disable following HTTP redirects.

.PARAMETER NoCertificateValidation
    Disable TLS certificate validation. NOT recommended for production.

.PARAMETER CertificatePins
    Array of SPKI SHA256 base64 hashes for certificate pinning.

.PARAMETER WhatIf
    Show what would be done without executing.

.PARAMETER Confirm
    Prompt for confirmation before processing.

.PARAMETER Help
    Show full help and exit.

.INPUTS
    None. Pipeline input not supported for CLI.

.OUTPUTS
    Exit code: 0 = success, 1 = failure.

.EXAMPLE
    list-gen https://example.com/files/ https://example.org/data/

.EXAMPLE
    list-gen -InputFile urls.txt -OutputDir ~/output -LogLevel DEBUG

.EXAMPLE
    list-gen -Interactive

.EXAMPLE
    list-gen https://example.com/ -WhatIf

.EXAMPLE
    list-gen -InputFile urls.json -CertificatePins @('sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')
#>
function Invoke-ListGenCLI {
    [CmdletBinding(
        DefaultParameterSetName = 'Interactive',
        SupportsShouldProcess = $true,
        ConfirmImpact = 'Medium',
        HelpUri = 'https://github.com/mytech-today-now/PowerShellScripts/tree/main/URL-list-generator'
    )]
    param(
        # Parameter Set: URLs (direct URL arguments)
        [Parameter(ParameterSetName = 'Urls', Position = 0, ValueFromRemainingArguments = $true)]
        [ValidateNotNull()]
        [string[]]$Url,

        # Parameter Set: InputFile
        [Parameter(ParameterSetName = 'InputFile', Mandatory = $true)]
        [Alias('i', 'file')]
        [ValidateNotNullOrEmpty()]
        [string]$InputFile,

        # Parameter Set: Interactive (default)
        [Parameter(ParameterSetName = 'Interactive')]
        [Alias('int')]
        [switch]$Interactive,

        # Common parameters
        [Parameter()]
        [Alias('o', 'out')]
        [ValidateNotNullOrEmpty()]
        [string]$OutputDir,

        [Parameter()]
        [Alias('logdir')]
        [ValidateNotNullOrEmpty()]
        [string]$LogDir,

        [Parameter()]
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string]$LogLevel = 'INFO',

        [Parameter()]
        [ValidateRange(1, 300)]
        [int]$TimeoutSec = 60,

        [Parameter()]
        [ValidateRange(0, 10)]
        [int]$MaxRetries = 3,

        [Parameter()]
        [switch]$NoRedirects,

        [Parameter()]
        [switch]$NoCertificateValidation,

        [Parameter()]
        [ValidateNotNull()]
        [string[]]$CertificatePins,

        [Parameter()]
        [switch]$WhatIf,

        [Parameter()]
        [switch]$Confirm,

        # Help - triggers Get-Help
        [Parameter()]
        [Alias('?')]
        [switch]$Help
    )

    # Show help if requested
    if ($Help) {
        Get-Help -Name $PSCommandPath -Full
        return 0
    }

    # Resolve defaults
    if (-not $OutputDir) { $OutputDir = Get-DefaultOutputDir }
    if (-not $LogDir) { $LogDir = Get-DefaultLogDir }

    # Initialize logging
    $logFile = Join-Path $LogDir "list-gen_$(Get-Date -Format 'yyyy-MM').jsonl"
    Initialize-Log -LogPath $logFile -ScriptName $ScriptName -ScriptVersion $ScriptVersion -MinLevel $LogLevel

    Write-InfoLog -Message "=== $ScriptName v$ScriptVersion started ===" -Context @{
        parameterSet = $PSCmdlet.ParameterSetName
        urls         = $Url
        inputFile    = $InputFile
        interactive  = $Interactive
        outputDir    = $OutputDir
        logDir       = $LogDir
        logLevel     = $LogLevel
        timeoutSec   = $TimeoutSec
        maxRetries   = $MaxRetries
        noRedirects  = $NoRedirects
        noCertVal    = $NoCertificateValidation
        certPins     = $CertificatePins
        whatIf       = $WhatIf
        confirm      = $Confirm
        pid          = $PID
    }

    # Validate output directory
    $dirTest = Test-OutputDirectory -Path $OutputDir -CreateIfMissing $true
    if (-not $dirTest.Valid) {
        Write-ErrorLog -Message "Output directory validation failed" -Context @{ path = $OutputDir; error = $dirTest.Error }
        Write-Error "Output directory error: $($dirTest.Error)"
        return 1
    }

    # Build network params
    $networkParams = @{
        TimeoutSec          = $TimeoutSec
        MaxRetries          = $MaxRetries
        FollowRedirects     = -not $NoRedirects
        ValidateCertificate = -not $NoCertificateValidation
        CertificatePins     = $CertificatePins
    }

    # Warn if certificate validation disabled
    if ($NoCertificateValidation) {
        Write-WarnLog -Message "Certificate validation DISABLED via -NoCertificateValidation. NOT recommended for production!"
    }

    # Gather entries
    $entries = @()

    switch ($PSCmdlet.ParameterSetName) {
        'InputFile' {
            Write-Host "Reading URLs from file: $InputFile" -ForegroundColor Cyan
            try {
                $entries = Parse-InputFile -FilePath $InputFile
            }
            catch {
                Write-Error "Failed to parse input file: $($_.Exception.Message)"
                return 1
            }
        }

        'Urls' {
            Write-DebugLog -Message "Processing command-line URLs" -Context @{ count = $Url.Count }
            $entries = Parse-CommandLineEntries -Args $Url
        }

        'Interactive' {
            $entries = Parse-InteractiveInput -Prompt 'URL or file path'
        }
    }

    if ($entries.Count -eq 0) {
        Write-Host "No valid entries provided." -ForegroundColor Yellow
        Write-WarnLog -Message "No entries to process"
        return 0
    }

    Write-Host ""
    Write-Host "Total entries: $($entries.Count)" -ForegroundColor Green
    Write-Host "Output directory: $OutputDir" -ForegroundColor Cyan
    Write-Host "Log file: $logFile" -ForegroundColor Cyan
    Write-Host ""

    # Normalize/validate entries
    $normalizedEntries = Validate-AndNormalizeEntries -Entries $entries -AssumeHttps $true

    if ($normalizedEntries.Count -eq 0) {
        Write-Host "No valid URLs after normalization." -ForegroundColor Yellow
        Write-WarnLog -Message "No valid entries after normalization"
        return 0
    }

    # WhatIf preview
    if ($WhatIf) {
        Write-Host "WhatIf: Would process $($normalizedEntries.Count) directory URLs:" -ForegroundColor Yellow
        foreach ($entry in $normalizedEntries) {
            Write-Host "  - $($entry.AbsoluteUri)"
        }
        return 0
    }

    # Confirm if requested
    if ($Confirm) {
        $choice = Read-Host "Process $($normalizedEntries.Count) entries? [Y/N]"
        if ($choice -notin @('y', 'Y', 'yes', 'YES')) {
            Write-Host "Cancelled." -ForegroundColor Yellow
            return 0
        }
    }

    # Process each entry
    $results = @()
    $successCount = 0
    $failCount = 0

    for ($i = 0; $i -lt $normalizedEntries.Count; $i++) {
        $entry = $normalizedEntries[$i]
        $entryNum = $i + 1

        Write-Host "[$entryNum/$($normalizedEntries.Count)] Processing: $($entry.AbsoluteUri)" -ForegroundColor Cyan

        if ($PSCmdlet.ShouldProcess($entry.AbsoluteUri, 'Extract file URLs and generate output file')) {
            $result = Process-DirectoryEntry -Entry $entry.AbsoluteUri -OutputDir $OutputDir -NetworkParams $networkParams
            $results += $result

            if ($result.Success) {
                $successCount++
                if ($result.FileCount -gt 0) {
                    Write-Host "  [OK] Found $($result.FileCount) files -> $($result.OutputFile)" -ForegroundColor Green
                }
                else {
                    Write-Host "  [OK] No files found in directory" -ForegroundColor Yellow
                }
            }
            else {
                $failCount++
                Write-Host "  [FAIL] $($result.Error)" -ForegroundColor Red
            }
        }
        else {
            Write-Host "  [SKIPPED]" -ForegroundColor Yellow
        }
    }

    # Summary
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  Processing Complete" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  Successful: $successCount" -ForegroundColor Green
    Write-Host "  Failed:     $failCount" -ForegroundColor Red
    Write-Host "  Total:      $($normalizedEntries.Count)" -ForegroundColor Cyan
    Write-Host ""

    if ($successCount -gt 0) {
        Write-Host "Output files saved to: $OutputDir" -ForegroundColor Green
    }

    Write-InfoLog -Message "=== $ScriptName completed ===" -Context @{
        success = $successCount
        failed  = $failCount
        total   = $normalizedEntries.Count
    }

    return if ($failCount -gt 0) { 1 } else { 0 }
}

# Entry point
try {
    $exitCode = Invoke-ListGenCLI @args
    exit $exitCode
}
catch {
    Write-Error "Fatal error: $($_.Exception.Message)"
    Write-ErrorLog -Message "Fatal error in entry point" -Context @{ error = $_.Exception.Message; stackTrace = $_.ScriptStackTrace } -Exception $_
    exit 1
}