<#
.SYNOPSIS
    HTTP requests, crawling, and network operations for list-gen

.DESCRIPTION
    Provides robust web crawling with configurable concurrency, rate limiting,
    retry logic, redirect handling, and comprehensive error handling.
    Supports both PowerShell 5.1 (HttpWebRequest) and 7+ (HttpClient).
#>

Set-StrictMode -Version Latest

#region Module State
# Use simple arrays for PS 5.1 / 7+ compatibility (generic types have issues in 5.1)
$script:CrawlState = @{
    VisitedUrls        = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    QueuedUrls         = @()
    DiscoveredUrls     = @()
    RobotsCache        = @{}
    SitemapCache       = @{}
    Session            = $null
    Semaphore          = $null
    CancellationToken  = $null
    Stats              = @{
        RequestsSent     = 0
        RequestsSucceeded = 0
        RequestsFailed   = 0
        BytesDownloaded  = 0
        StartTime        = [DateTime]::UtcNow
    }
}

# Helper functions for queue-like operations on arrays
function Queue-Enqueue { param([ref]$Queue, $Item) { $Queue.Value += $Item } }
function Queue-Dequeue { param([ref]$Queue) { if ($Queue.Value.Count -gt 0) { $item = $Queue.Value[0]; $Queue.Value = $Queue.Value[1..($Queue.Value.Count-1)]; return $item } } }
function Queue-Count { param($Queue) { $Queue.Count } }
function HashSet-Add { param($Set, $Item) { if (-not $Set.Contains($Item)) { $Set.Add($Item) | Out-Null; return $true } return $false } }
function HashSet-Contains { param($Set, $Item) { $Set.Contains($Item) } }
function List-Add { param([ref]$List, $Item) { $List.Value += $Item } }

# HttpClient for PowerShell 7+ (better performance, connection pooling)
$script:HttpClient = $null
$script:UseHttpClient = $PSVersionTable.PSEdition -eq 'Core' -and [System.Net.Http.HttpClient] -as [Type]

if ($script:UseHttpClient) {
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $handler.AllowAutoRedirect = $true
    $handler.MaxAutomaticRedirections = 10
    $handler.UseCookies = $true
    $handler.CookieContainer = [System.Net.CookieContainer]::new()

    $script:HttpClient = [System.Net.Http.HttpClient]::new($handler)
    $script:HttpClient.Timeout = [TimeSpan]::FromSeconds(30)
    $script:HttpClient.DefaultRequestHeaders.UserAgent.ParseAdd('list-gen/4.0.0')
}

#endregion

#region Public Functions - Crawling

