<#
.SYNOPSIS
    Scans publicly accessible web directories for media files and generates an alphabetized, grouped list of URLs.

.DESCRIPTION
    gen-list.ps1 is a robust PowerShell tool that discovers media files (video, audio, images) from web directory listings.
    It supports flexible input methods, self-updating from GitHub, structured logging, and multiple output formats.

    Repository: https://github.com/mytech-today-now/URL-list-generator

.NOTES
    Version: 1.0.0
    Author: Grok (xAI) - Generated for mytech-today-now
#>

[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [Parameter(Mandatory = $false, Position = 0, ValueFromPipeline = $true)]
    [string[]]$Url,

    [Parameter(Mandatory = $false)]
    [string]$InputFile,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [switch]$Json,

    [Parameter(Mandatory = $false)]
    [switch]$Text,

    [Parameter(Mandatory = $false)]
    [switch]$Recursive,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [string]$Username,

    [Parameter(Mandatory = $false)]
    [string]$Password,

    [Parameter(Mandatory = $false)]
    [switch]$Quiet,

    [Parameter(Mandatory = $false)]
    [switch]$Help
)

# Self-updating and remote invocation logic
$ScriptName = 'gen-list.ps1'
$RepoUrl = 'https://raw.githubusercontent.com/mytech-today-now/URL-list-generator/refs/heads/main/gen-list.ps1'
$LocalBaseDir = Join-Path $env:USERPROFILE 'myTech.Today'
$LocalScriptDir = Join-Path $LocalBaseDir 'gen-list'
$LocalScriptPath = Join-Path $LocalScriptDir $ScriptName
$LogDir = Join-Path $LocalBaseDir 'logs'
$LogFile = Join-Path $LogDir "gen-list_$(Get-Date -Format 'yyyy-MM').jsonl"

# Capture original arguments for relaunch
$OriginalArgs = $MyInvocation.UnboundArguments + $MyInvocation.BoundParameters.GetEnumerator().ForEach({ "-$($_.Key)", $_.Value })

function Write-Log {
    param([string]$Level, [string]$Message, [object]$Data = $null)
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $entry = [PSCustomObject]@{
        Timestamp = Get-Date -Format 'o'
        Level     = $Level
        Message   = $Message
        Data      = $Data
        Script    = $ScriptName
    } | ConvertTo-Json -Compress
    $entry | Out-File -FilePath $LogFile -Append -Encoding UTF8
}

# Setup logging module
$LoggingModuleUrl = 'https://raw.githubusercontent.com/mytech-today-now/scripts/refs/heads/main/logging.ps1'
$LoggingModulePath = Join-Path $LocalBaseDir 'logging.ps1'

if (-not (Test-Path $LoggingModulePath)) {
    try {
        Invoke-WebRequest -Uri $LoggingModuleUrl -OutFile $LoggingModulePath -UseBasicParsing
        Write-Log 'INFO' 'Downloaded logging module'
    } catch {
        Write-Log 'WARN' 'Failed to download logging module' $_.Exception.Message
    }
}

# Ensure local repo directory
if (-not (Test-Path $LocalScriptDir)) {
    try {
        New-Item -ItemType Directory -Path $LocalScriptDir -Force | Out-Null
        Write-Log 'INFO' "Created local directory: $LocalScriptDir"
    } catch {
        Write-Error "Failed to create local directory: $_"
        exit 1
    }
}

