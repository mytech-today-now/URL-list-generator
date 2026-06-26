<#
.SYNOPSIS
    Unit tests for list-gen module

.DESCRIPTION
    Validates core functionality: regex patterns, URL normalization, extraction,
    validation, and export. Run with Pester or directly.
#>

Set-StrictMode -Version Latest

# Import module for testing
$modulePath = Join-Path $PSScriptRoot '..' 'list-gen.psd1'
if (Test-Path $modulePath) {
    Import-Module $modulePath -Force
}
else {
    Write-Error "Module not found at $modulePath"
    exit 1
}

$testResults = @()

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message. Expected: $Expected, Actual: $Actual"
    }
}

function Assert-True {
    param($Condition, [string]$Message)
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Null {
    param($Value, [string]$Message)
    if ($Value -ne $null) {
        throw "Assertion failed: $Message. Expected null, got: $Value"
    }
}

function Run-Test {
    param([string]$Name, [scriptblock]$TestBlock)
    Write-Host "Testing: $Name" -NoNewline
    try {
        & $TestBlock
        Write-Host " [PASS]" -ForegroundColor Green
        $testResults += @{ Name = $Name; Passed = $true; Error = $null }
    }
    catch {
        Write-Host " [FAIL]" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        $testResults += @{ Name = $Name; Passed = $false; Error = $_.Exception.Message }
    }
}

#region Regex Pattern Tests

Run-Test "Href regex - double quoted" {
    $html = '<a href="https://example.com">Link</a>'
    $urls = Extract-UrlsFromHtml -Html $html -BaseUrl 'https://base.com'
    Assert-Equal 1 $urls.Count
    Assert-Equal 'https://example.com' $urls[0].Url
}

Run-Test "Href regex - single quoted" {
    $html = "<a href='https://example.com'>Link</a>"
    $urls = Extract-UrlsFromHtml -Html $html -BaseUrl 'https://base.com'
    Assert-Equal 1 $urls.Count
    Assert-Equal 'https://example.com' $urls[0].Url
}

Run-Test "Href regex - unquoted" {
    $html = '<a href=https://example.com>Link</a>'
    $urls = Extract-UrlsFromHtml -Html $html -BaseUrl 'https://base.com'
    Assert-Equal 1 $urls.Count
    Assert-Equal 'https://example.com' $urls[0].Url
}

Run-Test "Href regex - case insensitive" {
    $html = '<A HREF="https://example.com">Link</A>'
    $urls = Extract-UrlsFromHtml -Html $html -BaseUrl 'https://base.com'
    Assert-Equal 1 $urls.Count
    Assert-Equal 'https://example.com' $urls[0].Url
}

Run-Test "Href regex - whitespace handling" {
    $html = '<a  href  =  "https://example.com"  >Link</a>'
    $urls = Extract-UrlsFromHtml -Html $html -BaseUrl 'https://base.com'
    Assert-Equal 1 $urls.Count
    Assert-Equal 'https://example.com' $urls[0].Url
}

Run-Test "Href regex - javascript URL filtered" {
    $html = '<a href="javascript:alert(1)">XSS</a>'
    $urls = Extract-UrlsFromHtml -Html $html -BaseUrl 'https://base.com'
    Assert-Equal 0 $urls.Count
}

Run-Test "Href regex - data URL filtered" {
    $html = '<img src="data:image/png;base64,abc123">'
    $urls = Extract-UrlsFromHtml -Html $html -BaseUrl 'https://base.com'
    Assert-Equal 0 $urls.Count
}

Run-Test "Src attribute extraction" {
    $html = '<img src="https://example.com/image.png">'
    $urls = Extract-UrlsFromHtml -Html $html -BaseUrl 'https://base.com' -Attributes @('src')
    Assert-Equal 1 $urls.Count
    Assert-Equal 'https://example.com/image.png' $urls[0].Url
    Assert-Equal 'src' $urls[0].Attribute
}

Run-Test "Multiple attributes extraction" {
    $html = '<a href="https://example.com/page"><img src="https://example.com/img.jpg" data-src="https://example.com/img2.jpg"></a>'
    $urls = Extract-UrlsFromHtml -Html $html -BaseUrl 'https://base.com' -Attributes @('href','src','data-src')
    Assert-Equal 3 $urls.Count
}

#endregion

#region URL Normalization Tests

Run-Test "Normalize - lowercase scheme and host" {
    $result = Normalize-Url 'HTTPS://EXAMPLE.COM/Path'
    Assert-Equal 'https://example.com/Path' $result
}

Run-Test "Normalize - remove default port" {
    $result = Normalize-Url 'https://example.com:443/path'
    Assert-Equal 'https://example.com/path' $result
    $result = Normalize-Url 'http://example.com:80/path'
    Assert-Equal 'http://example.com/path' $result
}

Run-Test "Normalize - keep non-default port" {
    $result = Normalize-Url 'https://example.com:8443/path'
    Assert-Equal 'https://example.com:8443/path' $result
}

Run-Test "Normalize - remove dot segments" {
    $result = Normalize-Url 'https://example.com/a/b/../c/./d'
    Assert-Equal 'https://example.com/a/c/d' $result
    $result = Normalize-Url 'https://example.com/../path'
    Assert-Equal 'https://example.com/path' $result
}

Run-Test "Normalize - sort query parameters" {
    $result = Normalize-Url 'https://example.com/path?b=2&a=1&c=3'
    Assert-Equal 'https://example.com/path?a=1&b=2&c=3' $result
}

Run-Test "Normalize - remove fragment" {
    $result = Normalize-Url 'https://example.com/path#section' -RemoveFragment
    Assert-Equal 'https://example.com/path' $result
}

Run-Test "Normalize - preserve fragment by default" {
    $result = Normalize-Url 'https://example.com/path#section'
    Assert-Equal 'https://example.com/path#section' $result
}

Run-Test "Normalize - invalid URL returns null" {
    $result = Normalize-Url 'not-a-url'
    Assert-Null $result
}

#endregion

#region URL Validation Tests

Run-Test "Test-UrlValid - valid HTTPS" {
    $result = Test-UrlValid 'https://example.com/path?query=1'
    Assert-True $result.IsValid
    Assert-Equal 'https://example.com/path?query=1' $result.NormalizedUrl
}

Run-Test "Test-UrlValid - valid HTTP" {
    $result = Test-UrlValid 'http://example.com'
    Assert-True $result.IsValid
}

Run-Test "Test-UrlValid - invalid scheme" {
    $result = Test-UrlValid 'ftp://example.com'
    Assert-True (-not $result.IsValid)
    Assert-True ($result.Errors.Count -gt 0)
}

Run-Test "Test-UrlValid - missing host" {
    $result = Test-UrlValid 'https:///path'
    Assert-True (-not $result.IsValid)
}

Run-Test "Test-UrlValid - empty string" {
    $result = Test-UrlValid ''
    Assert-True (-not $result.IsValid)
}

Run-Test "Test-UrlValid - relative URL" {
    $result = Test-UrlValid '/path/to/page'
    Assert-True (-not $result.IsValid)
}

Run-Test "Test-UrlValid - IP address host" {
    $result = Test-UrlValid 'http://192.168.1.1'
    Assert-True $result.IsValid
}

Run-Test "Test-UrlValid - localhost" {
    $result = Test-UrlValid 'http://localhost:8080'
    Assert-True $result.IsValid
}

#endregion

#region Relative URL Resolution Tests

Run-Test "ConvertTo-AbsoluteUrl - relative path" {
    $result = ConvertTo-AbsoluteUrl '/page.html' 'https://example.com/base/'
    Assert-Equal 'https://example.com/page.html' $result
}

Run-Test "ConvertTo-AbsoluteUrl - relative with directory" {
    $result = ConvertTo-AbsoluteUrl 'sub/page.html' 'https://example.com/base/'
    Assert-Equal 'https://example.com/base/sub/page.html' $result
}

Run-Test "ConvertTo-AbsoluteUrl - parent directory" {
    $result = ConvertTo-AbsoluteUrl '../other.html' 'https://example.com/base/dir/'
    Assert-Equal 'https://example.com/other.html' $result
}

Run-Test "ConvertTo-AbsoluteUrl - protocol relative" {
    $result = ConvertTo-AbsoluteUrl '//cdn.example.com/script.js' 'https://example.com/page'
    Assert-Equal 'https://cdn.example.com/script.js' $result
}

Run-Test "ConvertTo-AbsoluteUrl - fragment only" {
    $result = ConvertTo-AbsoluteUrl '#section' 'https://example.com/page'
    Assert-Equal 'https://example.com/page#section' $result
}

Run-Test "ConvertTo-AbsoluteUrl - already absolute" {
    $result = ConvertTo-AbsoluteUrl 'https://other.com/page' 'https://example.com/base/'
    Assert-Equal 'https://other.com/page' $result
}

#endregion

#region Pattern Matching Tests

Run-Test "Select-UrlPattern - wildcard match" {
    $urls = @('https://example.com/blog/post1', 'https://example.com/news/item', 'https://example.com/blog/post2')
    $result = $urls | Select-UrlPattern -Pattern '*blog*'
    Assert-Equal 2 $result.Count
}

Run-Test "Select-UrlPattern - wildcard exclude" {
    $urls = @('https://example.com/blog/post1', 'https://example.com/news/item')
    $result = $urls | Select-UrlPattern -Pattern '*blog*' -NotMatch
    Assert-Equal 1 $result.Count
    Assert-Equal 'https://example.com/news/item' $result[0]
}

Run-Test "Select-UrlPattern - regex match" {
    $urls = @('https://example.com/api/v1/users', 'https://example.com/api/v2/posts', 'https://example.com/web/page')
    $result = $urls | Select-UrlPattern -Pattern '^/api/v\d+' -Regex
    Assert-Equal 2 $result.Count
}

Run-Test "Select-UrlPattern - case sensitive" {
    $urls = @('https://example.com/BLOG', 'https://example.com/blog')
    $result = $urls | Select-UrlPattern -Pattern '*BLOG*' -CaseSensitive
    Assert-Equal 1 $result.Count
    Assert-Equal 'https://example.com/BLOG' $result[0]
}

#endregion

#region Input Processing Tests

Run-Test "Get-UrlInput - single URL" {
    $result = Get-UrlInput -Source 'https://example.com'
    Assert-Equal 1 $result.Count
    Assert-Equal 'https://example.com' $result[0].Url
}

Run-Test "Get-UrlInput - text file" {
    $testFile = Join-Path $env:TEMP 'test-urls.txt'
    @'
https://example.com/1
https://example.com/2
# comment
https://example.com/3
'@ | Set-Content $testFile -Encoding UTF8
    $result = Get-UrlInput -Source $testFile -Format Text
    Assert-Equal 3 $result.Count
    Remove-Item $testFile
}

Run-Test "Get-UrlInput - CSV file" {
    $testFile = Join-Path $env:TEMP 'test-urls.csv'
    @"
url,name
https://example.com/1,Site 1
https://example.com/2,Site 2
"@ | Set-Content $testFile -Encoding UTF8
    $result = Get-UrlInput -Source $testFile -Format Csv
    Assert-Equal 2 $result.Count
    Remove-Item $testFile
}

Run-Test "Get-UrlInput - JSON file" {
    $testFile = Join-Path $env:TEMP 'test-urls.json'
    @'
[
  {"url": "https://example.com/1", "name": "Site 1"},
  {"url": "https://example.com/2", "name": "Site 2"}
]
'@ | Set-Content $testFile -Encoding UTF8
    $result = Get-UrlInput -Source $testFile -Format Json
    Assert-Equal 2 $result.Count
    Remove-Item $testFile
}

#endregion

#region Export Tests

Run-Test "Export-UrlList - CSV format" {
    $urls = @('https://example.com/1', 'https://example.com/2')
    $testPath = Join-Path $env:TEMP 'test-export.csv'
    Export-UrlList -InputObject $urls -Path $testPath -Format Csv
    Assert-True (Test-Path $testPath)
    $content = Get-Content $testPath -Raw
    Assert-True ($content -match 'https://example.com/1')
    Remove-Item $testPath
}

Run-Test "Export-UrlList - JSON format" {
    $urls = @('https://example.com/1', 'https://example.com/2')
    $testPath = Join-Path $env:TEMP 'test-export.json'
    Export-UrlList -InputObject $urls -Path $testPath -Format Json
    Assert-True (Test-Path $testPath)
    $content = Get-Content $testPath -Raw
    Assert-True ($content -match 'https://example.com/1')
    Remove-Item $testPath
}

Run-Test "Export-UrlList - JSONL format" {
    $urls = @('https://example.com/1', 'https://example.com/2')
    $testPath = Join-Path $env:TEMP 'test-export.jsonl'
    Export-UrlList -InputObject $urls -Path $testPath -Format Jsonl
    Assert-True (Test-Path $testPath)
    $lines = Get-Content $testPath
    Assert-Equal 2 $lines.Count
    Remove-Item $testPath
}

Run-Test "Export-UrlList - Sitemap format" {
    $items = @(
        [pscustomobject]@{ Url = 'https://example.com/1'; LastMod = (Get-Date).AddDays(-1); ChangeFreq = 'weekly'; Priority = 0.8 },
        [pscustomobject]@{ Url = 'https://example.com/2'; LastMod = (Get-Date); ChangeFreq = 'daily'; Priority = 0.5 }
    )
    $testPath = Join-Path $env:TEMP 'test-sitemap.xml'
    Export-UrlList -InputObject $items -Path $testPath -Format Sitemap
    Assert-True (Test-Path $testPath)
    $content = Get-Content $testPath -Raw
    Assert-True ($content -match '<loc>https://example.com/1</loc>')
    Assert-True ($content -match '<lastmod>')
    Assert-True ($content -match '<changefreq>weekly</changefreq>')
    Assert-True ($content -match '<priority>0.8</priority>')
    Remove-Item $testPath
}

#endregion

#region Edge Case Tests

Run-Test "Malformed HTML - missing quotes" {
    $html = '<a href=https://example.com>Link</a><img src=image.jpg>'
    $urls = Extract-UrlsFromHtml -Html $html -BaseUrl 'https://base.com'
    Assert-Equal 2 $urls.Count
}

Run-Test "Malformed HTML - mixed case attributes" {
    $html = '<A HrEf="https://example.com">Link</A>'
    $urls = Extract-UrlsFromHtml -Html $html -BaseUrl 'https://base.com'
    Assert-Equal 1 $urls.Count
}

Run-Test "International domain names" {
    $result = Normalize-Url 'https://例え.テスト/path'
    Assert-True ($result -match 'xn--')
}

Run-Test "Unicode in path" {
    $result = Normalize-Url 'https://example.com/パス/ページ'
    Assert-True ($result -match '%')
}

Run-Test "Very long URL" {
    $longPath = ('a' * 2000)
    $url = "https://example.com/$longPath"
    $result = Normalize-Url $url
    Assert-True ($result.Length -gt 2000)
}

Run-Test "Multiple slashes normalization" {
    $result = Normalize-Url 'https://example.com///path//to///page'
    Assert-Equal 'https://example.com/path/to/page' $result
}

Run-Test "Empty path becomes root" {
    $result = Normalize-Url 'https://example.com'
    Assert-Equal 'https://example.com/' $result
}

#endregion

# Summary
Write-Host ""
Write-Host "============ Test Summary ============"
$passed = ($testResults | Where-Object { $_.Passed }).Count
$failed = ($testResults | Where-Object { -not $_.Passed }).Count
$total = $testResults.Count
Write-Host "Total: $total | Passed: $passed | Failed: $failed"
if ($failed -gt 0) {
    Write-Host "Failed tests:" -ForegroundColor Red
    $testResults | Where-Object { -not $_.Passed } | ForEach-Object { Write-Host "  - $($_.Name): $($_.Error)" -ForegroundColor Red }
    exit 1
}
else {
    Write-Host "All tests passed!" -ForegroundColor Green
    exit 0
}