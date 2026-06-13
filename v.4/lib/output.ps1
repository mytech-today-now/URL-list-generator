<#
.SYNOPSIS
    Output formatting and export functions for list-gen

.DESCRIPTION
    Exports URL lists to multiple formats: CSV, JSON, JSONL, XML, TXT, HTML, Excel (via CSV),
    Sitemap XML, and custom formats. Supports streaming for large datasets.
#>

Set-StrictMode -Version Latest

#region Public Functions - Export

function Export-UrlList {
    <#
    .SYNOPSIS
        Export URL list to file in specified format

    .DESCRIPTION
        Exports URL collections to various formats with options for compression,
        custom fields, and streaming large datasets.

    .PARAMETER InputObject
        URLs to export (pipeline input, array, or CrawlResult/UrlInfo objects)

    .PARAMETER Path
        Output file path

    .PARAMETER Format
        Output format: Csv, Json, Jsonl, Xml, Txt, Html, Sitemap, Excel (default: Csv)

    .PARAMETER Properties
        Properties to include (default: all). Use '*' for all, or comma-separated list.

    .PARAMETER NoHeader
        Omit header row (CSV/TXT)

    .PARAMETER Delimiter
        Field delimiter for CSV/TXT (default: ',')

    .PARAMETER Encoding
        File encoding (default: UTF8NoBOM)

    .PARAMETER Compress
        Compress output with GZip

    .PARAMETER Append
        Append to existing file

    .PARAMETER Force
        Overwrite existing file

    .PARAMETER WhatIf
        Show what would be exported without writing

    .EXAMPLE
        Get-UrlList 'https://example.com' | Export-UrlList -Path './urls.csv' -Format Csv

    .EXAMPLE
        $urls | Export-UrlList -Path './urls.json' -Format Json -Properties Url,Depth,StatusCode

    .EXAMPLE
        $crawlResults | Export-UrlList -Path './sitemap.xml' -Format Sitemap
    #>
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyCollection()]
        [object[]]$InputObject,

        [Parameter(Mandatory, Position=0)]
        [string]$Path,

        [ValidateSet('Csv','Json','Jsonl','Xml','Txt','Html','Sitemap','Excel','Markdown')]
        [string]$Format = 'Csv',

        [string[]]$Properties = @('*'),

        [switch]$NoHeader,

        [string]$Delimiter = ',',

        [ValidateSet('ASCII','UTF7','UTF8','UTF8NoBOM','UTF32','Unicode','BigEndianUnicode','Default','OEM')]
        [string]$Encoding = 'UTF8NoBOM',

        [switch]$Compress,

        [switch]$Append,

        [switch]$Force,

        [switch]$WhatIf
    )

    begin {
        $items = @()
        $exportPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $dir = Split-Path $exportPath -Parent
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }

        if (Test-Path $exportPath -and -not $Force -and -not $Append) {
            throw "File exists: $exportPath (use -Force to overwrite or -Append to append)"
        }
    }

    process {
        foreach ($item in $InputObject) {
            $items += $item
        }
    }

    end {
        if ($items.Count -eq 0) {
            Log-Warning -Message "No items to export" -Category 'Export'
            return
        }

        # Normalize items to consistent objects
        $normalized = Normalize-ExportItems -Items $items -Properties $Properties

        if ($WhatIf) {
            Write-Host "Would export $($normalized.Count) items to $exportPath as $Format"
            return
        }

        # Dispatch to format-specific exporter
        switch ($Format) {
            'Csv'      { Export-CsvFormat -Items $normalized -Path $exportPath -Delimiter $Delimiter -NoHeader:$NoHeader -Encoding $Encoding -Append:$Append -Compress:$Compress }
            'Json'     { Export-JsonFormat -Items $normalized -Path $exportPath -Encoding $Encoding -Compress:$Compress -Append:$Append }
            'Jsonl'    { Export-JsonlFormat -Items $normalized -Path $exportPath -Encoding $Encoding -Compress:$Compress -Append:$Append }
            'Xml'      { Export-XmlFormat -Items $normalized -Path $exportPath -Encoding $Encoding -Compress:$Compress }
            'Txt'      { Export-TxtFormat -Items $normalized -Path $exportPath -Delimiter $Delimiter -NoHeader:$NoHeader -Encoding $Encoding -Append:$Append -Compress:$Compress }
            'Html'     { Export-HtmlFormat -Items $normalized -Path $exportPath -Encoding $Encoding -Compress:$Compress }
            'Sitemap'  { Export-SitemapFormat -Items $normalized -Path $exportPath -Encoding $Encoding -Compress:$Compress }
            'Excel'    { Export-ExcelFormat -Items $normalized -Path $exportPath -Encoding $Encoding -Compress:$Compress }
            'Markdown' { Export-MarkdownFormat -Items $normalized -Path $exportPath -Encoding $Encoding -Compress:$Compress }
            default    { throw "Unsupported format: $Format" }
        }

        Log-Info -Message "Exported {0} items to {1} ({2})" -Args $normalized.Count, $exportPath, $Format -Category 'Export'
    }
}

