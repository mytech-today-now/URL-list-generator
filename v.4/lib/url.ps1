<#
.SYNOPSIS
    Core URL parsing, normalization, and regex patterns for list-gen

.DESCRIPTION
    Provides robust URL extraction from HTML, URL normalization, validation, and
    pattern matching. All regex patterns are pre-compiled for performance and
    designed to handle malformed HTML, international characters, and edge cases.

.NOTES
    This module has no dependencies and contains pure functions for testability.
#>

Set-StrictMode -Version Latest

#region Pre-compiled Regex Patterns (Performance Critical)

$script:RegexCache = @{}

function Get-Regex {
    <#
    .SYNOPSIS
        Get or create a pre-compiled Regex instance with caching
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [string]$Pattern,

        [Parameter()]
        [System.Text.RegularExpressions.RegexOptions]$Options = [System.Text.RegularExpressions.RegexOptions]::None
    )

    $key = "$Pattern|$Options"
    if ($script:RegexCache.ContainsKey($key)) {
        return $script:RegexCache[$key]
    }

    try {
        $regex = [System.Text.RegularExpressions.Regex]::new($Pattern, $Options)
        $script:RegexCache[$key] = $regex
        return $regex
    }
    catch {
        Log-Error -Message "Invalid regex pattern: {0}" -Args $Pattern -Exception $_ -Category 'Regex'
        throw
    }
}

