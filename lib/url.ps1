<#
.SYNOPSIS
    URL processing utilities for list-gen - normalization, validation, and file URL extraction.

.DESCRIPTION
    Provides robust URL handling using System.Uri for parsing, normalization, and
    relative-to-absolute resolution. Handles edge cases: missing schemes, query strings,
    fragments, various extensions, trailing slashes, and directory detection.

.NOTES
    Version: 3.0.0
    Part of list-gen module
#>

#requires -Version 7.0
Set-StrictMode -Version Latest

# Common file extensions that indicate a file (not a directory)
$script:FileExtensions = @(
    # Archives
    '.zip', '.tar', '.gz', '.tgz', '.bz2', '.tbz2', '.xz', '.txz',
    '.rar', '.7z', '.zst', '.lz4',
    # Documents
    '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
    '.odt', '.ods', '.odp', '.rtf', '.txt', '.md', '.csv',
    # Images
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.tif',
    '.webp', '.svg', '.ico', '.heic', '.avif',
    # Audio/Video
    '.mp3', '.wav', '.flac', '.ogg', '.m4a', '.aac', '.opus',
    '.mp4', '.mkv', '.webm', '.avi', '.mov', '.flv', '.wmv',
    # Code/Config
    '.json', '.xml', '.yaml', '.yml', '.toml', '.ini', '.cfg',
    '.conf', '.config', '.js', '.ts', '.py', '.ps1', '.sh',
    '.bat', '.cmd', '.html', '.htm', '.css', '.scss', '.less',
    # Executables/Installers
    '.exe', '.msi', '.dmg', '.pkg', '.deb', '.rpm', '.apk',
    '.appimage', '.bin', '.run',
    # Fonts
    '.ttf', '.otf', '.woff', '.woff2', '.eot',
    # Database
    '.sqlite', '.db', '.mdb',
    # Misc
    '.iso', '.img', '.vhd', '.vmdk', '.ova', '.ovf'
)

# Extensions that are commonly used for directory listings (not files)
# These might appear in directory indexes but represent folders
$script:DirectoryIndicators = @(
    '/', '..', '../', './', '?C=', '?M=', '?S=', '?D=', '?N=', '?A='
)

<#
.SYNOPSIS
    Normalizes a URL string into a valid absolute URI.

.DESCRIPTION
    Handles multiple input formats:
    - Full URLs with scheme (http://, https://)
    - Scheme-less URLs (example.com/path) -> assumes HTTPS
    - URLs with/without trailing slashes
    - URLs with query strings and fragments (preserved)
    - File paths that look like URLs
    
    For directory URLs, ensures trailing slash. For file URLs, preserves extension.

.PARAMETER Url
    Input URL string to normalize.

.PARAMETER AssumeHttps
    If true (default), prepends https:// to scheme-less URLs.
    If false, prepends http://.

.PARAMETER TreatAsDirectory
    Forces treatment as directory (ensures trailing slash).
    If not specified, auto-detects based on extension.

.OUTPUTS
    System.Uri object representing the normalized URL.

.EXAMPLE
    Normalize-Url 'example.com/dir/'
    # Returns: https://example.com/dir/

.EXAMPLE
    Normalize-Url 'http://example.com/file.txt'
    # Returns: http://example.com/file.txt

.EXAMPLE
    Normalize-Url 'example.com/path?query=1#frag'
    # Returns: https://example.com/path?query=1#frag
#>
function Normalize-Url {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Url,

        [Parameter()]
        [bool]$AssumeHttps = $true,

        [Parameter()]
        [switch]$TreatAsDirectory
    )

    process {
        $inputUrl = $Url.Trim()

        # Handle empty/null
        if ([string]::IsNullOrWhiteSpace($inputUrl)) {
            Write-WarnLog -Message "Empty URL provided to Normalize-Url"
            return $null
        }

        # Check if it already has a scheme
        $hasScheme = $inputUrl -match '^[a-zA-Z][a-zA-Z0-9+.-]*://'

        $workingUrl = $inputUrl

        if (-not $hasScheme) {
            $scheme = if ($AssumeHttps) { 'https://' } else { 'http://' }
            $workingUrl = "$scheme$inputUrl"
            Write-DebugLog -Message "Added scheme to scheme-less URL" -Context @{ original = $inputUrl; withScheme = $workingUrl }
        }

        try {
            $uri = [System.Uri]$workingUrl
        }
        catch {
            Write-ErrorLog -Message "Failed to parse URL as System.Uri" -Context @{ url = $workingUrl; error = $_.Exception.Message } -Exception $_
            return $null
        }

        # Determine if this should be treated as a directory
        $isDirectory = $TreatAsDirectory.IsPresent

        if (-not $isDirectory) {
            # Auto-detect: check if path ends with a known file extension
            $path = $uri.AbsolutePath
            $isDirectory = -not (Test-IsFileUrl -Path $path)

            # Also check for directory indicators in query string
            if (-not $isDirectory -and $uri.Query) {
                foreach ($indicator in $script:DirectoryIndicators) {
                    if ($uri.Query -like "*$indicator*") {
                        $isDirectory = $true
                        break
                    }
                }
            }
        }

        # Normalize: ensure trailing slash for directories, preserve for files
        $normalizedPath = $uri.AbsolutePath
        if ($isDirectory -and -not $normalizedPath.EndsWith('/')) {
            $normalizedPath += '/'
        }
        elseif (-not $isDirectory -and $normalizedPath.EndsWith('/')) {
            # Looks like a file but has trailing slash - could be a directory
            # Keep the slash to be safe (server will redirect if wrong)
        }

        # Reconstruct URI with normalized path, preserving query and fragment
        # System.UriBuilder handles this cleanly
        $builder = [System.UriBuilder]::new($uri)
        $builder.Path = $normalizedPath
        # Query and Fragment are preserved automatically from original $uri

        $result = $builder.Uri

        Write-DebugLog -Message "URL normalized" -Context @{
            input      = $inputUrl
            output     = $result.AbsoluteUri
            isDirectory = $isDirectory
            scheme     = $result.Scheme
        }

        return $result
    }
}

