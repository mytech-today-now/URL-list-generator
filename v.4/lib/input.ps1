<#
.SYNOPSIS
    Input handling and source processing for list-gen

.DESCRIPTION
    Handles multiple input sources: single URLs, URL lists from files (txt, csv, json, xml),
    sitemaps, robots.txt, stdin pipeline, and clipboard. Provides validation and normalization.

.NOTES
    Requires: lib/url.ps1, lib/logging.ps1, lib/network.ps1
#>

Set-StrictMode -Version Latest

#region Public Functions - Input Sources

function Get-UrlInput {
    <#
    .SYNOPSIS
        Get URLs from various input sources

    .DESCRIPTION
        Unified entry point for all input types. Supports:
        - Single URL string
        - File with URLs (one per line, CSV, JSON, XML)
        - Sitemap URLs (auto-discovered or explicit)
        - robots.txt (for crawl-delay, disallow rules)
        - Pipeline input
        - Clipboard content

    .PARAMETER Source
        Input source: URL, file path, 'sitemap:<url>', 'robots:<url>', 'clipboard', or 'stdin'

    .PARAMETER Format
        Input file format (auto-detected if not specified): Text, Csv, Json, Xml, Sitemap

    .PARAMETER Column
        Column name/index for CSV/JSON/XML (default: 'Url', 'url', 'URL', 0)

    .PARAMETER BaseUrl
        Base URL for resolving relative URLs in input

    .PARAMETER MaxUrls
        Maximum URLs to return (0 = unlimited)

    .PARAMETER Validate
        Validate each URL syntactically (default: $true)

    .OUTPUTS
        [UrlInputResult[]] with properties: Url, Source, LineNumber, IsValid, Errors

    .EXAMPLE
        Get-UrlInput -Source '<https://example.com>'

    .EXAMPLE
        Get-UrlInput -Source './urls.txt' -Format Text

    .EXAMPLE
        Get-UrlInput -Source 'sitemap:<https://example.com/sitemap.xml>'

    .EXAMPLE
        Get-Content urls.csv | Get-UrlInput -Source 'stdin' -Format Csv -Column 'url'
    #>
    [CmdletBinding(DefaultParameterSetName='Auto')]
    param(
        [Parameter(Mandatory, Position=0, ParameterSetName='Auto')]
        [Parameter(Mandatory, Position=0, ParameterSetName='File')]
        [Parameter(Mandatory, Position=0, ParameterSetName='Sitemap')]
        [Parameter(Mandatory, Position=0, ParameterSetName='Robots')]
        [Parameter(Mandatory, Position=0, ParameterSetName='Clipboard')]
        [Parameter(Mandatory, Position=0, ParameterSetName='Stdin')]
        [string]$Source,

        [Parameter(ParameterSetName='File')]
        [ValidateSet('Text','Csv','Json','Xml','Sitemap','Auto')]
        [string]$Format = 'Auto',

        [Parameter(ParameterSetName='File')]
        [string]$Column = 'Url',

        [Parameter(ParameterSetName='File')]
        [Parameter(ParameterSetName='Sitemap')]
        [string]$BaseUrl,

        [int]$MaxUrls = 0,

        [switch]$Validate = $true
    )

    $results = @()

    switch -Wildcard ($Source) {
        'sitemap:*' {
            $sitemapUrl = $Source.Substring(8)
            $results += Get-SitemapUrls -SitemapUrl $sitemapUrl -MaxUrls $MaxUrls -Validate:$Validate
        }
        'robots:*' {
            $robotsUrl = $Source.Substring(7)
            $results += Get-RobotsTxtUrls -RobotsUrl $robotsUrl -MaxUrls $MaxUrls
        }
        'clipboard' {
            $results += Get-ClipboardUrls -MaxUrls $MaxUrls -Validate:$Validate
        }
        'stdin' {
            $results += Get-StdinUrls -Format $Format -Column $Column -MaxUrls $MaxUrls -Validate:$Validate
        }
        default {
            # Check if it's a file
            if (Test-Path $Source -PathType Leaf) {
                $results += Get-FileUrls -Path $Source -Format $Format -Column $Column -BaseUrl $BaseUrl -MaxUrls $MaxUrls -Validate:$Validate
            }
            elseif ($Source -match '^https?://') {
                $results += @{
                    Url         = $Source
                    Source      = 'Direct'
                    LineNumber  = 0
                    IsValid     = $true
                    Errors      = @()
                    RetrievedAt = (Get-Date).ToUniversalTime()
                }
            }
            else {
                Log-Error -Message "Unknown input source: {0}" -Args $Source -Category 'Input'
                throw "Invalid source: $Source. Use URL, file path, 'sitemap:<url>', 'robots:<url>', 'clipboard', or 'stdin'."
            }
        }
    }

    # Apply global max limit
    if ($MaxUrls -gt 0 -and $results.Count -gt $MaxUrls) {
        $results = $results[0..($MaxUrls-1)]
    }

    return $results
}

