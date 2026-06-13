<#
.SYNOPSIS
    list-gen v3.2.0 - Web Directory URL List Generator

.DESCRIPTION
    Extracts file URLs from web directory listings and generates text files
    containing the full URLs of all files found. Supports multiple input sources,
    comprehensive logging, cross-platform operation, and enterprise-grade security.

    This script is the CLI entry point for the list-gen module. It imports the
    module (which loads all nested modules: logging, network, url, input, output)
    and invokes the Invoke-ListGenCLI function with the provided arguments.

.NOTES
    Author:       myTech.Today
    Version:      3.2.0
    Requires:     PowerShell 7.0+
    Module:       list-gen (installed or local)
    Repository:   https://github.com/mytech-today-now/PowerShellScripts/tree/main/URL-list-generator
    License:      MIT

.COMPONENT
    list-gen.ps1 - CLI entry point
    list-gen.psd1 - Module manifest
    lib/logging.ps1 - Structured JSONL logging
    lib/network.ps1 - HTTP client with retry, TLS, cert pinning
    lib/url.ps1 - URL normalization and extraction
    lib/input.ps1 - Input parsing (files, CLI, interactive)
    lib/output.ps1 - Output file generation and directory management

.LINK
    https://github.com/mytech-today-now/PowerShellScripts/tree/main/URL-list-generator
    https://github.com/mytech-today-now/PowerShellScripts/blob/main/LICENSE
#>

#requires -Version 7.0

# ─── PSScriptAnalyzer Suppressions ──────────────────────────────────────────────
# The following suppress legitimate warnings for design reasons:
# PSUseShouldProcessForStateChangingFunctions: The Invoke-ListGenCLI function
#   implements its own confirmation logic via -WhatIf/-Confirm parameters and
#   explicit ShouldProcess calls per-item. The function-level SupportsShouldProcess
#   enables automatic common parameter binding.
#   Suppress with: #pragma PSUseShouldProcessForStateChangingFunctions
#pragma warning disable PSUseShouldProcessForStateChangingFunctions
#pragma warning disable PSUseDeclaredVarsMoreThanAssignments

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Script Metadata ────────────────────────────────────────────────────────────
$ScriptVersion = '3.2.0'
$ScriptName    = 'list-gen'

# ─── Module Resolution & Import ─────────────────────────────────────────────────
# Resolve the module root directory - works whether script is called directly,
# via alias, or from a different working directory.
$ScriptDir = (Get-Item -LiteralPath $PSCommandPath).DirectoryName
$ModuleManifest = Join-Path $ScriptDir 'list-gen.psd1'

if (-not (Test-Path -LiteralPath $ModuleManifest)) {
    Write-Error -Message "Module manifest not found: $ModuleManifest" -ErrorAction Stop
    exit 3
}

try {
    # Import with -Force to allow re-import during development; -DisableNameChecking
    # avoids noise from the nested module functions we intentionally export.
    Import-Module -Name $ModuleManifest -ErrorAction Stop -DisableNameChecking -Force
}
catch {
    Write-Error -Message "Failed to import list-gen module: $($_.Exception.Message)" -ErrorAction Stop
    exit 1
}

# ─── CLI FUNCTION: Invoke-ListGenCLI ────────────────────────────────────────────
<#
.SYNOPSIS
    Command-line interface for list-gen module.

.DESCRIPTION
    Processes directory URLs from multiple input sources and generates
    file URL lists. Supports direct URLs, input files, and interactive input.

.PARAMETER Url
    One or more directory URLs to process (positional, remaining arguments).
    Accepts pipeline input for InputObject-style usage.

.PARAMETER InputFile
    Path to file containing URLs to process. Supports .txt, .md, .rtf, .json.

.PARAMETER Interactive
    Run in interactive mode, prompting for URLs.

.PARAMETER OutputDir
    Output directory for generated files. Default: ~/Downloads.
    Environment variable: LIST_GEN_OUTPUT_DIR

.PARAMETER LogDir
    Log directory. Default: platform-appropriate location.
    Alias: ld
    Environment variable: LIST_GEN_LOG_DIR