<#
.SYNOPSIS
    Tests if a URL path looks like a file (has known extension).

.PARAMETER Path
    URL path component (e.g., /path/file.txt).

.RETURNS
    $true if path has a known file extension.
#>
function Test-IsFileUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path
    )

    # Get the last segment (filename)
    $segments = $Path.Split('/', [StringSplitOptions]::RemoveEmptyEntries)
    if ($segments.Count -eq 0) {
        return $false  # Root path = directory
    }

    $lastSegment = $segments[-1]

    # Check for extension
    $ext = [System.IO.Path]::GetExtension($lastSegment).ToLowerInvariant()
    if ([string]::IsNullOrEmpty($ext)) {
        return $false  # No extension = likely directory
    }

    # Check against known file extensions
    return $script:FileExtensions -contains $ext
}

<#
.SYNOPSIS
    Extracts all file URLs from a web directory listing page.

.DESCRIPTION
    Fetches the directory listing HTML, parses anchor href attributes,
    filters out non-file links (parent dir, mailto, javascript, fragments),
    and resolves relative URLs to absolute URLs using the base directory URL.

.PARAMETER DirectoryUrl
    Normalized directory URL (must end with / for directories).

.PARAMETER TimeoutSec
    Request timeout override.

.PARAMETER MaxRetries
    Retry attempt override.

.PARAMETER FollowRedirects
    Follow HTTP redirects.

.PARAMETER ValidateCertificate
    Validate TLS certificate.

.PARAMETER CertificatePins
    SPKI pins for certificate pinning.

.OUTPUTS
    Array of absolute file URL strings (System.Uri.AbsoluteUri).

.EXAMPLE
    $urls = Extract-FileUrls -DirectoryUrl 'https://example.com/files/'