function Get-FileUrls {
    <#
    .SYNOPSIS
        Read URLs from a file

    .PARAMETER Path
        Path to input file

    .PARAMETER Format
        File format (Auto-detected by extension if not specified)

    .PARAMETER Column
        Column name for structured formats

    .PARAMETER BaseUrl
        Base URL for relative URL resolution

    .PARAMETER MaxUrls
        Maximum URLs to read

    .PARAMETER Validate
        Validate URLs
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$Path,

        [ValidateSet('Text','Csv','Json','Xml','Sitemap','Auto')]
        [string]$Format = 'Auto',

        [string]$Column = 'Url',

        [string]$BaseUrl,

        [int]$MaxUrls = 0,

        [switch]$Validate
    )

    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    $detectedFormat = if ($Format -eq 'Auto') {
        switch ($ext) {
            '.txt'  { 'Text' }
            '.csv'  { 'Csv' }
            '.json' { 'Json' }
            '.xml'  { 'Xml' }
            default { 'Text' }
        }
    } else { $Format }

    Log-Info -Message "Reading URLs from file: {0} (format: {1})" -Args $Path, $detectedFormat -Category 'Input'

    $urls = switch ($detectedFormat) {
        'Text'   { Get-TextFileUrls -Path $Path -MaxUrls $MaxUrls }
        'Csv'    { Get-CsvFileUrls -Path $Path -Column $Column -MaxUrls $MaxUrls }
        'Json'   { Get-JsonFileUrls -Path $Path -Column $Column -MaxUrls $MaxUrls }
        'Xml'    { Get-XmlFileUrls -Path $Path -Column $Column -MaxUrls $MaxUrls }
        'Sitemap' { Get-SitemapUrlsFromFile -Path $Path -MaxUrls $MaxUrls }
        default  { throw "Unsupported format: $detectedFormat" }
    }

    # Process each URL
    $results = @()
    $lineNum = 0
    foreach ($url in $urls) {
        $lineNum++
        if ([string]::IsNullOrWhiteSpace($url)) { continue }

        # Resolve relative URLs
        $resolvedUrl = $url
        if ($BaseUrl -and (Test-RelativeUrl $url)) {
            try {
                $resolvedUrl = ConvertTo-AbsoluteUrl -RelativeUrl $url -BaseUrl $BaseUrl
            }
            catch {
                Log-Warning -Message "Failed to resolve relative URL at line {0}: {1}" -Args $lineNum, $url -Category 'Input'
            }
        }

        $errors = @()
        $isValid = $true
        if ($Validate) {
            $validation = Test-UrlValid $resolvedUrl
            $isValid = $validation.IsValid
            $errors = $validation.Errors
        }

        $results += @{
            Url         = $resolvedUrl
            Source      = "File:$detectedFormat"
            LineNumber  = $lineNum
            IsValid     = $isValid
            Errors      = $errors
            RetrievedAt = (Get-Date).ToUniversalTime()
        }

        if ($MaxUrls -gt 0 -and $results.Count -ge $MaxUrls) { break }
    }

    return $results
}