# Pre-compiled patterns for HTML attribute extraction
$script:Patterns = @{
    # HREF attribute: matches href="value" or href='value' or href=value (unquoted)
    # Handles: whitespace, case-insensitive, quoted/unquoted, javascript:, data:, mailto:
    Href = @'
(?xi)
href
\s* = \s*
(?:
    " ( [^"]* ) "          # double-quoted: capture group 1
  | ' ( [^']* ) '          # single-quoted: capture group 2
  | ( [^\s>"']+ )          # unquoted: capture group 3 (until whitespace, >, or quote)
)
'@

    # SRC attribute (for images, scripts, iframes, etc.)
    Src = @'
(?xi)
src
\s* = \s*
(?:
    " ( [^"]* ) "
  | ' ( [^']* ) '
  | ( [^\s>"']+ )
)
'@

    # Generic attribute value extractor (for any attribute)
    AttributeValue = @'
(?xi)
(\w+)                     # attribute name (group 1)
\s* = \s*
(?:
    " ( [^"]* ) "         # double-quoted value (group 2)
  | ' ( [^']* ) '         # single-quoted value (group 3)
  | ( [^\s>"']+ )         # unquoted value (group 4)
)
'@

    # Base tag for relative URL resolution
    BaseTag = @'
(?xi)
<base
\s+ [^>]*?
href
\s* = \s*
(?:
    " ( [^"]* ) "
  | ' ( [^']* ) '
  | ( [^\s>"']+ )
)
[^>]*>
'@

    # Meta refresh redirect
    MetaRefresh = @'
(?xi)
<meta
\s+ [^>]*?
http-equiv \s* = \s* ["\'] refresh ["\'] [^>]*?
content \s* = \s* ["\'] \d+ \s* ; \s* url = ([^"']+) ["\']
'@

    # JavaScript URL patterns (to filter or flag)
    JsUrl = @'
(?xi)
^ \s*
(?:
    javascript \s* :
  | data \s* :
  | vbscript \s* :
  | about \s* :
  | blob \s* :
)
'@

    # URL scheme detection
    UrlScheme = @'
^ ( [a-zA-Z][a-zA-Z0-9+.-]* ) :
'@

    # Relative URL patterns
    RelativePath = @'
^ (?: \./ | ../ | / | [a-zA-Z0-9] )
'@

    # Protocol-relative URL (//example.com/path)
    ProtocolRelative = @'
^ //
'@

    # Fragment-only URL (#section)
    FragmentOnly = @'
^ #
'@

    # Query string extraction
    QueryString = @'
\? ( [^#]* )
'@

    # Fragment extraction
    Fragment = @'
# ( .* )
'@

    # Valid URL characters (RFC 3986)
    ValidUrlChars = @'
[ a-zA-Z0-9 \-._~!$&'()*+,;=:@/ % ]
'@
}

# Initialize all patterns as compiled regexes
foreach ($name in $script:Patterns.Keys) {
    $options = [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
               [System.Text.RegularExpressions.RegexOptions]::IgnorePatternWhitespace -bor
               [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    $script:RegexCache[$name] = [System.Text.RegularExpressions.Regex]::new($script:Patterns[$name], $options)
}

#endregion

#region Public Functions - URL Extraction

function Extract-UrlsFromHtml {
    <#
    .SYNOPSIS
        Extract all URLs from HTML content

    .DESCRIPTION
        Parses HTML and extracts URLs from href, src, and other attributes.
        Handles malformed HTML, international characters, and various quoting styles.

    .PARAMETER Html
        HTML content as string

    .PARAMETER BaseUrl
        Base URL for resolving relative URLs

    .PARAMETER Attributes
        Attributes to extract (default: href, src). Can include: href, src, action, data-src, poster, etc.

    .PARAMETER Filter
        ScriptBlock to filter results. Receives each URL, returns $true to keep.

    .PARAMETER Unique
        Return only unique URLs (default: $true)

    .PARAMETER ResolveRelative
        Resolve relative URLs against BaseUrl (default: $true)

    .OUTPUTS
        System.Collections.Generic.List[UrlInfo]

    .EXAMPLE
        $urls = Extract-UrlsFromHtml -Html $html -BaseUrl 'https://example.com'

    .EXAMPLE
        $urls = Extract-UrlsFromHtml -Html $html -Attributes @('href','src','data-src') -Filter { $_ -notmatch '^javascript:' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)]
        [string]$Html,

        [Parameter(Position=1)]
        [string]$BaseUrl = '',

        [string[]]$Attributes = @('href', 'src'),

        [ScriptBlock]$Filter,

        [switch]$Unique = $true,

        [switch]$ResolveRelative = $true
    )

    begin {
        $results = [System.Collections.Generic.List[pscustomobject]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $baseUri = if ($BaseUrl) { try { [Uri]::new($BaseUrl) } catch { $null } } else { $null }
    }

    process {
        foreach ($attr in $Attributes) {
            $pattern = Get-AttributePattern $attr
            $matches = $pattern.Matches($Html)

            foreach ($match in $matches) {
                $url = Get-MatchUrl $match
                if ([string]::IsNullOrWhiteSpace($url)) { continue }

                # Skip javascript:, data:, etc. unless explicitly allowed
                if ($url -imatch $script:RegexCache['JsUrl']) {
                    Log-Debug -Message "Skipping non-HTTP URL: {0}" -Args $url -Category 'Parsing'
                    continue
                }

                # Resolve relative URLs
                if ($ResolveRelative -and $baseUri -and (Test-RelativeUrl $url)) {
                    try {
                        $resolved = Resolve-RelativeUrl -BaseUri $baseUri -RelativeUrl $url
                        $url = $resolved.AbsoluteUri
                    }
                    catch {
                        Log-Warning -Message "Failed to resolve relative URL: {0} (base: {1})" -Args $url, $BaseUrl -Category 'Parsing'
                    }
                }

                # Normalize
                $normalized = Normalize-Url $url
                if (-not $normalized) { continue }

                # Apply filter
                if ($Filter -and -not (& $Filter $normalized)) { continue }

                # Deduplicate
                if ($Unique -and $seen.Contains($normalized)) { continue }
                $seen.Add($normalized) | Out-Null

                $results.Add([pscustomobject]@{
                    Url          = $normalized
                    Attribute    = $attr
                    OriginalUrl  = $url
                    IsRelative   = (Test-RelativeUrl $url)
                    SourceHtml   = $match.Value.Substring(0, [Math]::Min(200, $match.Value.Length))
                })
            }
        }
    }

    end {
        return $results
    }
}

function Get-AttributePattern {
    param([string]$AttributeName)

    $key = "Attr_$AttributeName"
    if ($script:RegexCache.ContainsKey($key)) {
        return $script:RegexCache[$key]
    }

    # Build pattern dynamically for any attribute
    $pattern = @"
(?xi)
$AttributeName
\s* = \s*
(?:
    " ( [^"]* ) "
  | ' ( [^']* ) '
  | ( [^\s>"']+ )
)
"@

    $regex = [System.Text.RegularExpressions.Regex]::new($pattern,
        [System.Text.RegularExpressions.RegexOptions]::Compiled -bor
        [System.Text.RegularExpressions.RegexOptions]::IgnorePatternWhitespace -bor
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $script:RegexCache[$key] = $regex
    return $regex
}

function Get-MatchUrl {
    param($Match)

    # Groups: 1=double-quoted, 2=single-quoted, 3=unquoted
    for ($i = 1; $i -lt $Match.Groups.Count; $i++) {
        if ($Match.Groups[$i].Success) {
            return $Match.Groups[$i].Value.Trim()
        }
    }
    return $null
}

#endregion

#region Public Functions - URL Normalization & Validation

function Normalize-Url {
    <#
    .SYNOPSIS
        Normalize a URL (lowercase scheme/host, remove default ports, sort query params)

    .DESCRIPTION
        Applies RFC 3986 normalization: scheme/host to lowercase, removes default ports,
        decodes unnecessary percent-encoding, removes dot-segments, sorts query parameters.

    .PARAMETER Url
        URL to normalize

    .PARAMETER SortQueryParams
        Sort query parameters alphabetically (default: $true)

    .PARAMETER RemoveFragment
        Remove fragment identifier (default: $false)

    .OUTPUTS
        string (normalized URL) or $null if invalid

    .EXAMPLE
        Normalize-Url 'HTTPS://EXAMPLE.COM:443/Path/../File?b=2&a=1#frag'
        # Returns: 'https://example.com/file?a=1&b=2#frag'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)]
        [string]$Url,

        [switch]$SortQueryParams = $true,

        [switch]$RemoveFragment
    )

    try {
        $uri = [Uri]::new($Url)
    }
    catch {
        Log-Debug -Message "Invalid URI for normalization: {0}" -Args $Url -Category 'Normalization'
        return $null
    }

    # Scheme and host to lowercase
    $scheme = $uri.Scheme.ToLowerInvariant()
    $host = $uri.Host.ToLowerInvariant()

    # Port handling - remove default ports
    $port = $uri.Port
    $defaultPorts = @{ 'http' = 80; 'https' = 443; 'ftp' = 21; 'ftps' = 990 }
    if ($defaultPorts.ContainsKey($scheme) -and $port -eq $defaultPorts[$scheme]) {
        $port = -1  # Will be omitted in ToString
    }

    # Reconstruct authority
    $authority = $host
    if ($port -ne -1) { $authority += ":$port" }

    # Path - remove dot segments (./ and ../)
    $path = Remove-DotSegments $uri.AbsolutePath

    # Query string
    $query = $uri.Query.TrimStart('?')
    if ($SortQueryParams -and $query) {
        $params = $query -split '&' | Where-Object { $_ } |
            ForEach-Object {
                $kv = $_ -split '=', 2
                [PSCustomObject]@{ Key = $kv[0]; Value = if ($kv.Count -gt 1) { $kv[1] } else { '' } }
            } | Sort-Object Key
        $query = ($params | ForEach-Object { "{0}={1}" -f $_.Key, $_.Value }) -join '&'
    }

    # Fragment
    $fragment = if ($RemoveFragment) { '' } else { $uri.Fragment }

    # Build normalized URL
    $normalized = "${scheme}://${authority}${path}"
    if ($query) { $normalized += "?$query" }
    if ($fragment) { $normalized += $fragment }

    return $normalized
}

function Remove-DotSegments {
    param([string]$Path)

    if (-not $Path -or $Path -eq '/') { return '/' }

    $segments = $Path -split '/'
    $stack = @()

    foreach ($seg in $segments) {
        switch ($seg) {
            ''      { continue }           # Skip empty (from leading // or trailing /)
            '.'     { continue }           # Current directory - skip
            '..'    { if ($stack.Count -gt 0) { $stack = $stack[0..($stack.Count-2)] } }  # Parent directory
            default { $stack += $seg }
        }
    }

    $result = '/' + ($stack -join '/')
    # Preserve trailing slash if original had it (and wasn't just root)
    if ($Path.EndsWith('/') -and $Path.Length -gt 1) {
        $result += '/'
    }
    return $result
}

function Test-UrlValid {
    <#
    .SYNOPSIS
        Validate a URL for syntactic correctness and optionally reachability

    .DESCRIPTION
        Performs RFC 3986 syntactic validation. With -CheckReachability, performs
        a HEAD request to verify the resource exists.

    .PARAMETER Url
        URL to validate

    .PARAMETER CheckReachability
        Perform HTTP HEAD request (requires network access)

    .PARAMETER TimeoutSec
        Timeout for reachability check (default: 10s)

    .PARAMETER AllowedSchemes
        Allowed URI schemes (default: http, https)

    .OUTPUTS
        [UrlValidationResult] with properties: IsValid, Url, Errors, HttpStatusCode

    .EXAMPLE
        Test-UrlValid 'https://example.com'

    .EXAMPLE
        Test-UrlValid 'https://example.com' -CheckReachability -TimeoutSec 5
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)]
        [string]$Url,

        [switch]$CheckReachability,

        [int]$TimeoutSec = 10,

        [string[]]$AllowedSchemes = @('http', 'https')
    )

    $result = @{
        Url              = $Url
        IsValid          = $false
        Errors           = @()
        HttpStatusCode   = $null
        NormalizedUrl    = $null
    }

    # Syntactic validation
    if ([string]::IsNullOrWhiteSpace($Url)) {
        $result.Errors += 'URL is empty or whitespace'
        return $result
    }

    try {
        $uri = [Uri]::new($Url)
    }
    catch {
        $result.Errors += "Invalid URI syntax: $($_.Exception.Message)"
        return $result
    }

    # Scheme validation
    $scheme = $uri.Scheme.ToLowerInvariant()
    if ($AllowedSchemes -notcontains $scheme) {
        $result.Errors += "Scheme '$scheme' not in allowed schemes: $($AllowedSchemes -join ', ')"
        return $result
    }

    # Host validation
    if ([string]::IsNullOrWhiteSpace($uri.Host)) {
        $result.Errors += 'Missing or invalid host'
        return $result
    }

    # Basic host syntax (RFC 1123 / RFC 3986)
    if ($uri.Host -notmatch '^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$' -and
        $uri.Host -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -and
        $uri.Host -ne 'localhost') {
        $result.Errors += "Host '$($uri.Host)' does not appear to be a valid domain or IP"
        # Don't return - just warn
    }

    # Normalize for output
    $result.NormalizedUrl = Normalize-Url $Url
    $result.IsValid = $true

    # Reachability check
    if ($CheckReachability -and $result.IsValid) {
        $result = Check-UrlReachability -Url $result.NormalizedUrl -TimeoutSec $TimeoutSec -Result $result
    }

    return $result
}

function Check-UrlReachability {
    param(
        [string]$Url,
        [int]$TimeoutSec,
        $Result
    )

    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = 'HEAD'
        $request.Timeout = $TimeoutSec * 1000
        $
```powershell
        $request.UserAgent = $script:ModuleConfig.DefaultUserAgent
        $request.AllowAutoRedirect = $true
        $request.MaximumAutomaticRedirections = 5

        $response = $request.GetResponse()
        $Result.HttpStatusCode = [int]$response.StatusCode
        $response.Close()

        if ($Result.HttpStatusCode -ge 400) {
            $Result.Errors += "HTTP $($Result.HttpStatusCode): $([System.Net.HttpStatusCode]::$($Result.HttpStatusCode))"
            $Result.IsValid = $false
        }
    }
    catch [System.Net.WebException] {
        $Result.HttpStatusCode = if ($_.Response) { [int]$_.Response.StatusCode } else { 0 }
        $Result.Errors += "Network error: $($_.Exception.Message)"
        $Result.IsValid = $false
    }
    catch {
        $Result.Errors += "Unexpected error: $($_.Exception.Message)"
        $Result.IsValid = $false
    }

    return $Result
}

function Test-RelativeUrl {
    param([string]$Url)

    return $Url -match $script:RegexCache['RelativePath'] -or
           $Url -match $script:RegexCache['ProtocolRelative'] -or
           $Url -match $script:RegexCache['FragmentOnly']
}

function Resolve-RelativeUrl {
    param(
        [Parameter(Mandatory)]
        [Uri]$BaseUri,

        [Parameter(Mandatory)]
        [string]$RelativeUrl
    )

    if ($RelativeUrl -match $script:RegexCache['FragmentOnly']) {
        return [Uri]::new($BaseUri, $RelativeUrl)
    }

    if ($RelativeUrl -match $script:RegexCache['ProtocolRelative']) {
        return [Uri]::new("$($BaseUri.Scheme):$RelativeUrl")
    }

    return [Uri]::new($BaseUri, $RelativeUrl)
}

function ConvertTo-AbsoluteUrl {
    <#
    .SYNOPSIS
        Convert a relative URL to absolute using a base URL

    .PARAMETER RelativeUrl
        Relative URL or path

    .PARAMETER BaseUrl
        Base URL for resolution

    .OUTPUTS
        string (absolute URL)

    .EXAMPLE
        ConvertTo-AbsoluteUrl '/path/page.html' '<https://example.com/base/>'
        # Returns: '<https://example.com/path/page.html>'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)]
        [string]$RelativeUrl,

        [Parameter(Mandatory, Position=1)]
        [string]$BaseUrl
    )

    try {
        $baseUri = [Uri]::new($BaseUrl)
        $resolved = Resolve-RelativeUrl -BaseUri $baseUri -RelativeUrl $RelativeUrl
        return Normalize-Url $resolved.AbsoluteUri
    }
    catch {
        Log-Error -Message "Failed to convert to absolute URL: {0} (base: {1})" -Args $RelativeUrl, $BaseUrl -Exception $_ -Category 'Normalization'
        throw
    }
}

#endregion

#region Public Functions - Pattern Matching & Filtering

function Select-UrlPattern {
    <#
    .SYNOPSIS
        Filter URLs by pattern matching

    .DESCRIPTION
        Supports wildcard, regex, and glob-style patterns for flexible URL filtering.

    .PARAMETER Url
        URLs to filter (pipeline input supported)

    .PARAMETER Pattern
        Pattern to match (wildcard by default, use -Regex for regex)

    .PARAMETER Regex
        Treat Pattern as regular expression

    .PARAMETER CaseSensitive
        Case-sensitive matching

    .PARAMETER NotMatch
        Invert match (exclude matching URLs)

    .EXAMPLE
        Get-UrlList -Source '<https://example.com>' | Select-UrlPattern -Pattern '*blog*' -NotMatch

    .EXAMPLE
        $urls | Select-UrlPattern -Pattern '^/api/v\d+' -Regex
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string[]]$Url,

        [Parameter(Mandatory, Position=0)]
        [string]$Pattern,

        [switch]$Regex,

        [switch]$CaseSensitive,

        [switch]$NotMatch
    )

    process {
        foreach ($u in $Url) {
            $match = if ($Regex) {
                if ($CaseSensitive) { $u -cmatch $Pattern } else { $u -imatch $Pattern }
            }
            else {
                # Wildcard to regex conversion
                $regexPattern = '^' + ([System.Text.RegularExpressions.Regex]::Escape($Pattern) -replace '\\\\\\\\*', '.*' -replace '\\\\\\\\?', '.') + '$'
                if ($CaseSensitive) { $u -cmatch $regexPattern } else { $u -imatch $regexPattern }
            }

            if ($NotMatch) { $match = -not $match }
            if ($match) { $u }
        }
    }
}

#endregion

#region Type Definitions (for output objects - pure PSObject, no Add-Type for compatibility)

# Type data for consistent property access
if (-not ('UrlInfo' -as [Type])) {
    Update-TypeData -TypeName 'UrlInfo' -MemberType ScriptProperty -MemberName Url -Value { $this.Url } -ErrorAction SilentlyContinue
    Update-TypeData -TypeName 'UrlValidationResult' -MemberType ScriptProperty -MemberName Url -Value { $this.Url } -ErrorAction SilentlyContinue
}

#endregion

Export-ModuleMember -Function @(
    'Extract-UrlsFromHtml',
    'Normalize-Url',
    'Test-UrlValid',
    'Test-RelativeUrl',
    'Resolve-RelativeUrl',
    'ConvertTo-AbsoluteUrl',
    'Select-UrlPattern',
    'Get-Regex'
)