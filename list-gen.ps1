# ============================================================================
# Web Directory URL Extractor
#
# Prompts for a web directory URL, scans the directory listing,
# and generates a text file containing the full URL of every file found.
#
# Example:
#   https://mytech.today/tools/media/videos/50th/slideshow/
#
# Output:
#   urls-YYYYMMDD-HHMMSS.txt
#
# Compatible with:
#   PowerShell 5.1+
#   PowerShell 7+
# ============================================================================

Clear-Host

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "        Web Directory URL List Generator"
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

# Prompt user for URL
do {
    $BaseUrl = Read-Host "Enter the URL of the web directory to scan"

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        Write-Host "URL cannot be empty." -ForegroundColor Yellow
        continue
    }

    # Ensure trailing slash
    if (-not $BaseUrl.EndsWith('/')) {
        $BaseUrl += '/'
    }

    $ValidUrl = $true

    try {
        [void][System.Uri]$BaseUrl
    }
    catch {
        $ValidUrl = $false
        Write-Host "Invalid URL format." -ForegroundColor Red
    }

} until ($ValidUrl)

Write-Host ""
Write-Host "Scanning:" -NoNewline
Write-Host " $BaseUrl" -ForegroundColor Green
Write-Host ""

try {
    $Response = Invoke-WebRequest -Uri $BaseUrl -UseBasicParsing -ErrorAction Stop
}
catch {
    Write-Host ""
    Write-Host "Failed to retrieve directory listing." -ForegroundColor Red
    Write-Host $_.Exception.Message
    exit 1
}

# Extract href values
$Links = [regex]::Matches(
    $Response.Content,
    '(?i)href\s*=\s*["'']([^"'']+)["'']'
) | ForEach-Object {
    $_.Groups[1].Value.Trim()
}

# Remove common non-file entries
$Files = $Links |
    Where-Object {
        $_ -and
        $_ -ne "/" -and
        $_ -ne "../" -and
        $_ -notmatch '^#' -and
        $_ -notmatch '^mailto:' -and
        $_ -notmatch '^javascript:' -and
        $_ -notmatch '/$'
    } |
    Sort-Object -Unique

if ($Files.Count -eq 0) {
    Write-Host "No files were found in the directory listing." -ForegroundColor Yellow
    exit
}

# Build full URLs
$Urls = foreach ($File in $Files) {

    try {
        $AbsoluteUri = [System.Uri]::new([System.Uri]$BaseUrl, $File)
        $AbsoluteUri.AbsoluteUri
    }
    catch {
        "$BaseUrl$([uri]::EscapeUriString($File))"
    }
}

# Generate timestamped output file
$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$OutputFile = "urls-$Timestamp.txt"

$Urls | Set-Content -Path $OutputFile -Encoding UTF8

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host "Completed Successfully"
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Files Found : $($Urls.Count)"
Write-Host "Output File : $(Resolve-Path $OutputFile)"
Write-Host ""

$ShowCount = [Math]::Min(10, $Urls.Count)

Write-Host "First $ShowCount URLs:"
Write-Host "--------------------------------------------------"

$Urls |
    Select-Object -First $ShowCount |
    ForEach-Object { Write-Host $_ }

Write-Host ""
Write-Host "Done."