# Self-update logic
$IsRemote = $MyInvocation.MyCommand.Path -notlike "*$LocalScriptDir*"
if ($IsRemote) {
    Write-Host "🔄 Updating to latest version..." -ForegroundColor Cyan
    try {
        $latestContent = Invoke-WebRequest -Uri $RepoUrl -UseBasicParsing -TimeoutSec 30
        $latestContent.Content | Out-File -FilePath $LocalScriptPath -Encoding UTF8 -Force
        Write-Log 'INFO' 'Self-updated to latest version'
    } catch {
        Write-Log 'ERROR' 'Self-update failed' $_.Exception.Message
        Write-Warning "Self-update failed. Continuing with remote version."
    }

    # Relaunch local version
    if (Test-Path $LocalScriptPath) {
        Write-Host "🚀 Relaunching local copy..." -ForegroundColor Green
        $cmd = "& `"$LocalScriptPath`" $($OriginalArgs -join ' ')"
        Invoke-Expression $cmd
        exit 0
    }
}

# Main script starts here
$Version = '1.0.0'
$StartTime = Get-Date

if ($Help) {
    Get-Help $MyInvocation.MyCommand.Path -Detailed
    exit 0
}

Write-Host "🌐 gen-list.ps1 v$Version - Media URL List Generator" -ForegroundColor Magenta

# Import or define logging if needed
if (Test-Path $LoggingModulePath) {
    . $LoggingModulePath
}

# Media extensions (case-insensitive)
$MediaExtensions = @(
    '.mp4','.mkv','.webm','.mov','.avi','.wmv','.flv','.mpeg','.mpg','.m4v','.3gp',
    '.jpg','.jpeg','.png','.gif','.webp','.bmp','.tiff','.tif','.svg',
    '.mp3','.wav','.ogg','.m4a','.flac','.aac','.wma','.opus'
) | Sort-Object

function Get-DirectoryListing {
    param(
        [string]$TargetUrl,
        [bool]$Recurse = $false,
        [PSCredential]$Credential = $null
    )

    $results = @()
    $queue = [System.Collections.Queue]::new()
    $queue.Enqueue($TargetUrl)
    $visited = @{}

    while ($queue.Count -gt 0) {
        $currentUrl = $queue.Dequeue()
        if ($visited.ContainsKey($currentUrl)) { continue }
        $visited[$currentUrl] = $true

        Write-Log 'INFO' "Fetching directory: $currentUrl"

        try {
            $params = @{
                Uri = $currentUrl
                UseBasicParsing = $true
                Method = 'GET'
                UserAgent = 'Mozilla/5.0 (compatible; gen-list.ps1/1.0)'
                TimeoutSec = 30
            }
            if ($Credential) { $params.Credential = $Credential }

            $response = Invoke-WebRequest @params
            $html = $response.Content

            # Parse links - support common directory listing formats
            $links = [regex]::Matches($html, '<a\s+href="([^"]+)"', 'IgnoreCase')

            foreach ($match in $links) {
                $href = $match.Groups[1].Value.Trim()
                if ($href -eq '../' -or $href -eq './' -or $href.StartsWith('?')) { continue }

                $fullUrl = if ($href -match '^https?://') { $href } else { $currentUrl.TrimEnd('/') + '/' + $href.TrimStart('/') }

                if ($href.EndsWith('/')) {
                    # Subdirectory
                    if ($Recurse) {
                        $queue.Enqueue($fullUrl)
                    }
                } elseif ($MediaExtensions -contains [System.IO.Path]::GetExtension($href).ToLower()) {
                    $results += $fullUrl
                }
            }
        } catch {
            Write-Log 'ERROR' "Failed to fetch $currentUrl" $_.Exception.Message
            Write-Warning "Failed to access $currentUrl : $($_.Exception.Message)"
        }
    }

    return $results | Sort-Object -Unique
}

# Collect input URLs
$allUrls = @()

if ($Url) {
    $allUrls = $Url
} elseif ($InputFile) {
    if (Test-Path $InputFile) {
        $content = Get-Content $InputFile -Raw
        $allUrls = [regex]::Matches($content, 'https?://[^\s"''<>,;]+') | ForEach-Object { $_.Value }
    } else {
        Write-Error "Input file not found: $InputFile"
        exit 1
    }
} elseif ([Console]::IsInputRedirected) {
    # Pipeline input
    $allUrls = @($input) | Where-Object { $_ }
} else {
    # Interactive mode
    Write-Host "`nEnter web directory URL(s) (one per line, blank line to finish):" -ForegroundColor Yellow
    $inputLines = @()
    while ($true) {
        $line = Read-Host
        if ([string]::IsNullOrWhiteSpace($line)) { break }
        $inputLines += $line
    }
    $allUrls = $inputLines
}

# Clean and parse URLs
$cleanUrls = @()
foreach ($u in $allUrls) {
    $trimmed = $u.Trim('"', "'", ' ', "`t", "`n", "`r")
    if ($trimmed -match '^https?://') {
        $cleanUrls += $trimmed
    }
}
$cleanUrls = $cleanUrls | Sort-Object -Unique

if (-not $cleanUrls) {
    Write-Host "No valid URLs provided. Use -Url, -InputFile, or interactive mode." -ForegroundColor Red
    exit 1
}

if ($DryRun) {
    Write-Host "🔍 DRY RUN - Would process the following URLs:" -ForegroundColor Cyan
    $cleanUrls | ForEach-Object { Write-Host "   $_" -ForegroundColor Gray }
    exit 0
}

# Process URLs
$allMedia = @{}
$progressId = 1

foreach ($webUrl in $cleanUrls) {
    Write-Progress -Id $progressId -Activity "Scanning $webUrl" -Status "Fetching directory listing..." -PercentComplete 0
    $files = Get-DirectoryListing -TargetUrl $webUrl -Recurse $Recursive

    foreach ($file in $files) {
        $ext = [System.IO.Path]::GetExtension($file).ToLower()
        if (-not $allMedia.ContainsKey($ext)) {
            $allMedia[$ext] = [System.Collections.ArrayList]::new()
        }
        $allMedia[$ext].Add($file) | Out-Null
    }
    Write-Progress -Id $progressId -Completed
    $progressId++
}

# Sort within groups
foreach ($ext in $allMedia.Keys) {
    $allMedia[$ext] = $allMedia[$ext] | Sort-Object
}

# Prepare output
$DownloadsDir = [Environment]::GetFolderPath('Downloads')
$Timestamp = Get-Date -Format 'yyyy-MM-dd-HH-mm'
$DefaultTxtPath = Join-Path $DownloadsDir "URLs-results-$Timestamp.txt"
$DefaultJsonPath = Join-Path $DownloadsDir "URLs-results-$Timestamp.json"

if ($OutputPath) {
    if (Test-Path $OutputPath -PathType Container) {
        $outDir = $OutputPath
    } else {
        $outDir = Split-Path $OutputPath -Parent
        if (-not $outDir) { $outDir = $DownloadsDir }
    }
} else {
    $outDir = $DownloadsDir
}

$OutputTxt = Join-Path $outDir "URLs-results-$Timestamp.txt"
$OutputJson = Join-Path $outDir "URLs-results-$Timestamp.json"

# Save outputs
$totalFiles = ($allMedia.Values | Measure-Object -Sum Count).Sum

if (-not $Quiet) {
    Write-Host "`n✅ Processing complete!" -ForegroundColor Green
    Write-Host "   Total media files found: $totalFiles" -ForegroundColor White
}

$grouped = @{}
foreach ($ext in ($allMedia.Keys | Sort-Object)) {
    $grouped[$ext] = $allMedia[$ext]
    if (-not $Quiet) {
        Write-Host "   $($ext.ToUpper()): $($allMedia[$ext].Count) files" -ForegroundColor Cyan
    }
}

# Text output
$grouped.GetEnumerator() | ForEach-Object {
    "=== $($_.Key.ToUpper()) ===" | Out-File -FilePath $OutputTxt -Append -Encoding UTF8
    $_.Value | Out-File -FilePath $OutputTxt -Append -Encoding UTF8
    "" | Out-File -FilePath $OutputTxt -Append -Encoding UTF8
}

# JSON output
$grouped | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputJson -Encoding UTF8

# Pipeline output
if ($MyInvocation.ExpectingInput -or $Text) {
    if ($Json -or -not $Text) {
        $grouped | ConvertTo-Json -Depth 10
    } else {
        Get-Content $OutputTxt
    }
} else {
    Write-Host "`n📁 Results saved to:" -ForegroundColor Green
    Write-Host "   TXT: $OutputTxt" -ForegroundColor White
    Write-Host "   JSON: $OutputJson" -ForegroundColor White
}

$EndTime = Get-Date
$Duration = $EndTime - $StartTime

Write-Log 'INFO' "Completed scan" @{
    TotalFiles = $totalFiles
    Extensions = $grouped.Keys.Count
    DurationSeconds = [math]::Round($Duration.TotalSeconds, 2)
    Recursive = $Recursive
}

if (-not $Quiet) {
    Write-Host "`n⏱️  Completed in $($Duration.ToString('mm\:ss'))" -ForegroundColor Gray
}