function Normalize-ExportItems {
    param($Items, [string[]]$Properties)

    $includeAll = $Properties -contains '*'
    $result = @()

    foreach ($item in $Items) {
        $obj = [pscustomobject]@{}

        $propsToExport = if ($includeAll) { $item.PSObject.Properties.Name } else { $Properties }

        foreach ($prop in $propsToExport) {
            if ($item.PSObject.Properties[$prop]) {
                $val = $item.$prop
                # Convert complex types to strings
                if ($val -is [DateTime]) { $val = $val.ToString('o') }
                elseif ($val -is [Uri]) { $val = $val.AbsoluteUri }
                elseif ($val -is [Collections.IDictionary]) { $val = ($val.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ' }
                elseif ($val -is [Array] -or $val -is [Collections.IList]) { $val = $val -join '; ' }
                $obj | Add-Member -NotePropertyName $prop -NotePropertyValue $val -Force
            }
        }
        $result.Add($obj)
    }

    return $result
}

#region Format-Specific Exporters

function Export-CsvFormat {
    param([List[psobject]]$Items, [string]$Path, [string]$Delimiter, [switch]$NoHeader, [string]$Encoding, [switch]$Append, [switch]$Compress)

    $EncodingObj = Get-Encoding $Encoding
    $mode = if ($Compress) {
        $fs = [IO.FileStream]::new($Path + '.gz', [IO.FileMode]::Create, [IO.FileAccess]::Write)
        [IO.Compression.GZipStream]::new($fs, [IO.Compression.CompressionMode]::Compress)
    } else {
        $fileMode = if ($Append) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
        [IO.FileStream]::new($Path, $fileMode, [IO.FileAccess]::Write)
    }

    try {
        $writer = [IO.StreamWriter]::new($mode, $EncodingObj)
        $writer.AutoFlush = $true

        if (-not $NoHeader -and (-not $Append -or (Test-Path $Path -and (Get-Item $Path).Length -eq 0))) {
            $headers = $Items[0].PSObject.Properties.Name -join $Delimiter
            $writer.WriteLine($headers)
        }

        foreach ($item in $Items) {
            $values = $item.PSObject.Properties.Value | ForEach-Object {
                $str = if ($_ -eq $null) { '' } else { $_.ToString() }
                # Escape for CSV
                if ($str -match '[\",\r\n]') {
                    '"' + $str.Replace('"', '""') + '"'
                } else { $str }
            }
            $writer.WriteLine(($values -join $Delimiter))
        }
    }
    finally {
        if ($writer) { $writer.Dispose() }
        if ($mode) { $mode.Dispose() }
    }
}

function Export-JsonFormat {
    param([List[psobject]]$Items, [string]$Path, [string]$Encoding, [switch]$Compress, [switch]$Append)

    $json = $Items | ConvertTo-Json -Depth 5 -Compress
    Write-EncodedFile -Path $Path -Content $json -Encoding $Encoding -Compress:$Compress -Append:$Append
}

function Export-JsonlFormat {
    param([List[psobject]]$Items, [string]$Path, [string]$Encoding, [switch]$Compress, [switch]$Append)

    $stream = Open-OutputStream -Path $Path -Encoding $Encoding -Compress:$Compress -Append:$Append
    try {
        $writer = [IO.StreamWriter]::new($stream, Get-Encoding $Encoding)
        $writer.AutoFlush = $true
        foreach ($item in $Items) {
            $json = $item | ConvertTo-Json -Depth 5 -Compress
            $writer.WriteLine($json)
        }
    }
    finally {
        if ($writer) { $writer.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Export-XmlFormat {
    param([List[psobject]]$Items, [string]$Path, [string]$Encoding, [switch]$Compress)

    $xml = [Xml]::new()
    $root = $xml.CreateElement('UrlList')
    $xml.AppendChild($root) | Out-Null

    foreach ($item in $Items) {
        $urlEl = $xml.CreateElement('Url')
        foreach ($prop in $item.PSObject.Properties) {
            $child = $xml.CreateElement($prop.Name)
            $val = if ($prop.Value) { $prop.Value.ToString() } else { '' }
            $child.InnerText = $val
            $urlEl.AppendChild($child) | Out-Null
        }
        $root.AppendChild($urlEl) | Out-Null
    }

    $xml.Save($Path)
    if ($Compress) {
        Compress-File $Path
    }
}

function Export-TxtFormat {
    param([List[psobject]]$Items, [string]$Path, [string]$Delimiter, [switch]$NoHeader, [string]$Encoding, [switch]$Append, [switch]$Compress)

    Export-CsvFormat @PSBoundParameters
}

function Export-HtmlFormat {
    param([List[psobject]]$Items, [string]$Path, [string]$Encoding, [switch]$Compress)

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>URL List Export - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 2rem; line-height: 1.6; }
        table { border-collapse: collapse; width: 100%; margin-top: 1rem; }
        th, td { border: 1px solid #ddd; padding: 0.75rem; text-align: left; }
        th { background: #f5f5f5; font-weight: 600; position: sticky; top: 0; }
        tr:nth-child(even) { background: #fafafa; }
        tr:hover { background: #f0f7ff; }
        a { color: #0066cc; text-decoration: none; }
        a:hover { text-decoration: underline; }
        .meta { color: #666; font-size: 0.9rem; margin-bottom: 1rem; }
        .count { font-weight: bold; color: #333; }
    </style>
</head>
<body>
    <h1>URL List Export</h1>
    <div class="meta">Generated: $(Get-Date -Format 'o') | Count: <span class="count">$($Items.Count)</span></div>
    <table>
        <thead><tr>
"@

    $headers = $Items[0].PSObject.Properties.Name
    $html += ($headers | ForEach-Object { "            <th>$($_)</th>" }) -join "`n"
    $html += @"
        </tr></thead>
        <tbody>
"@

    foreach ($item in $Items) {
        $html += "        <tr>"
        foreach ($prop in $item.PSObject.Properties) {
            $val = if ($prop.Value) { $prop.Value.ToString() } else { '' }
            $cell = [System.Web.HttpUtility]::HtmlEncode($val)
            # Make URLs clickable
            if ($prop.Name -eq 'Url' -and $val -match '^https?://') {
                $cell = "<a href='$val' target='_blank' rel='noopener'>$cell</a>"
            }
            $html += "<td>$cell</td>"
        }
        $html += "</tr>"
    }

    $html += @"
        </tbody>
    </table>
</body>
</html>
"@

    Write-EncodedFile -Path $Path -Content $html -Encoding $Encoding -Compress:$Compress
}

function Export-SitemapFormat {
    param([List[psobject]]$Items, [string]$Path, [string]$Encoding, [switch]$Compress)

    $xml = [Xml]::new()
    $xml.AppendChild($xml.CreateXmlDeclaration('1.0', 'UTF-8', $null)) | Out-Null

    $urlset = $xml.CreateElement('urlset')
    $urlset.SetAttribute('xmlns', 'http://www.sitemaps.org/schemas/sitemap/0.9')
    $urlset.SetAttribute('xmlns:xhtml', 'http://www.w3.org/1999/xhtml')
    $xml.AppendChild($urlset) | Out-Null

    foreach ($item in $Items) {
        $url = if ($item.Url) { $item.Url } elseif ($item.url) { $item.url } else { '' }
        if (-not $url) { continue }

        $urlEl = $xml.CreateElement('url')
        $loc = $xml.CreateElement('loc')
        $loc.InnerText = $url
        $urlEl.AppendChild($loc) | Out-Null

        # Optional fields
        $lastMod = if ($item.LastMod) { $item.LastMod } elseif ($item.LastModified) { $item.LastModified } else { $null }
        if ($lastMod) {
            $lm = $xml.CreateElement('lastmod')
            $lm.InnerText = $lastMod.ToString('yyyy-MM-dd')
            $urlEl.AppendChild($lm) | Out-Null
        }
        $changeFreq = if ($item.ChangeFreq) { $item.ChangeFreq } elseif ($item.ChangeFrequency) { $item.ChangeFrequency } else { $null }
        if ($changeFreq) {
            $cf = $xml.CreateElement('changefreq')
            $cf.InnerText = $changeFreq
            $urlEl.AppendChild($cf) | Out-Null
        }
        if ($item.Priority) {
            $pr = $xml.CreateElement('priority')
            $pr.InnerText = [string]$item.Priority
            $urlEl.AppendChild($pr) | Out-Null
        }

        $urlset.AppendChild($urlEl) | Out-Null
    }

    $settings = [Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $settings.Encoding = Get-Encoding $Encoding
    $settings.OmitXmlDeclaration = $false

    $writer = [Xml.XmlWriter]::Create($Path, $settings)
    $xml.Save($writer)
    $writer.Close()

    if ($Compress) {
        Compress-File $Path
    }
}

function Export-ExcelFormat {
    param([List[psobject]]$Items, [string]$Path, [string]$Encoding, [switch]$Compress)

    # Excel can open CSV directly. Export as CSV with .xlsx extension
    $csvPath = [IO.Path]::ChangeExtension($Path, '.csv')
    Export-CsvFormat -Items $Items -Path $csvPath -Delimiter ',' -Encoding $Encoding -NoHeader:$false
    Move-Item $csvPath $Path -Force

    if ($Compress) {
        Compress-File $Path
    }
}

function Export-MarkdownFormat {
    param([List[psobject]]$Items, [string]$Path, [string]$Encoding, [switch]$Compress)

    $headers = $Items[0].PSObject.Properties.Name
    $md = "| $($headers -join ' | ') |\n"
    $md += "| $($headers | ForEach-Object { '---' }) -join ' | ') |\n"

    foreach ($item in $Items) {
        $row = $item.PSObject.Properties.Value | ForEach-Object {
            $str = if ($_ -eq $null) { '' } else { $_.ToString().Replace('|', '\|') }
            $str
        }
        $md += "| $($row -join ' | ') |\n"
    }

    Write-EncodedFile -Path $Path -Content $md -Encoding $Encoding -Compress:$Compress
}

#endregion

#region Helpers

function Get-Encoding {
    param([string]$Name)
    switch ($Name) {
        'UTF8NoBOM' { return [System.Text.UTF8Encoding]::new($false) }
        'UTF8'      { return [System.Text.UTF8Encoding]::new($true) }
        'ASCII'     { return [System.Text.ASCIIEncoding]::new() }
        'UTF7'      { return [System.Text.UTF7Encoding]::new() }
        'UTF32'     { return [System.Text.UTF32Encoding]::new() }
        'Unicode'   { return [System.Text.UnicodeEncoding]::new() }
        'BigEndianUnicode' { return [System.Text.UnicodeEncoding]::new($true, $true) }
        'Default'   { return [System.Text.Encoding]::Default }
        'OEM'       { return [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
        default     { return [System.Text.Encoding]::GetEncoding($Name) }
    }
}

function Write-EncodedFile {
    param([string]$Path, [string]$Content, [string]$Encoding, [switch]$Compress, [switch]$Append)

    $stream = Open-OutputStream -Path $Path -Encoding $Encoding -Compress:$Compress -Append:$Append
    try {
        $writer = [IO.StreamWriter]::new($stream, Get-Encoding $Encoding)
        $writer.Write($Content)
    }
    finally {
        if ($writer) { $writer.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Open-OutputStream {
    param([string]$Path, [string]$Encoding, [switch]$Compress, [switch]$Append)

    if ($Append) { $mode = [IO.FileMode]::Append } else { $mode = [IO.FileMode]::Create }
    $fs = [IO.FileStream]::new($Path, $mode, [IO.FileAccess]::Write)

    if ($Compress) {
        return [IO.Compression.GZipStream]::new($fs, [IO.Compression.CompressionMode]::Compress)
    }
    return $fs
}

function Compress-File {
    param([string]$Path)
    $source = [IO.File]::OpenRead($Path)
    $dest = [IO.File]::Create($Path + '.gz')
    $gzip = [IO.Compression.GZipStream]::new($dest, [IO.Compression.CompressionMode]::Compress)
    $source.CopyTo($gzip)
    $gzip.Close()
    $dest.Close()
    $source.Close()
    Move-Item ($Path + '.gz') $Path -Force
}

#endregion

#region Console Output Formatting

function Format-UrlTable {
    <#
    .SYNOPSIS
        Format URLs as a pretty console table

    .PARAMETER InputObject
        URLs to format

    .PARAMETER Properties
        Properties to display

    .PARAMETER MaxWidth
        Maximum column width (default: auto)

    .EXAMPLE
        $urls | Format-UrlTable -Properties Url,Depth,StatusCode
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$InputObject,

        [string[]]$Properties = @('Url', 'Depth', 'StatusCode', 'Attribute'),

        [int]$MaxWidth = 120
    )

    begin {
        $items = @()
    }
    process { $items += $InputObject }
    end {
        if (-not $items) { return }

        # Calculate column widths
        $widths = @{}
        foreach ($prop in $Properties) {
            $maxLen = $prop.Length
            foreach ($item in $items) {
                $val = ($item.$prop).ToString()
                if ($val.Length -gt $maxLen) { $maxLen = $val.Length }
            }
            $widths[$prop] = [Math]::Min($maxLen, 80)
        }

        # Header
        $header = $Properties | ForEach-Object { $_.PadRight($widths[$_]) } -join ' | '
        $sep = $Properties | ForEach-Object { '-' * $widths[$_] } -join '-+-'

        Write-Host $header -ForegroundColor Cyan
        Write-Host $sep -ForegroundColor DarkGray

        # Rows
        foreach ($item in $items) {
            $row = $Properties | ForEach-Object {
                $val = ($item.$_).ToString()
                if ($val.Length -gt $widths[$_]) { $val = $val.Substring(0, $widths[$_]-3) + '...' }
                $val.PadRight($widths[$_])
            } -join ' | '
            Write-Host $row
        }

        Write-Host "Total: $($items.Count) items" -ForegroundColor Green
    }
}

function Format-UrlTree {
    <#
    .SYNOPSIS
        Display URLs as a tree structure by domain/path

    .PARAMETER InputObject
        URLs to display

    .PARAMETER MaxDepth
        Maximum tree depth to display

    .EXAMPLE
        $crawlResults | Format-UrlTree
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$InputObject,

        [int]$MaxDepth = 5
    )

    begin { $items = @() }
    process { $items += $InputObject }
    end {
        if (-not $items) { return }

        $tree = @{}
        foreach ($item in $items) {
            $url = $item.Url
            try {
                $uri = [Uri]::new($url)
                $host = $uri.Host
                $path = $uri.AbsolutePath.Trim('/')
                $segments = if ($path) { $path -split '/' } else { @() }

                $current = $tree
                if (-not $current.ContainsKey($host)) { $current[$host] = @{} }
                $current = $current[$host]

                for ($i = 0; $i -lt [Math]::Min($segments.Count, $MaxDepth); $i++) {
                    $seg = $segments[$i]
                    if (-not $current.ContainsKey($seg)) { $current[$seg] = @{} }
                    $current = $current[$seg]
                }
            }
            catch { }
        }

        Write-UrlTree -Tree $tree -Indent 0
    }
}

function Write-UrlTree {
    param([hashtable]$Tree, [int]$Indent)

    foreach ($key in $Tree.Keys | Sort-Object) {
        $prefix = '  ' * $Indent
        $hasChildren = $Tree[$key].Count -gt 0
        $marker = if ($hasChildren) { '📁' } else { '📄' }
        Write-Host "$prefix$marker $key" -ForegroundColor (if ($hasChildren) { 'Yellow' } else { 'Green' })
        if ($hasChildren) {
            Write-UrlTree -Tree $Tree[$key] -Indent ($Indent + 1)
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Export-UrlList',
    'Format-UrlTable',
    'Format-UrlTree',
    'Normalize-ExportItems'
)