.PARAMETER LogLevel
    Minimum log level. Default: INFO.
    Environment variable: LIST_GEN_LOG_LEVEL

.PARAMETER TimeoutSec
    Request timeout in seconds. Default: 60.
    Environment variable: LIST_GEN_TIMEOUT_SEC

.PARAMETER MaxRetries
    Maximum retry attempts for failed requests. Default: 3.
    Environment variable: LIST_GEN_MAX_RETRIES

.PARAMETER NoRedirects
    Disable following HTTP redirects.

.PARAMETER NoCertificateValidation
    Disable TLS certificate validation. NOT recommended for production.

.PARAMETER CertificatePins
    Array of SPKI SHA256 base64 hashes for certificate pinning.
    Format: 'sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='

.PARAMETER Help
    Show full help and exit.

.INPUTS
    System.String[]. Pipeline input binds to the Url parameter.

.OUTPUTS
    Exit code: 0 = success, 1 = partial failure, 2 = usage/help, 3 = validation error.

.EXAMPLE
    list-gen https://example.com/files/ https://example.org/data/
    # Process two directory URLs directly

.EXAMPLE
    list-gen -InputFile urls.txt -OutputDir ~/output -LogLevel DEBUG
    # Read URLs from file, custom output and log level

.EXAMPLE
    list-gen -Interactive
    # Interactive mode - prompts for URLs

.EXAMPLE
    list-gen https://example.com/ -WhatIf
    # Preview what would be processed without executing

.EXAMPLE
    'https://site1.com/', 'https://site2.com/' | list-gen
    # Pipeline input

.EXAMPLE
    list-gen -InputFile urls.json -CertificatePins @('sha256/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')
    # With certificate pinning