function Get-TextFileUrls {
    param([string]$Path, [int]$MaxUrls)

    $count = 0
    switch -Regex -File $Path {
        '^\s*#' { continue }  # Skip comments
        '^\s*$' { continue }  # Skip empty lines
        default {
            $line = $_.Trim()
            if ($line -match '^https?://') {
                yield $line
                $count++
                if ($MaxUrls -gt 0 -and $count -ge $MaxUrls) { break }
            }
        }
    }
}

function Get-CsvFileUrls {
    param([string]$Path, [string]$Column, [int]$MaxUrls)

    $data = Import-Csv -Path $Path -ErrorAction Stop
    $colName = Find-ColumnName $data.PSObject.Properties.Name $Column

    $count = 0
    foreach ($row in $data) {
        $url = $row.$colName
        if ($url) {
            yield $url.Trim()
            $count++
            if ($MaxUrls -gt 0 -and $count -ge $MaxUrls) { break }
        }
    }
}

function Get-JsonFileUrls {
    param([string]$Path, [string]$Column, [int]$MaxUrls)

    $content = Get-Content -Path $Path -Raw -Encoding UTF8
    $data = $content | ConvertFrom-Json -Depth 10

    # Handle array of objects or array of strings
    $items = @()
    if ($data -is [Array]) {
        $items = $data
    }
    elseif ($data -is [PSCustomObject] -and $data.PSObject.Properties.Name -contains 'urls') {
        $items = $data.urls
    }
    else {
        $items = @($data)
    }

    $colName = if ($items.Count -gt 0 -and $items -is [PSCustomObject]) {
        Find-ColumnName $items.PSObject.Properties.Name $Column
    } else { $null }

    $count = 0
    foreach ($item in $items) {
        $url = if ($colName) { $item.$colName } else { $item }
        if ($url) {
            yield $url.ToString().Trim()
            $count++
            if ($MaxUrls -gt 0 -and $count -ge $MaxUrls) { break }
        }
    }
}

function Get-XmlFileUrls {
    param([string]$Path, [string]$Column, [int]$MaxUrls)

    $xml = [Xml](Get-Content -Path $Path -Raw)
    $nodes = $xml.SelectNodes("//*[local-name()='$Column']")
    if (-not $nodes) { $nodes = $xml.SelectNodes("//url") }
    if (-not $nodes) { $nodes = $xml.SelectNodes("//loc") }
    if (-not $nodes) { $nodes = $xml.SelectNodes("//*[contains(local-name(), 'url')]") }

    $count = 0
    foreach ($node in $nodes) {
        $url = $node.InnerText.Trim()
        if ($url) {
            yield $url
            $count++
            if ($MaxUrls -gt 0 -and $count -ge $MaxUrls) { break }
        }
    }
}

function Find-ColumnName {
    param([string[]]$Properties, [string]$Preferred)

    # Try exact match (case-insensitive)
    $match = $Properties | Where-Object { $_ -ieq $Preferred }
    if ($match) { return $match }

    # Try common variations
    $variations = @('url','URL','Url','link','Link','href','Href','address','Address','uri','URI','Uri')
    foreach ($v in $variations) {
        $match = $Properties | Where-Object { $_ -ieq $v }
        if ($match) { return $match }
    }

    # Default to first property
    return $Properties
}

#endregion

#region Sitemap & Robots.txt Processing

