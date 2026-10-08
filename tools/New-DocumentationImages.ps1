#Requires -Version 7.4
<#
.SYNOPSIS
    Renders the graphics of the GitHub README (package\docs\images\readme-*.png) from the administrator guide.

.DESCRIPTION
    GitHub renders Markdown only: the custom blocks of the guide (cards, flow) and its theme are lost.
    This tool renders them as images, with the CSS of the built HTML guide and the icons of
    tools\Build-Documentation.ps1, in a light and a dark version (2x resolution), so that the README
    and the guide always look the same. The README chooses the version with <picture>.

        readme-banner     the hero of the guide, with three key figures
        readme-why        what the companion brings (cards block "One report, many views", chapter 1)
        readme-how        the publication pipeline (first flow block, chapter 2) and who sees what
        readme-agent      the agent in Microsoft Teams (flow block "Microsoft Teams", chapter 2) and the
                          answer format (cards block "Title and scope", chapter 11)

    The screenshots (report-*.png and teams-*.png) are not produced here: they are taken from the real
    report and the real agent in Teams on a demonstration tenant with fictitious personas.

.PARAMETER OutputFolder
    Default: package\docs\images next to the tools folder.

.PARAMETER KeepWork
    Keeps the work folder (HTML pages of the graphics) and shows its path.

.EXAMPLE
    .\tools\Build-Documentation.ps1 ; .\tools\New-DocumentationImages.ps1
    The guide is built first: its HTML holds the CSS of the graphics.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.3.0
    Part of : Purview DLP Report for Microsoft Fabric (repository tool)