#>
function Invoke-ListGenCLI {
    [CmdletBinding(
        DefaultParameterSetName = 'Interactive',
        SupportsShouldProcess     = $true,
        ConfirmImpact             = 'Medium',
        HelpUri                   = 'https://github.com/mytech-today-now/PowerShellScripts/tree/main/URL-list-generator'
    )]
    param(
        # Parameter Set: URLs (direct URL arguments)
        [Parameter(
            ParameterSetName = 'Urls',
            Position         = 0,
            ValueFromRemainingArguments = $true,
            ValueFromPipeline = $true
        )]
        [ValidateNotNull()]
        [ValidateScript({
            if ($_ -is [string] -and $_ -match '^https?://') { $true }
            else { throw "URL must start with http:// or https://: $_" }
        })]
        [string[]]$Url,

        # Parameter Set: InputFile
        [Parameter(
            ParameterSetName = 'InputFile',
            Mandatory = $true
        )]
        [Alias('i', 'file')]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$InputFile,

        # Parameter Set: Interactive (default)
        [Parameter(ParameterSetName = 'Interactive')]
        [Alias('int')]
        [switch]$Interactive,

        # Common parameters
        [Parameter()]
        [Alias('o', 'out')]
        [ValidateNotNull()]
        [string]$OutputDir = '',

        [Parameter()]
        [Alias('ld')]
        [ValidateNotNull()]
        [string]$LogDir = '',

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

        # Help - triggers Get-Help
        [Parameter()]
        [Alias('?')]
        [switch]$ShowHelp
    )

    # Show help if requested
    if ($ShowHelp) {
        Get-Help -Name 'Invoke-ListGenCLI' -Full
        return 2  # Usage exit code
    }

    # Resolve defaults with environment variable fallbacks
    # Use helper to treat empty string as unset for fallback purposes
    function Resolve-Default($value, $envVar, $default) {
        if ($null -ne $value -and $value -ne '') { return $value }
        if ($null -ne $envVar -and $envVar -ne '') { return $envVar }
        return $default
    }

    $OutputDir = Resolve-Default $OutputDir $env:LIST_GEN_OUTPUT_DIR (Get-DefaultOutputDir)
    $LogDir    = Resolve-Default $LogDir    $env:LIST_GEN_LOG_DIR    (Get-DefaultLogDir)
    $LogLevel  = Resolve-Default $LogLevel  $env:LIST_GEN_LOG_LEVEL  'INFO'
    $TimeoutSec = Resolve-Default $TimeoutSec $env:LIST_GEN_TIMEOUT_SEC 60
    $MaxRetries = Resolve-Default $MaxRetries $env:LIST_GEN_MAX_RETRIES 3

    # Initialize logging
    $logFile = Join-Path $LogDir "list-gen_$(Get-Date -Format 'yyyy-MM').jsonl"
    Initialize-Log -LogPath $logFile -ScriptName $ScriptName -ScriptVersion $ScriptVersion -MinLevel $LogLevel

    Write-InfoLog -Message "=== $ScriptName v$ScriptVersion started ===" -Context @{
        parameterSet   = $PSCmdlet.ParameterSetName
        urls           = $Url
        inputFile      = $InputFile
        interactive    = $Interactive
        outputDir      = $OutputDir
        logDir         = $LogDir
        logLevel       = $LogLevel
        timeoutSec     = $TimeoutSec
        maxRetries     = $MaxRetries
        noRedirects    = $NoRedirects
        noCertVal      = $NoCertificateValidation
        certPins       = $CertificatePins
        whatIf         = $PSBoundParameters.ContainsKey('WhatIf')
        confirm        = $PSBoundParameters.ContainsKey('Confirm')
        pid            = $PID
        psVersion      = $PSVersionTable.PSVersion.ToString()
        os             = $PSVersionTable.OS
    }

    # Validate output directory
    $dirTest = Test-OutputDirectory -Path $OutputDir -CreateIfMissing $true
    if (-not $dirTest.Valid) {
        Write-ErrorLog -Message "Output directory validation failed" -Context @{ path = $OutputDir; error = $dirTest.Error }
        Write-Error -Message "Output directory error: $($dirTest.Error)"
        return 3
    }

    # Build network parameters hashtable for downstream functions
    $networkParams = @{
        TimeoutSec          = $TimeoutSec
        MaxRetries          = $MaxRetries
        FollowRedirects     = -not $NoRedirects
        ValidateCertificate = -not $NoCertificateValidation
        CertificatePins     = $CertificatePins
    }

    # Warn if certificate validation disabled (security-sensitive)
    if ($NoCertificateValidation) {
        Write-WarnLog -Message "Certificate validation DISABLED via -NoCertificateValidation. NOT recommended for production!"
    }

    # ─── Gather Entries ───────────────────────────────────────────────────────
    $entries = @()

    switch ($PSCmdlet.ParameterSetName) {
        'InputFile' {
            Write-Host "Reading URLs from file: $InputFile" -ForegroundColor Cyan
            try {
                $entries = Parse-InputFile -FilePath $InputFile
            }
            catch {
                Write-ErrorLog -Message "Failed to parse input file" -Context @{ file = $InputFile } -Exception $_.Exception
                Write-Error -Message "Failed to parse input file: $($_.Exception.Message)"
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

    # ─── Normalize & Validate Entries ──────────────────────────────────────────
    $normalizedEntries = Validate-AndNormalizeEntries -Entries $entries -AssumeHttps $true

    if ($normalizedEntries.Count -eq 0) {
        Write-Host "No valid URLs after normalization." -ForegroundColor Yellow
        Write-WarnLog -Message "No valid entries after normalization"
        return 0
    }

    # ─── WhatIf Preview ────────────────────────────────────────────────────────
    # Uses automatic common parameter via $PSBoundParameters
    if ($PSBoundParameters.ContainsKey('WhatIf')) {
        Write-Host "WhatIf: Would process $($normalizedEntries.Count) directory URLs:" -ForegroundColor Yellow
        foreach ($entry in $normalizedEntries) {
            Write-Host "  - $($entry.AbsoluteUri)"
        }
        return 0
    }

    # ─── Confirm ────────────────────────────────────────────────────────────────
    # Automatic common parameter support
    if ($PSBoundParameters.ContainsKey('Confirm')) {
        $choice = Read-Host "Process $($normalizedEntries.Count) entries? [Y/N]"
        if ($choice -notin @('y', 'Y', 'yes', 'YES')) {
            Write-Host "Cancelled." -ForegroundColor Yellow
            return 0
        }
    }

    # ─── Process Each Entry ────────────────────────────────────────────────────
    $results = [System.Collections.Generic.List[PSObject]]::new()
    $successCount = 0
    $failCount = 0

    # Progress reporting for batch operations
    $progressId = 1
    $total = $normalizedEntries.Count

    for ($i = 0; $i -lt $total; $i++) {
        $entry = $normalizedEntries[$i]
        $entryNum = $i + 1

        Write-Host "[$entryNum/$total] Processing: $($entry.AbsoluteUri)" -ForegroundColor Cyan

        # Progress bar for multi-entry operations
        if ($total -gt 1) {
            $percent = [math]::Round(($entryNum / $total) * 100)
            Write-Progress -Activity "Processing directory listings" -Status "$entryNum of $total" -PercentComplete $percent -Id $progressId
        }

        # Per-item ShouldProcess (honors -WhatIf/Confirm automatically)
        if ($PSCmdlet.ShouldProcess($entry.AbsoluteUri, 'Extract file URLs and generate output file')) {
            try {
                $result = Process-DirectoryEntry -Entry $entry.AbsoluteUri -OutputDir $OutputDir -NetworkParams $networkParams
                $results.Add($result)

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
                    Write-ErrorLog -Message "Entry processing failed" -Context @{ url = $entry.AbsoluteUri; error = $result.Error }
                }
            }
            catch {
                $failCount++
                $errMsg = $_.Exception.Message
                Write-Host "  [ERROR] $errMsg" -ForegroundColor Red
                Write-ErrorLog -Message "Exception during entry processing" -Context @{ url = $entry.AbsoluteUri } -Exception $_.Exception
            }
        }
        else {
            Write-Host "  [SKIPPED]" -ForegroundColor Yellow
        }
    }

    # Complete progress bar
    if ($total -gt 1) {
        Write-Progress -Activity "Processing directory listings" -Status "Completed" -PercentComplete 100 -Completed -Id $progressId
    }

    # ─── Summary Output ────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  Processing Complete" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  Successful: $successCount" -ForegroundColor Green
    Write-Host "  Failed:     $failCount" -ForegroundColor Red
    Write-Host "  Total:      $total" -ForegroundColor Cyan
    Write-Host ""

    if ($successCount -gt 0) {
        Write-Host "Output files saved to: $OutputDir" -ForegroundColor Green
    }

    Write-InfoLog -Message "=== $ScriptName completed ===" -Context @{
        success = $successCount
        failed  = $failCount
        total   = $total
    }

    # Exit codes: 0=success, 1=partial failure, 3=validation error (handled above)
    return if ($failCount -gt 0) { 1 } else { 0 }
}

# ─── Entry Point ────────────────────────────────────────────────────────────────
# Only run when executed as a script (not when dot-sourced for testing)

Write-Host "DEBUG: InvocationName=$($MyInvocation.InvocationName)"
if ($MyInvocation.InvocationName -eq ($null) -or $MyInvocation.InvocationName -match '\.ps1$') {
    try {
        
Write-Host "DEBUG: Calling Invoke-ListGenCLI with args: @args"
$exitCode = Invoke-ListGenCLI @args
        exit $exitCode
    }
    catch {
        # $_ is an ErrorRecord; .Exception is the actual System.Exception
        Write-Error -Message "Fatal error: $($_.Exception.Message)"
        Write-ErrorLog -Message "Fatal error in entry point" -Context @{
            error       = $_.Exception.Message
            stackTrace  = $_.ScriptStackTrace
            position    = $_.InvocationInfo.PositionMessage
        } -Exception $_.Exception
        exit 1
    }
}

# Restore PSScriptAnalyzer warning state
#pragma warning restore PSUseShouldProcessForStateChangingFunctions
#pragma warning restore PSUseDeclaredVarsMoreThanAssignments