function Get-SitemapUrls {
    <#
    .SYNOPSIS
        Extract URLs from a sitemap (XML) or sitemap index

    .PARAMETER SitemapUrl
        URL of sitemap or sitemap index

    .PARAMETER MaxUrls
        Maximum URLs to extract

    .PARAMETER Validate
        Validate extracted URLs

    .PARAMETER FollowIndex
        Follow sitemap index references (default: $true)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [string]$SitemapUrl,

        [int]$MaxUrls = 0,

        [switch]$Validate = $true,

        [switch]$FollowIndex = $true
    )

    Log-Info -Message "Fetching sitemap: {0}" -Args $SitemapUrl -Category 'Sitemap'

    $content = Invoke-WebRequestSafe -Url $SitemapUrl -TimeoutSec 30
    if (-not $content) {
        Log-Error -Message "Failed to fetch sitemap: {0}" -Args $SitemapUrl -Category 'Sitemap'
        return @()
    }

    $results = @()
    $processedSitemaps = @()
    $queue = @($SitemapUrl)

    while ($queue.Count -gt 0 -and ($MaxUrls -eq 0 -or $results.Count -lt $MaxUrls)) {
        $currentUrl = $queue
        $queue = $queue[1..($queue.Count-1)]
        if ($processedSitemaps -contains $currentUrl) { continue }
        $processedSitemaps += $currentUrl

        $currentContent = Invoke-WebRequestSafe -Url $currentUrl -TimeoutSec 30
        if (-not $currentContent) { continue }

        $xml = [Xml]$currentContent
        $ns = @{ 'sm' = '<http://www.sitemaps.org/schemas/sitemap/0.9>' }

        # Check for sitemap index
        $sitemapNodes = $xml.SelectNodes('//sm:sitemap/sm:loc', $ns)
        if (-not $sitemapNodes) { $sitemapNodes = $xml.SelectNodes('//sitemap/loc') }

        if ($sitemapNodes -and $sitemapNodes.Count -gt 0 -and $FollowIndex) {
            foreach ($node in $sitemapNodes) {
                $childUrl = $node.InnerText.Trim()
                if (-not ($processedSitemaps -contains $childUrl)) {
                    $queue += $childUrl
                }
            }
            continue
        }

        # Extract URLs from this sitemap
        $urlNodes = $xml.SelectNodes('//sm:url/sm:loc', $ns)
        if (-not $urlNodes) { $urlNodes = $xml.SelectNodes('//url/loc') }

        foreach ($node in $urlNodes) {
            $url = $node.InnerText.Trim()
            if (-not $url) { continue }

            $errors = @()
            $isValid = $true
            if ($Validate) {
                $validation = Test-UrlValid $url
                $isValid = $validation.IsValid
                $errors = $validation.Errors
            }

            $results += @{
                Url         = $url
                Source      = 'Sitemap'
                LineNumber  = 0
                IsValid     = $isValid
                Errors      = $errors
                RetrievedAt = (Get-Date).ToUniversalTime()
            }

            if ($MaxUrls -gt 0 -and $results.Count -ge $MaxUrls) { break }
        }
    }

    return $results
}

function Get-SitemapUrlsFromFile {
    param([string]$Path, [int]$MaxUrls)

    $content = Get-Content -Path $Path -Raw
    $xml = [Xml]$content
    $ns = @{ 'sm' = '<http://www.sitemaps.org/schemas/sitemap/0.9>' }

    $urlNodes = $xml.SelectNodes('//sm:url/sm:loc', $ns)
    if (-not $urlNodes) { $urlNodes = $xml.SelectNodes('//url/loc') }

    $count = 0
    foreach ($node in $urlNodes) {
        $url = $node.InnerText.Trim()
        if ($url) {
            yield $url
            $count++
            if ($MaxUrls -gt 0 -and $count -ge $MaxUrls) { break }
        }
    }
}