#>
function Extract-FileUrls {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$DirectoryUrl,

        [Parameter()]
        [ValidateRange(1, 300)]
        [int]$TimeoutSec,

        [Parameter()]
        [ValidateRange(0, 10)]
        [int]$MaxRetries,

        [Parameter()]
        [bool]$FollowRedirects,

        [Parameter()]
        [bool]$ValidateCertificate,

        [Parameter()]
        [string[]]$CertificatePins
    )

    # Parse and validate directory URL
    $dirUri = Normalize-Url -Url $DirectoryUrl -TreatAsDirectory
    if (-not $dirUri) {
        Write-ErrorLog -Message "Invalid directory URL" -Context @{ directoryUrl = $DirectoryUrl }
        return @()
    }

    # Ensure it ends with /
    if (-not $dirUri.AbsoluteUri.EndsWith('/')) {
        Write-WarnLog -Message "Directory URL does not end with /, appending" -Context @{ url = $dirUri.AbsoluteUri }
        $builder = [System.UriBuilder]::new($dirUri)
        $builder.Path = $dirUri.AbsolutePath.TrimEnd('/') + '/'
        $dirUri = $builder.Uri
    }

    Write-DebugLog -Message "Fetching directory listing" -Context @{ directoryUrl = $dirUri.AbsoluteUri }

    # Fetch the directory listing
    try {
        $response = Invoke-WebRequestWithRetry -Uri $dirUri.AbsoluteUri `
            -Method GET `
            -TimeoutSec $TimeoutSec `
            -MaxRetries $MaxRetries `
            -FollowRedirects $FollowRedirects `
            -ValidateCertificate $ValidateCertificate `
            -CertificatePins $CertificatePins `
            -UseBasicParsing
    }
    catch {
        Write-ErrorLog -Message "Failed to retrieve directory listing" -Context @{
            directoryUrl = $dirUri.AbsoluteUri
            error        = $_.Exception.Message
        } -Exception $_
        throw
    }

    $html = $response.Content
    if ([string]::IsNullOrWhiteSpace($html)) {
        Write-WarnLog -Message "Directory listing returned empty content" -Context @{ directoryUrl = $dirUri.AbsoluteUri }
        return @()
    }

    # Extract href attributes from HTML
    # Pattern matches: href="..." or href='...' (case-insensitive)
    $hrefPattern = '(?i)href\s*=\s*["'']([^"'']+)["'']'
    $matches = [System.Text.RegularExpressions.Regex]::Matches($html, $hrefPattern)

    $rawLinks = @()
    foreach ($match in $matches) {
        if ($match.Groups.Count -ge 2) {
            $rawLinks += $match.Groups[1].Value.Trim()
        }
    }

    Write-DebugLog -Message "Raw links extracted from HTML" -Context @{ count = $rawLinks.Count }

    # Filter and resolve links
    $fileUrls = @()

    foreach ($link in $rawLinks) {
        try {
            $resolved = Resolve-RelativeUrl -BaseUrl $dirUri.AbsoluteUri -RelativeUrl $link

            if (-not $resolved) {
                continue
            }

            $resolvedUri = [System.Uri]$resolved

            # Filter out non-file entries
            if (Should-IncludeUrl -ResolvedUri $resolvedUri -BaseUri $dirUri) {
                $fileUrls += $resolvedUri.AbsoluteUri
            }
        }
        catch {
            Write-DebugLog -Message "Failed to resolve link, skipping" -Context @{ link = $link; error = $_.Exception.Message }
        }
    }

    # Sort and deduplicate
    $fileUrls = $fileUrls | Sort-Object -Unique

    Write-InfoLog -Message "Extracted file URLs from directory" -Context @{
        directoryUrl = $dirUri.AbsoluteUri
        fileCount    = $fileUrls.Count
    }

    return $fileUrls
}

<#
.SYNOPSIS
    Resolves a relative URL against a base URL.

.PARAMETER BaseUrl
    Absolute base URL (directory URL ending with /).

.PARAMETER RelativeUrl
    Relative or absolute URL to resolve.

.RETURNS
    Absolute URI string, or $null if resolution fails.
#>
function Resolve-RelativeUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$RelativeUrl
    )

    $relativeUrl = $RelativeUrl.Trim()

    # Skip empty
    if ([string]::IsNullOrWhiteSpace($relativeUrl)) {
        return $null
    }

    # Skip fragment-only
    if ($relativeUrl.StartsWith('#')) {
        return $null
    }

    # Skip javascript: and mailto: and other non-http schemes
    if ($relativeUrl -match '^[a-zA-Z][a-zA-Z0-9+.-]*:') {
        $scheme = $relativeUrl.Split(':')[0].ToLowerInvariant()
        if ($scheme -notin @('http', 'https')) {
            return $null
        }
        # Absolute URL with http/https scheme - use as-is
        return $relativeUrl
    }

    # Resolve relative to base
    try {
        $baseUri = [System.Uri]$BaseUrl
        $absoluteUri = [System.Uri]::new($baseUri, $relativeUrl)
        return $absoluteUri.AbsoluteUri
    }
    catch {
        Write-DebugLog -Message "Failed to resolve relative URL" -Context @{
            baseUrl      = $BaseUrl
            relativeUrl  = $relativeUrl
            error        = $_.Exception.Message
        }
        return $null
    }
}

<#
.SYNOPSIS
    Determines if a resolved URL should be included in the file list.

.DESCRIPTION
    Filters out:
    - Parent directory (../)
    - Current directory (./)
    - Root directory (/)
    - Directory links (ending with /)
    - Fragment-only links
    - mailto:, javascript:, tel:, data: schemes
    - Links outside the base directory (optional, controlled by -AllowExternal)

.PARAMETER ResolvedUri
    The resolved absolute URI.

.PARAMETER BaseUri
    The base directory URI.

.PARAMETER AllowExternal
    If true, allows links to different hosts/domains. Default: false.

.RETURNS
    $true if URL should be included.
#>
function Should-IncludeUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Uri]$ResolvedUri,

        [Parameter(Mandatory = $true)]
        [System.Uri]$BaseUri,

        [Parameter()]
        [bool]$AllowExternal = $false
    )

    # Must be http or https
    if ($ResolvedUri.Scheme -notin @('http', 'https')) {
        return $false
    }

    # Check host matches base (unless external allowed)
    if (-not $AllowExternal -and $ResolvedUri.Host -ine $BaseUri.Host) {
        Write-DebugLog -Message "Skipping external host" -Context @{
            baseHost = $BaseUri.Host
            linkHost = $ResolvedUri.Host
        }
        return $false
    }

    # Must be under base path (or same path)
    $basePath = $BaseUri.AbsolutePath
    $linkPath = $ResolvedUri.AbsolutePath

    if (-not $linkPath.StartsWith($basePath, [StringComparison]::OrdinalIgnoreCase)) {
        Write-DebugLog -Message "Skipping link outside base path" -Context @{
            basePath = $basePath
            linkPath = $linkPath
        }
        return $false
    }

    # Skip directory indicators
    $lastSegment = $linkPath.Split('/', [StringSplitOptions]::RemoveEmptyEntries)[-1]
    if ($lastSegment -ieq '..' -or $lastSegment -ieq '.') {
        return $false
    }

    # Skip if it ends with / (directory link in listing)
    if ($linkPath.EndsWith('/')) {
        return $false
    }

    # Skip query-only parameters used for sorting (e.g., ?C=N;O=D)
    # but KEEP files that happen to have query strings
    # Heuristic: if the path portion looks like a file, keep it
    if (-not (Test-IsFileUrl -Path $linkPath)) {
        # No file extension - could be a directory or a parameterized directory link
        # Check if it's just the base path with query params
        if ($linkPath -eq $basePath -and $ResolvedUri.Query) {
            return $false  # e.g., /dir/?C=N;O=D
        }
        # Could be a file without extension - include it but warn
        Write-DebugLog -Message "Including URL without file extension" -Context @{ url = $ResolvedUri.AbsoluteUri }
    }

    return $true
}

<#
.SYNOPSIS
    Validates a URL string without throwing.

.PARAMETER Url
    URL to validate.

.PARAMETER RequireHttps
    If true, only HTTPS URLs are valid.

.RETURNS
    PSCustomObject with Valid (bool), Uri (System.Uri or null), Error (string).
#>
function Test-Url {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Url,

        [Parameter()]
        [bool]$RequireHttps = $false
    )

    $result = [PSCustomObject]@{
        Valid = $false
        Uri   = $null
        Error = $null
    }

    try {
        $uri = Normalize-Url -Url $Url -AssumeHttps $true
        if (-not $uri) {
            $result.Error = 'Failed to normalize URL'
            return $result
        }

        if ($RequireHttps -and $uri.Scheme -ine 'https') {
            $result.Error = 'HTTPS required but URL uses HTTP'
            return $result
        }

        $result.Valid = $true
        $result.Uri   = $uri
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

<#
.SYNOPSIS
    Gets the filename from a URL, handling edge cases.

.PARAMETER Url
    Absolute URL string.

.RETURNS
    Filename string, or generated name if not determinable.
#>
function Get-UrlFileName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Url
    )

    try {
        $uri = [System.Uri]$Url
        $path = $uri.AbsolutePath
        $segments = $path.Split('/', [StringSplitOptions]::RemoveEmptyEntries)

        if ($segments.Count -gt 0) {
            $fileName = $segments[-1]
            # Remove query string if present in filename (shouldn't happen but safety)
            $fileName = $fileName.Split('?')[0]
            $fileName = $fileName.Split('#')[0]

            if (-not [string]::IsNullOrWhiteSpace($fileName)) {
                return $fileName
            }
        }
    }
    catch {
        Write-DebugLog -Message "Failed to extract filename from URL, using generated name" -Context @{ url = $Url; error = $_.Exception.Message }
    }

    # Generate a name from URL hash
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Url))
    $shortHash = [Convert]::ToBase64String($hash)[0..11] -join '' -replace '[/+=]', '_'
    return "download_$shortHash"
}

Export-ModuleMember -Function @(
    'Normalize-Url'
    'Test-IsFileUrl'
    'Extract-FileUrls'
    'Resolve-RelativeUrl'
    'Should-IncludeUrl'
    'Test-Url'
    'Get-UrlFileName'
)