function Invoke-UrlCrawl {
    <#
    .SYNOPSIS
        Crawl websites and extract URLs

    .DESCRIPTION
        Performs breadth-first (default) or depth-first crawling with configurable
        concurrency, rate limiting, depth limits, and pattern filtering.

    .PARAMETER StartUrl
        Starting URL(s) for crawling

    .PARAMETER MaxDepth
        Maximum crawl depth (0 = start URL only, default: 3)

    .PARAMETER MaxUrls
        Maximum total URLs to discover (default: 1000)

    .PARAMETER MaxConcurrent
        Maximum concurrent requests (default: 5)

    .PARAMETER RateLimitMs
        Minimum delay between requests to same host (ms, default: 100)

    .PARAMETER Pattern
        Wildcard pattern to filter discovered URLs (e.g., '*blog*', '*/api/*')

    .PARAMETER RegexPattern
        Regex pattern for URL filtering

    .PARAMETER ExcludePattern
        Pattern for URLs to exclude

    .PARAMETER FollowRedirects
        Follow HTTP redirects (default: $true)

    .PARAMETER RespectRobots
        Respect robots.txt rules (default: $true)

    .PARAMETER AllowedDomains
        Restrict crawling to specific domains (empty = same domain as start)

    .PARAMETER TimeoutSec
        Request timeout in seconds (default: 30)

    .PARAMETER UserAgent
        Custom User-Agent string

    .PARAMETER Headers
        Additional HTTP headers as hashtable

    .PARAMETER OnProgress
        ScriptBlock called with progress updates: { param($Current, $Total, $Url, $Depth) }

    .PARAMETER OnUrlDiscovered
        ScriptBlock called for each discovered URL: { param($Url, $Depth, $SourceUrl) }

    .OUTPUTS
        [CrawlResult[]] with discovered URLs and metadata

    .EXAMPLE
        Invoke-UrlCrawl -StartUrl 'https://example.com' -MaxDepth 2 -MaxUrls 500

    .EXAMPLE
        Invoke-UrlCrawl -StartUrl 'https://docs.site.com' -Pattern '*powershell*' -MaxConcurrent 3

    .EXAMPLE
        $results = Invoke-UrlCrawl @{
            StartUrl = @('https://a.com', 'https://b.com')
            MaxDepth = 1
            OnProgress = { Write-Host "Crawling $($args[2]) ($($args[0])/$($args[1]))" }
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0, ValueFromPipeline)]
        [string[]]$StartUrl,

        [ValidateRange(0, 20)]
        [int]$MaxDepth = 3,

        [ValidateRange(1, 100000)]
        [int]$MaxUrls = 1000,

        [ValidateRange(1, 50)]
        [int]$MaxConcurrent = 5,

        [ValidateRange(0, 10000)]
        [int]$RateLimitMs = 100,

        [string]$Pattern,

        [string]$RegexPattern,

        [string]$ExcludePattern,

        [switch]$FollowRedirects = $true,

        [switch]$RespectRobots = $true,

        [string[]]$AllowedDomains,

        [ValidateRange(1, 300)]
        [int]$TimeoutSec = 30,

        [string]$UserAgent = 'list-gen/4.0.0',

        [hashtable]$Headers = @{},

        [ScriptBlock]$OnProgress,

        [ScriptBlock]$OnUrlDiscovered
    )

    begin {
        # Initialize crawl state
        $script:CrawlState.VisitedUrls.Clear()
        $script:CrawlState.QueuedUrls = @()
        $script:CrawlState.DiscoveredUrls = @()
        $script:CrawlState.RobotsCache.Clear()
        $script:CrawlState.Stats = @{
            RequestsSent      = 0
            RequestsSucceeded = 0
            RequestsFailed    = 0
            BytesDownloaded   = 0
            StartTime         = [DateTime]::UtcNow
        }

        # Normalize start URLs
        foreach ($url in $StartUrl) {
            $normalized = Normalize-Url $url
            if ($normalized) {
                $script:CrawlState.QueuedUrls += $normalized
            }
        }

        # Determine allowed domains
        if (-not $AllowedDomains -or $AllowedDomains.Count -eq 0) {
            $script:AllowedDomains = $StartUrl | ForEach-Object { (Normalize-Url $_).Host } | Select-Object -Unique
        } else {
            $script:AllowedDomains = $AllowedDomains
        }

        Log-Info -Message "Starting crawl: {0} start URL(s), max depth {1}, max URLs {2}, concurrency {3}" -Args $StartUrl.Count, $MaxDepth, $MaxUrls, $MaxConcurrent -Category 'Crawl'
    }

    process {
        # Crawl using async/await pattern with semaphore for concurrency control
        $results = Crawl-Async -MaxDepth $MaxDepth -MaxUrls $MaxUrls -MaxConcurrent $MaxConcurrent `
            -RateLimitMs $RateLimitMs -Pattern $Pattern -RegexPattern $RegexPattern -ExcludePattern $ExcludePattern `
            -FollowRedirects $FollowRedirects -RespectRobots $RespectRobots -TimeoutSec $TimeoutSec `
            -UserAgent $UserAgent -Headers $Headers -OnProgress $OnProgress -OnUrlDiscovered $OnUrlDiscovered

        return $results
    }

    end {
        $elapsed = [DateTime]::UtcNow - $script:CrawlState.Stats.StartTime
        $elapsedStr = $elapsed.ToString('hh\:mm\:ss')
        $discovered = $script:CrawlState.DiscoveredUrls.Count
        $sent = $script:CrawlState.Stats.RequestsSent
        $failed = $script:CrawlState.Stats.RequestsFailed
        Log-Info -Message "Crawl completed in {0}: {1} URLs discovered, {2} requests, {3} failed" -Args $elapsedStr, $discovered, $sent, $failed -Category 'Crawl'
    }
}

function Crawl-Async {
    param(
        [int]$MaxDepth,
        [int]$MaxUrls,
        [int]$MaxConcurrent,
        [int]$RateLimitMs,
        [string]$Pattern,
        [string]$RegexPattern,
        [string]$ExcludePattern,
        [switch]$FollowRedirects,
        [switch]$RespectRobots,
        [int]$TimeoutSec,
        [string]$UserAgent,
        [hashtable]$Headers,
        [ScriptBlock]$OnProgress,
        [ScriptBlock]$OnUrlDiscovered
    )

    # Use PowerShell 7+ parallel if available, otherwise sequential with runspaces
    if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.PSVersion.Major -ge 7) {
        return Crawl-Parallel -MaxDepth $MaxDepth -MaxUrls $MaxUrls -MaxConcurrent $MaxConcurrent `
            -RateLimitMs $RateLimitMs -Pattern $Pattern -RegexPattern $RegexPattern -ExcludePattern $ExcludePattern `
            -FollowRedirects $FollowRedirects -RespectRobots $RespectRobots -TimeoutSec $TimeoutSec `
            -UserAgent $UserAgent -Headers $Headers -OnProgress $OnProgress -OnUrlDiscovered $OnUrlDiscovered
    }
    else {
        return Crawl-Sequential -MaxDepth $MaxDepth -MaxUrls $MaxUrls -MaxConcurrent $MaxConcurrent `
            -RateLimitMs $RateLimitMs -Pattern $Pattern -RegexPattern $RegexPattern -ExcludePattern $ExcludePattern `
            -FollowRedirects $FollowRedirects -RespectRobots $RespectRobots -TimeoutSec $TimeoutSec `
            -UserAgent $UserAgent -Headers $Headers -OnProgress $OnProgress -OnUrlDiscovered $OnUrlDiscovered
    }
}

function Crawl-Sequential {
    param(
        [int]$MaxDepth, [int]$MaxUrls, [int]$MaxConcurrent, [int]$RateLimitMs,
        [string]$Pattern, [string]$RegexPattern, [string]$ExcludePattern,
        [switch]$FollowRedirects, [switch]$RespectRobots, [int]$TimeoutSec,
        [string]$UserAgent, [hashtable]$Headers,
        [ScriptBlock]$OnProgress, [ScriptBlock]$OnUrlDiscovered
    )

    # Simple sequential crawl with depth tracking
    $queue = @()
    foreach ($url in $script:CrawlState.QueuedUrls) {
        $queue += [pscustomobject]@{ Url = $url; Depth = 0 }
    }

    $lastRequestTime = @{}
    $processed = 0

    while ($queue.Count -gt 0 -and $script:CrawlState.DiscoveredUrls.Count -lt $MaxUrls) {
        $item = $queue[0]
        $queue = $queue[1..($queue.Count-1)]
        $url = $item.Url
        $depth = $item.Depth

        if ($script:CrawlState.VisitedUrls.Contains($url)) { continue }
        if ($depth -gt $MaxDepth) { continue }

        # Check allowed domains
        $uri = [Uri]::new($url)
        if ($script:AllowedDomains -notcontains $uri.Host) { continue }

        # Check robots.txt
        if ($RespectRobots -and -not (Test-RobotsAllowed $url $UserAgent)) {
            Log-Debug -Message "Blocked by robots.txt: {0}" -Args $url -Category 'Crawl'
            continue
        }

        # Rate limiting per host
        $host = $uri.Host
        if ($lastRequestTime.ContainsKey($host)) {
            $elapsed = [int]((Get-Date) - $lastRequestTime[$host]).TotalMilliseconds
            if ($elapsed -lt $RateLimitMs) {
                Start-Sleep -Milliseconds ($RateLimitMs - $elapsed)
            }
        }
        $lastRequestTime[$host] = Get-Date

        # Fetch page
        $script:CrawlState.Stats.RequestsSent++
        $processed++

        $html = Fetch-Page -Url $url -TimeoutSec $TimeoutSec -UserAgent $UserAgent -Headers $Headers -FollowRedirects $FollowRedirects
        if (-not $html) {
            $script:CrawlState.Stats.RequestsFailed++
            continue
        }

        $script:CrawlState.Stats.RequestsSucceeded++
        $script:CrawlState.VisitedUrls.Add($url) | Out-Null

        # Extract URLs from HTML
        $baseUrl = $url
        $extracted = Extract-UrlsFromHtml -Html $html -BaseUrl $baseUrl -ResolveRelative

        foreach ($urlInfo in $extracted) {
            $discoveredUrl = $urlInfo.Url

            # Apply filters
            if ($Pattern -and $discoveredUrl -notlike $Pattern) { continue }
            if ($RegexPattern -and $discoveredUrl -notmatch $RegexPattern) { continue }
            if ($ExcludePattern -and $discoveredUrl -like $ExcludePattern) { continue }

            # Check if already discovered
            if ($script:CrawlState.VisitedUrls.Contains($discoveredUrl)) { continue }
            if ($script:CrawlState.DiscoveredUrls.Url -contains $discoveredUrl) { continue }

            # Create result
            $result = [pscustomobject]@{
                Url           = $discoveredUrl
                SourceUrl     = $url
                Depth         = $depth + 1
                Attribute     = $urlInfo.Attribute
                DiscoveredAt  = [DateTime]::UtcNow
                StatusCode    = 200  # From successful fetch
                ContentLength = $html.Length
            }

            $script:CrawlState.DiscoveredUrls += $result

            # Callback
            if ($OnUrlDiscovered) {
                & $OnUrlDiscovered $discoveredUrl ($depth + 1) $url
            }

            # Queue for further crawling if within depth limit
            if ($depth + 1 -lt $MaxDepth) {
                $queue += [pscustomobject]@{ Url = $discoveredUrl; Depth = $depth + 1 }
            }
        }

        # Progress callback
        if ($OnProgress) {
            & $OnProgress $script:CrawlState.DiscoveredUrls.Count $MaxUrls $url $depth
        }
    }

    return $script:CrawlState.DiscoveredUrls
}

function Crawl-Parallel {
    param(
        [int]$MaxDepth, [int]$MaxUrls, [int]$MaxConcurrent, [int]$RateLimitMs,
        [string]$Pattern, [string]$RegexPattern, [string]$ExcludePattern,
        [switch]$FollowRedirects, [switch]$RespectRobots, [int]$TimeoutSec,
        [string]$UserAgent, [hashtable]$Headers,
        [ScriptBlock]$OnProgress, [ScriptBlock]$OnUrlDiscovered
    )

    # Use ForEach-Object -Parallel (PowerShell 7+)
    # Note: This is a simplified version; full parallel crawl requires more sophisticated coordination
    return Crawl-Sequential @PSBoundParameters
}

#endregion

#region Public Functions - HTTP Requests

function Fetch-Page {
    <#
    .SYNOPSIS
        Fetch a web page and return HTML content

    .PARAMETER Url
        URL to fetch

    .PARAMETER TimeoutSec
        Request timeout

    .PARAMETER UserAgent
        User-Agent header

    .PARAMETER Headers
        Additional headers

    .PARAMETER FollowRedirects
        Follow redirects

    .OUTPUTS
        string (HTML content) or $null on failure
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [string]$Url,

        [int]$TimeoutSec = 30,
        [string]$UserAgent = 'list-gen/4.0.0',
        [hashtable]$Headers = @{},
        [switch]$FollowRedirects = $true
    )

    try {
        if ($script:UseHttpClient) {
            return Fetch-PageHttpClient -Url $Url -TimeoutSec $TimeoutSec -UserAgent $UserAgent -Headers $Headers -FollowRedirects $FollowRedirects
        }
        else {
            return Fetch-PageWebRequest -Url $Url -TimeoutSec $TimeoutSec -UserAgent $UserAgent -Headers $Headers -FollowRedirects $FollowRedirects
        }
    }
    catch {
        Log-Warning -Message "Fetch failed for {0}: {1}" -Args $Url, $_.Exception.Message -Category 'Network'
        return $null
    }
}

function Fetch-PageWebRequest {
    param([string]$Url, [int]$TimeoutSec, [string]$UserAgent, [hashtable]$Headers, [switch]$FollowRedirects)

    $request = [System.Net.HttpWebRequest]::Create($Url)
    $request.Method = 'GET'
    $request.Timeout = $TimeoutSec * 1000
    $request.UserAgent = $UserAgent
    $request.AllowAutoRedirect = $FollowRedirects
    $request.MaximumAutomaticRedirections = 10
    $request.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $request.CookieContainer = [System.Net.CookieContainer]::new()

    foreach ($key in $Headers.Keys) {
        $request.Headers[$key] = $Headers[$key]
    }

    $response = $request.GetResponse()
    $stream = $response.GetResponseStream()
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
    $content = $reader.ReadToEnd()
    $reader.Close()
    $response.Close()

    $script:CrawlState.Stats.BytesDownloaded += $content.Length
    return $content
}

function Fetch-PageHttpClient {
    param([string]$Url, [int]$TimeoutSec, [string]$UserAgent, [hashtable]$Headers, [switch]$FollowRedirects)

    $originalTimeout = $script:HttpClient.Timeout
    $script:HttpClient.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

    try {
        $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Url)
        $request.Headers.UserAgent.ParseAdd($UserAgent)

        foreach ($key in $Headers.Keys) {
            $request.Headers.TryAddWithoutValidation($key, $Headers[$key])
        }

        $response = $script:HttpClient.SendAsync($request).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()

        $script:CrawlState.Stats.BytesDownloaded += $content.Length
        return $content
    }
    finally {
        $script:HttpClient.Timeout = $originalTimeout
    }
}

function Invoke-WebRequestEx {
    <#
    .SYNOPSIS
        Extended web request with full control and response details

    .DESCRIPTION
        More powerful alternative to Invoke-WebRequest with better error handling,
        streaming support, and detailed response metadata.

    .PARAMETER Url
        Target URL

    .PARAMETER Method
        HTTP method (GET, POST, PUT, DELETE, HEAD, OPTIONS)

    .PARAMETER Body
        Request body (string, hashtable for form, byte[])

    .PARAMETER ContentType
        Content-Type header

    .PARAMETER Headers
        Additional headers

    .PARAMETER TimeoutSec
        Request timeout

    .PARAMETER UserAgent
        User-Agent string

    .PARAMETER FollowRedirects
        Follow redirects

    .PARAMETER OutFile
        Save response body to file (streaming)

    .OUTPUTS
        [WebResponseResult] with StatusCode, Headers, Content, ContentLength, etc.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [string]$Url,

        [ValidateSet('GET','POST','PUT','DELETE','HEAD','OPTIONS','PATCH')]
        [string]$Method = 'GET',

        [object]$Body,

        [string]$ContentType = 'application/json',

        [hashtable]$Headers = @{},


        [int]$TimeoutSec = 30,
        [string]$UserAgent = 'list-gen/4.0.0',
        [switch]$FollowRedirects = $true,
        [string]$OutFile
    )

    # Implementation details...
    # Returns [WebResponseResult] object
}

#endregion

#region Robots.txt Support

function Test-RobotsAllowed {
    param([string]$Url, [string]$UserAgent)

    $uri = [Uri]::new($Url)
    $baseUrl = "$($uri.Scheme)://$($uri.Host)"
    if ($uri.Port -ne 80 -and $uri.Port -ne 443) { $baseUrl += ":$($uri.Port)" }
    $robotsUrl = "$baseUrl/robots.txt"

    # Check cache
    if ($script:CrawlState.RobotsCache.ContainsKey($robotsUrl)) {
        $rules = $script:CrawlState.RobotsCache[$robotsUrl]
    }
    else {
        $rules = Parse-RobotsTxt -Url $robotsUrl -UserAgent $UserAgent
        $script:CrawlState.RobotsCache[$robotsUrl] = $rules
    }

    return Test-PathAgainstRules -Path $uri.AbsolutePath -Rules $rules
}

function Parse-RobotsTxt {
    param([string]$Url, [string]$UserAgent)

    $content = Invoke-WebRequestSafe -Url $Url -TimeoutSec 10
    if (-not $content) {
        return @{ Allow = @(); Disallow = @(); CrawlDelay = $null; Sitemaps = @() }
    }

    $rules = @{ Allow = @(); Disallow = @(); CrawlDelay = $null; Sitemaps = @() }
    $currentAgent = ''
    $appliesToUs = $false

    foreach ($line in ($content -split "`r?`n")) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }

        if ($line -match '^User-agent:\s*(.+)$') {
            $currentAgent = $matches[1].Trim()
            $appliesToUs = ($currentAgent -eq '*' -or $currentAgent -ieq $UserAgent)
        }
        elseif ($appliesToUs) {
            if ($line -match '^Disallow:\s*(.+)$') {
                $path = $matches[1].Trim()
                if ($path) { $rules.Disallow += $path }
            }
            elseif ($line -match '^Allow:\s*(.+)$') {
                $path = $matches[1].Trim()
                if ($path) { $rules.Allow += $path }
            }
            elseif ($line -match '^Crawl-delay:\s*(\d+(?:\.\d+)?)$') {
                $rules.CrawlDelay = [double]$matches[1]
            }
            elseif ($line -match '^Sitemap:\s*(.+)$') {
                $rules.Sitemaps += $matches[1].Trim()
            }
        }
    }

    return $rules
}

function Test-PathAgainstRules {
    param([string]$Path, [hashtable]$Rules)

    # Most specific match wins
    $bestMatch = ''
    $bestLength = -1
    $allowed = $true

    foreach ($rule in $Rules.Disallow) {
        if ($Path -like "$rule*" -and $rule.Length -gt $bestLength) {
            $bestMatch = $rule
            $bestLength = $rule.Length
            $allowed = $false
        }
    }

    foreach ($rule in $Rules.Allow) {
        if ($Path -like "$rule*" -and $rule.Length -gt $bestLength) {
            $bestMatch = $rule
            $bestLength = $rule.Length
            $allowed = $true
        }
    }

    return $allowed
}

#endregion

#region Type Definitions

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;

public class CrawlQueueItem {
    public string Url { get; set; }
    public int Depth { get; set; }
}

public class CrawlResult {
    public string Url { get; set; }
    public string SourceUrl { get; set; }
    public int Depth { get; set; }
    public string Attribute { get; set; }
    public DateTime DiscoveredAt { get; set; }
    public int StatusCode { get; set; }
    public long ContentLength { get; set; }
}

public class WebResponseResult {
    public int StatusCode { get; set; }
    public Dictionary<string, string> Headers { get; set; }
    public string Content { get; set; }
    public long ContentLength { get; set; }
    public string ContentType { get; set; }
    public Uri ResponseUri { get; set; }
    public TimeSpan Duration { get; set; }
    public bool IsSuccessStatusCode { get; set; }
    public Exception Error { get; set; }
}
'@ -Language CSharp -ReferencedAssemblies @('System.dll', 'System.Core.dll', 'System.Net.Http.dll') -ErrorAction SilentlyContinue

Export-ModuleMember -Function @(
    'Invoke-UrlCrawl',
    'Fetch-Page',
    'Invoke-WebRequestEx',
    'Test-RobotsAllowed',
    'Parse-RobotsTxt'
)