function Get-RobotsTxtUrls {
    <#
    .SYNOPSIS
        Parse robots.txt for sitemap references and crawl-delay

    .PARAMETER RobotsUrl
        URL of robots.txt

    .PARAMETER MaxUrls
        Maximum sitemap URLs to return

    .OUTPUTS
        [RobotsTxtResult] with Sitemaps, CrawlDelay, DisallowPaths, AllowPaths
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [string]$RobotsUrl,

        [int]$MaxUrls = 0
    )

    Log-Info -Message "Fetching robots.txt: {0}" -Args $RobotsUrl -Category 'Robots'

    $content = Invoke-WebRequestSafe -Url $RobotsUrl -TimeoutSec 15
    if (-not $content) {
        Log-Warning -Message "Failed to fetch robots.txt: {0}" -Args $RobotsUrl -Category 'Robots'
        return @()
    }

    $sitemaps = @()
    $crawlDelay = $null
    $disallow = @()
    $allow = @()

    $lines = $content -split "`r?`n"
    $currentUserAgent = ''

    foreach ($line in $lines) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }

        if ($line -match '^User-agent:\s*(.+)$') {
            $currentUserAgent = $matches.Trim()
        }
        elseif ($line -match '^Sitemap:\s*(.+)$' -and $currentUserAgent -in @('*', '', 'Googlebot', 'Bingbot')) {
            $sitemaps += $matches.Trim()
        }
        elseif ($line -match '^Crawl-delay:\s*(\d+(?:\.\d+)?)$' -and $currentUserAgent -in @('*', '', 'Googlebot', 'Bingbot')) {
            $crawlDelay = [double]$matches
        }
        elseif ($line -match '^Disallow:\s*(.+)$') {
            $disallow += $matches.Trim()
        }
        elseif ($line -match '^Allow:\s*(.+)$') {
            $allow += $matches.Trim()
        }
    }

    # Return sitemap URLs found in robots.txt
    $results = @()
    foreach ($sitemap in $sitemaps) {
        if ($MaxUrls -gt 0 -and $results.Count -ge $MaxUrls) { break }
        $results += Get-SitemapUrls -SitemapUrl $sitemap -MaxUrls ($MaxUrls - $results.Count) -Validate:$false
    }

    return $results
}

#endregion

#region Other Input Sources

function Get-ClipboardUrls {
    param([int]$MaxUrls, [switch]$Validate)

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $text = [System.Windows.Forms.Clipboard]::GetText()
    }
    catch {
        Log-Error -Message "Cannot access clipboard: {0}" -Args $_.Exception.Message -Category 'Input'
        return @()
    }

    $urls = $text -split "`r?`n" | Where-Object { $_ -match '^https?://' } | Select-Object -First $MaxUrls
    return $urls | ForEach-Object {
        $errors = @(); $isValid = $true
        if ($Validate) { $v = Test-UrlValid $_; $isValid = $v.IsValid; $errors = $v.Errors }
        @{ Url = $_; Source = 'Clipboard'; LineNumber = 0; IsValid = $isValid; Errors = $errors; RetrievedAt = (Get-Date).ToUniversalTime() }
    }
}

function Get-StdinUrls {
    param([string]$Format, [string]$Column, [int]$MaxUrls, [switch]$Validate)

    $input = $input | ForEach-Object { $_ }  # Read pipeline
    if (-not $input) { return @() }

    $count = 0
    foreach ($line in $input) {
        $line = $line.Trim()
        if (-not $line) { continue }

        $url = $line
        if ($Format -in @('Csv','Json','Xml')) {
            # Would need proper parsing - simplified for stdin
        }

        $errors = @(); $isValid = $true
        if ($Validate) { $v = Test-UrlValid $url; $isValid = $v.IsValid; $errors = $v.Errors }

        @{ Url = $url; Source = 'Stdin'; LineNumber = ++$count; IsValid = $isValid; Errors = $errors; RetrievedAt = (Get-Date).ToUniversalTime() }

        if ($MaxUrls -gt 0 -and $count -ge $MaxUrls) { break }
    }
}

#endregion

#region Helper - Safe Web Request

function Invoke-WebRequestSafe {
    param(
        [Parameter(Mandatory)]
        [string]$Url,

        [int]$TimeoutSec = 30,

        [string]$UserAgent = 'list-gen/4.1.0'
    )

    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.Timeout = $TimeoutSec * 1000
        $request.UserAgent = $UserAgent
        $request.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate

        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
        $content = $reader.ReadToEnd()
        $reader.Close()
        $response.Close()
        return $content
    }
    catch {
        Log-Debug -Message "Web request failed for {0}: {1}" -Args $Url, $_.Exception.Message -Category 'Network'
        return $null
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-UrlInput',
    'Get-FileUrls',
    'Get-SitemapUrls',
    'Get-RobotsTxtUrls',
    'Get-ClipboardUrls',
    'Invoke-WebRequestSafe'
)