#>
[CmdletBinding()]
param(
    [string]$OutputFolder,
    [switch]$KeepWork
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutputFolder) { $OutputFolder = Join-Path $root 'package\docs\images' }
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge not found: it takes the screenshots (headless mode).' }
$work = Join-Path ([IO.Path]::GetTempPath()) ('pdrf-doc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work, $OutputFolder -Force | Out-Null
$guideName = 'PurviewDlpReport-Fabric-Guide'

#region Guide assets ---------------------------------------------------------------------------------
function ConvertTo-ReadmeInline([string]$Text) {
    # Inline Markdown of a guide block (code, bold, italic) -> HTML.
    $h = [Net.WebUtility]::HtmlEncode($Text.Trim())
    $h = [regex]::Replace($h, '`([^`]+)`', '<code>$1</code>')
    $h = [regex]::Replace($h, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
    return [regex]::Replace($h, '(?<![\w*])\*([^*\s][^*]*)\*(?![\w*])', '<em>$1</em>')
}

function Get-ReadmeAssets {
    $builder = Join-Path $root 'tools\Build-Documentation.ps1'
    $guideHtml = Join-Path $root "package\docs\$guideName.html"
    $guideMd = Join-Path $root "package\docs\$guideName.md"
    if (-not (Test-Path $guideHtml)) { throw "package\docs\$guideName.html not found: run tools\Build-Documentation.ps1 first (it holds the CSS of the graphics)." }
    # Icons: the $Icons table of the documentation builder, read without running the builder.
    $ast = [Management.Automation.Language.Parser]::ParseFile($builder, [ref]$null, [ref]$null)
    $assign = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$Icons' }, $true)
    if (-not $assign) { throw "Icon table not found in $builder." }
    $md = [IO.File]::ReadAllText($guideMd) -replace "`r`n", "`n"
    $blocks = foreach ($m in [regex]::Matches($md, '(?s)```(flow|cards)\n(.*?)\n```')) {
        $lines = @($m.Groups[2].Value -split "`n" | Where-Object { $_.Trim() })
        [pscustomobject]@{ Kind = $m.Groups[1].Value; Lines = $lines; First = $lines[0].Split('|')[1].Trim() }
    }
    [pscustomobject]@{
        Icons   = & ([scriptblock]::Create($assign.Right.Extent.Text))
        Css     = [regex]::Match([IO.File]::ReadAllText($guideHtml), '(?s)<style>(.*?)</style>').Groups[1].Value
        Version = [regex]::Match($md, '(?m)^version:\s*(\S+)').Groups[1].Value
        Blocks  = @($blocks)
    }
}

function Get-GuideBlock([string]$Kind, [string]$FirstTitle) {
    # A cards or flow block of the guide, found by the title of its first item.
    $block = $assets.Blocks | Where-Object { $_.Kind -eq $Kind -and $_.First -eq $FirstTitle } | Select-Object -First 1
    if (-not $block) { throw "Guide block not found: $Kind starting with '$FirstTitle' (package\docs\$guideName.md)." }
    return $block.Lines
}

function Get-ReadmeIcon([string]$Name, [string]$Class = 'icon') {
    $path = $assets.Icons[$Name]; if (-not $path) { $path = $assets.Icons['info'] }
    "<svg class=""$Class"" viewBox=""0 0 24 24"" fill=""none"" stroke=""currentColor"" stroke-width=""1.7"" stroke-linecap=""round"" stroke-linejoin=""round"">$path</svg>"
}

function ConvertTo-ReadmeFlow([string[]]$Lines, [switch]$Vertical) {
    # Vertical: the nodes are stacked, icon on the left, with a downward arrow and its label.
    $items = foreach ($l in $Lines) {
        $icon, $title, $sub = $l.Split('|', 3).ForEach({ $_.Trim() })
        $title = [Net.WebUtility]::HtmlEncode($title); $sub = [Net.WebUtility]::HtmlEncode($sub)
        if ($Vertical) {
            if ($icon -eq 'arrow') {
                $note = if ($sub) { "<span class=""flow-sub"">$sub</span>" } else { '' }
                "<div class=""rb-varrow""><svg viewBox=""0 0 12 30""><path d=""M6 1v26M1 21l5 6 5-6"" fill=""none"" stroke=""currentColor"" stroke-width=""1.6""/></svg><span class=""flow-label"">$title</span>$note</div>"
            } else {
                "<div class=""rb-vnode""><div class=""flow-icon"">$(Get-ReadmeIcon $icon)</div><div><div class=""flow-title"">$title</div><div class=""flow-text"">$sub</div></div></div>"
            }
        } elseif ($icon -eq 'arrow') {
            "<div class=""flow-arrow""><span class=""flow-label"">$title</span><svg viewBox=""0 0 40 12""><path d=""M0 6h36M31 1l6 5-6 5"" fill=""none"" stroke=""currentColor"" stroke-width=""1.6""/></svg><span class=""flow-sub"">$sub</span></div>"
        } else {
            "<div class=""flow-node""><div class=""flow-icon"">$(Get-ReadmeIcon $icon)</div><div class=""flow-title"">$title</div><div class=""flow-text"">$sub</div></div>"
        }
    }
    $class = if ($Vertical) { 'flow rb-vflow' } else { 'flow rb-flow' }
    "<div class=""$class"">$($items -join '')</div>"
}

function ConvertTo-ReadmeCards([string[]]$Lines, [string]$Class = '') {
    $items = foreach ($l in $Lines) {
        $icon, $title, $text = $l.Split('|', 3).ForEach({ $_.Trim() })
        "<div class=""card-item""><div class=""card-icon"">$(Get-ReadmeIcon $icon)</div><div><div class=""card-title"">$(ConvertTo-ReadmeInline $title)</div><div class=""card-text"">$(ConvertTo-ReadmeInline $text)</div></div></div>"
    }
    "<div class=""cards $Class"">$($items -join '')</div>"
}
#endregion

#region Graphics ---------------------------------------------------------------------------------------
$Script:ReadmeCss = @'
html, body { background: #ffffff; }
html[data-theme="dark"], html[data-theme="dark"] body { background: #0d1117; }
body { display: block; margin: 0; padding: 0; }
.canvas { padding: 6px; }
.rb-caption { font-size: 11.5px; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; color: var(--cp-accent); margin: 0 0 8px 4px; }
.rb-caption span { color: var(--cp-text-muted); font-weight: 600; letter-spacing: 0.04em; text-transform: none; font-size: 12.5px; }
/* Banner */
.rb-hero { margin: 0; padding: 32px 36px 30px; }
.rb-hero-grid { position: relative; display: grid; grid-template-columns: minmax(0, 1fr) 260px; gap: 34px; align-items: center; }
.rb-hero h1 { font-size: 33px; }
.rb-hero .lead { margin: 18px 0 0; font-size: 17px; max-width: none; }
.rb-hero .badges { margin: 20px 0 0; }
.rb-stats { position: relative; display: grid; gap: 10px; }
.rb-stat { display: flex; align-items: center; gap: 14px; padding: 12px 16px; border-radius: 14px; background: var(--cp-panel-strong); border: 1px solid var(--cp-border); box-shadow: 0 1px 2px rgba(0, 0, 0, 0.08); }
.rb-stat b { font-size: 26px; line-height: 1; color: var(--cp-accent); font-weight: 750; min-width: 72px; text-align: center; white-space: nowrap; }
.rb-stat span { font-size: 13px; color: var(--cp-text-muted); line-height: 1.35; }
.rb-stat strong { display: block; color: var(--cp-text); font-size: 14px; }
/* Cards and flows */
.cards { margin: 0; }
.rb-cards2 { grid-template-columns: 1fr 1fr; }
.rb-cards3 { grid-template-columns: 1fr 1fr 1fr; }
.rb-flow { margin: 0; flex-wrap: nowrap; padding: 18px; gap: 4px; }
.rb-flow .flow-node { flex: 1 1 0; min-width: 0; padding: 14px 10px; }
.rb-flow .flow-title { font-size: 13.5px; overflow-wrap: anywhere; }
.rb-flow .flow-arrow { min-width: 0; width: 104px; flex: 0 0 104px; }
.rb-flow .flow-sub { max-width: 104px; }
.rb-space { height: 18px; }
/* How it works: vertical pipeline and who sees what */
.rb-hiw { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 16px; align-items: stretch; }
.rb-col { display: flex; flex-direction: column; }
.rb-vflow { flex: 1; flex-direction: column; flex-wrap: nowrap; align-items: stretch; justify-content: center; gap: 0; margin: 0; padding: 16px 18px; }
.rb-vnode { display: flex; align-items: center; gap: 14px; padding: 10px 16px; border-radius: 12px; background: var(--cp-surface); border: 1px solid var(--cp-border); }
.rb-vnode .flow-icon { margin: 0; flex-shrink: 0; }
.rb-vnode .flow-text { margin-top: 1px; }
.rb-varrow { display: flex; align-items: center; gap: 10px; min-height: 34px; padding-left: 31px; }
.rb-varrow svg { width: 12px; height: 26px; color: var(--cp-accent); flex-shrink: 0; }
.rb-varrow .flow-sub { max-width: none; font-size: 12px; }
.rb-modes { flex: 1; display: flex; flex-direction: column; gap: 10px; }
.rb-modes .card-item { flex: 1; align-items: center; }
.rb-modes .card-title { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
.rb-chip { font-size: 11px; font-weight: 600; padding: 0 8px; border-radius: 999px; border: 1px solid var(--cp-border); color: var(--cp-text-muted); }
.rb-chip.hot { color: var(--cp-accent-fg); background: var(--cp-accent); border-color: var(--cp-accent); }
.rb-note { margin: 10px 4px 0; font-size: 12.5px; color: var(--cp-text-muted); }
'@

function Save-Screenshot([string]$Html, [string]$Png, [int]$Width, [int]$Height, [int]$Scale = 1) {
    $url = 'file:///' + ($Html -replace '\\', '/')
    $profile = Join-Path $work 'edge-profile'
    if (Test-Path $Png) { Remove-Item $Png -Force }
    # Start-Process, not &: an Edge helper process can keep the output pipe open after the capture.
    $edgeArgs = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', "--user-data-dir=`"$profile`"", "--window-size=$Width,$Height", "--force-device-scale-factor=$Scale", "--screenshot=`"$Png`"", "`"$url`"")
    $proc = Start-Process -FilePath $edge -ArgumentList $edgeArgs -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(45)
    while (-not (Test-Path $Png) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    if (-not $proc.WaitForExit(10000)) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    if (-not (Test-Path $Png)) { throw "Screenshot not written: $Png" }
}

function Get-PageHeight([string]$Html, [int]$Width) {
    # Height of the .canvas element: the page writes it in body[data-h], read with --dump-dom.
    $url = 'file:///' + ($Html -replace '\\', '/')
    $dom = Join-Path $work ('dom-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.html')
    $edgeArgs = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', "--user-data-dir=`"$(Join-Path $work 'edge-profile')`"", "--window-size=$Width,2000", '--dump-dom', "`"$url`"")
    $proc = Start-Process -FilePath $edge -ArgumentList $edgeArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $dom
    if (-not $proc.WaitForExit(45000)) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    # Edge helper processes inherit the output handle: read in shared mode, retry until written.
    $m = $null
    for ($i = 0; $i -lt 20 -and -not ($m -and $m.Success); $i++) {
        $stream = [IO.File]::Open($dom, 'Open', 'Read', 'ReadWrite')
        try { $text = [IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
        $m = [regex]::Match($text, 'data-h="(\d+)"')
        if (-not $m.Success) { Start-Sleep -Milliseconds 250 }
    }
    if (-not $m.Success) { throw "Height not measured: $Html" }
    return [int]$m.Groups[1].Value
}

function New-ReadmeGraphic {
    # One graphic, light and dark: HTML page -> height measured by Edge -> 2x screenshot.
    param([string]$Name, [string]$Body, [int]$Width = 1080)
    $pages = @{}
    foreach ($theme in 'light', 'dark') {
        $html = "<!doctype html><html lang=""en"" data-theme=""$theme""><head><meta charset=""utf-8""><style>$($assets.Css)`n$($Script:ReadmeCss)</style></head>" +
            "<body><div class=""canvas"" style=""width:$($Width)px"">$Body</div><script>document.body.setAttribute('data-h', Math.ceil(document.querySelector('.canvas').getBoundingClientRect().height));</script></body></html>"
        $pages[$theme] = Join-Path $work "readme-$Name-$theme.html"
        [IO.File]::WriteAllText($pages[$theme], $html, [Text.UTF8Encoding]::new($false))
    }
    $height = Get-PageHeight $pages['light'] $Width
    foreach ($theme in 'light', 'dark') { Save-Screenshot $pages[$theme] (Join-Path $OutputFolder "readme-$Name-$theme.png") $Width $height 2 }
    Write-Host "  readme-$Name (light, dark)"
}

$Script:assets = Get-ReadmeAssets
$mid = '&middot;'
Write-Host 'Rendering the README graphics (light and dark, 2x)...'

# Banner: the hero of the guide, with three key figures.
$badges = @(
    "<span class=""badge badge-accent"">Version $($assets.Version)</span>"
    "<span class=""badge"">$(Get-ReadmeIcon 'terminal' 'icon-sm')PowerShell 7.4+</span>"
    "<span class=""badge"">$(Get-ReadmeIcon 'chat' 'icon-sm')Agent in Microsoft Teams</span>"
    "<span class=""badge"">$(Get-ReadmeIcon 'tag' 'icon-sm')MIT license</span>"
) -join ''
$banner = "<header class=""hero rb-hero""><div class=""rb-hero-grid""><div>" +
    "<div class=""hero-top""><div class=""hero-logo"">$(Get-ReadmeIcon 'shield')</div><div><div class=""eyebrow"">Purview DLP Report $mid Microsoft Fabric companion</div><h1>Purview DLP Report for Microsoft Fabric</h1></div></div>" +
    "<p class=""lead"">Publishes the messages sent to more than 25 recipients that the <strong>Purview DLP</strong> rule detected, with the profile of each sender, and gives every <strong>business line, manager and employee</strong> a Power BI report and an <strong>agent in Teams</strong> that show <strong>only the messages that concern them</strong>.</p>" +
    "<div class=""badges"">$badges</div></div>" +
    "<div class=""rb-stats"">" +
    "<div class=""rb-stat""><b>1</b><span><strong>report for everyone</strong>each reader sees their scope</span></div>" +
    "<div class=""rb-stat""><b>4</b><span><strong>kinds of scope</strong>compliance, business line, hierarchy, own</span></div>" +
    "<div class=""rb-stat""><b>FR&thinsp;&middot;&thinsp;EN</b><span><strong>questions in Teams</strong>same row-level security</span></div>" +
    "</div></div></header>"
New-ReadmeGraphic -Name 'banner' -Body $banner

# Why: what the companion brings (chapter 1).
New-ReadmeGraphic -Name 'why' -Body (ConvertTo-ReadmeCards (Get-GuideBlock 'cards' 'One report, many views') 'rb-cards2')

# How it works: the publication pipeline of chapter 2 (vertical) and who sees what.
$scopes = @(
    [pscustomobject]@{ Icon = 'shield'; Name = 'Compliance team'; Chip = '<span class="rb-chip hot">every message</span>'; Text = 'Including the senders not found in the directory. Group in the role <code>Compliance</code>.' }
    [pscustomobject]@{ Icon = 'layers'; Name = 'Business-line correspondent'; Chip = '<span class="rb-chip">their business lines</span>'; Text = 'One security group per business line, named after the value of the directory attribute.' }
    [pscustomobject]@{ Icon = 'people'; Name = 'Manager, director'; Chip = '<span class="rb-chip">their people</span>'; Text = 'Everyone who reports to them, directly or not: the <code>manager</code> attribute of Entra ID.' }
    [pscustomobject]@{ Icon = 'user'; Name = 'Employee'; Chip = '<span class="rb-chip">own messages</span>'; Text = 'Their user principal name. Scopes add up; someone in none of them sees nothing.' }
)
$scopeHtml = ($scopes | ForEach-Object { "<div class=""card-item""><div class=""card-icon"">$(Get-ReadmeIcon $_.Icon)</div><div><div class=""card-title"">$($_.Name) $($_.Chip)</div><div class=""card-text"">$($_.Text)</div></div></div>" }) -join ''
$how = "<div class=""rb-hiw""><div class=""rb-col""><div class=""rb-caption"">Daily publication <span>$mid from the local database to the report</span></div>$(ConvertTo-ReadmeFlow (Get-GuideBlock 'flow' 'Purview DLP Report') -Vertical)</div>" +
    "<div class=""rb-col""><div class=""rb-caption"">Who sees what <span>$mid one report, row-level security</span></div><div class=""rb-modes"">$scopeHtml</div></div></div>"
New-ReadmeGraphic -Name 'how' -Body $how

# Agent: the Teams chain of chapter 2 and the answer format of chapter 11.
$agent = "<div class=""rb-caption"">Questions in Microsoft Teams <span>$mid with the identity of the reader, end to end</span></div>" + (ConvertTo-ReadmeFlow (Get-GuideBlock 'flow' 'Microsoft Teams')) +
    "<div class=""rb-space""></div><div class=""rb-caption"">Every answer, the same card <span>$mid in the language of the question</span></div>" + (ConvertTo-ReadmeCards (Get-GuideBlock 'cards' 'Title and scope') 'rb-cards3')
New-ReadmeGraphic -Name 'agent' -Body $agent
#endregion

Get-ChildItem $OutputFolder -Filter 'readme-*.png' | Select-Object Name, @{ n = 'KB'; e = { [math]::Round($_.Length / 1KB) } } | Format-Table -AutoSize | Out-String | Write-Host
# Edge helper processes of the temporary profile, if any are left.
Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like "*$work*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
if ($KeepWork) { Write-Host "Work folder: $work" } else { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
