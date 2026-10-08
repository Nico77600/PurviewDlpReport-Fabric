# Purview DLP Report for Microsoft Fabric - Power BI report definition (PBIR format), dot-sourced by
# Publish-DlpReportToFabric.ps1.
# Design: the pages have an image background drawn by tools\new_report_backgrounds.py (same identity as the HTML report
# and the guide: warm background, white cards, crimson accent, gradient tiles). The visuals are transparent and placed
# in the slots listed in src\report\layout.json; the custom theme src\report\PurviewDlpReport.theme.json gives the
# colours and fonts. Every visual reads the semantic model: the row-level security applies to every page.

$script:ReportAssets = Join-Path $PSScriptRoot 'report'
$script:Accent = '#B11F4B'

function New-PbirLiteral($Value) { return @{ expr = @{ Literal = @{ Value = $Value } } } }
function New-PbirColor([string]$Hex) { return @{ solid = @{ color = (New-PbirLiteral "'$Hex'") } } }
function New-PbirField([string]$Entity, [string]$Property, [switch]$Measure) {
    $kind = if ($Measure) { 'Measure' } else { 'Column' }
    return @{ $kind = @{ Expression = @{ SourceRef = @{ Entity = $Entity } }; Property = $Property } }
}
function New-PbirProjection([string]$Entity, [string]$Property, [switch]$Measure, [string]$DisplayName) {
    $p = [ordered]@{ field = (New-PbirField $Entity $Property -Measure:$Measure); queryRef = "$Entity.$Property"; nativeQueryRef = $Property }
    if ($DisplayName) { $p.displayName = $DisplayName }
    return $p
}
function New-PbirMeasure([string]$Property) { New-PbirProjection 'Messages' $Property -Measure }

function New-PbirVisual {
    param([string]$Name, [double[]]$Slot, [string]$Type, [hashtable]$QueryState, $Sort, [hashtable]$Objects, [object[]]$Filters, [int]$Z = 1000, [switch]$KeepHeader)
    $visual = [ordered]@{ visualType = $Type }
    if ($QueryState) {
        $visual.query = [ordered]@{ queryState = $QueryState }
        if ($Sort) { $visual.query.sortDefinition = [ordered]@{ sort = @($Sort); isDefaultSort = $true } }
    }
    if ($Objects) { $visual.objects = $Objects }
    $container = [ordered]@{
        title      = @(@{ properties = @{ show = (New-PbirLiteral 'false') } })
        background = @(@{ properties = @{ show = (New-PbirLiteral 'false') } })
        border     = @(@{ properties = @{ show = (New-PbirLiteral 'false') } })
        dropShadow = @(@{ properties = @{ show = (New-PbirLiteral 'false') } })
    }
    if (-not $KeepHeader) { $container.visualHeader = @(@{ properties = @{ show = (New-PbirLiteral 'false') } }) }
    $visual.visualContainerObjects = $container
    $visual.drillFilterOtherVisuals = $true
    $v = [ordered]@{
        '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definition/visualContainer/2.0.0/schema.json'
        name      = $Name
        position  = [ordered]@{ x = $Slot[0]; y = $Slot[1]; z = $Z; height = $Slot[3]; width = $Slot[2]; tabOrder = $Z }
        visual    = $visual
    }
    if ($Filters) { $v.filterConfig = @{ filters = @($Filters) } }
    return $v
}

function New-PbirSlicer([string]$Name, [double[]]$Slot, [string]$Entity, [string]$Property, [string]$Mode = 'Dropdown') {
    $objects = @{
        data   = @(@{ properties = @{ mode = (New-PbirLiteral "'$Mode'") } })
        header = @(@{ properties = @{ show = (New-PbirLiteral 'false') } })
        items  = @(@{ properties = [ordered]@{ fontColor = (New-PbirColor '#242424'); background = (New-PbirColor '#FFFFFF'); outlineColor = (New-PbirColor '#DEDEDE'); outline = (New-PbirLiteral "'Frame'"); textSize = (New-PbirLiteral '10D') } })
    }
    return New-PbirVisual -Name $Name -Slot $Slot -Type 'slicer' -Objects $objects -QueryState @{ Values = @{ projections = @((New-PbirProjection $Entity $Property)) } }
}

function New-PbirCard([string]$Name, [double[]]$Slot, [string]$Entity, [string]$Measure, [string]$Color = '#242424', [string]$Size = '24D', [string]$Font = 'Segoe UI Semibold') {
    $objects = @{
        labels         = @(@{ properties = [ordered]@{ color = (New-PbirColor $Color); fontSize = (New-PbirLiteral $Size); fontFamily = (New-PbirLiteral "'$Font'"); labelDisplayUnits = (New-PbirLiteral '1D') } })
        categoryLabels = @(@{ properties = @{ show = (New-PbirLiteral 'false') } })
    }
    return New-PbirVisual -Name $Name -Slot $Slot -Type 'card' -Objects $objects -QueryState @{ Values = @{ projections = @((New-PbirProjection $Entity $Measure -Measure)) } }
}

function New-PbirGradient([string]$Entity, [string]$Measure, [string]$Low = '#F2C4D1', [string]$High = '#9A1A41') {
    # Returned as a single-item list with the unary comma, so that PowerShell keeps it an array.
    # Bars coloured from light pink to crimson by value (conditional formatting).
    return @(@{
            properties = @{ fill = @{ solid = @{ color = @{ expr = @{ FillRule = @{
                                Input    = (New-PbirField $Entity $Measure -Measure)
                                FillRule = @{ linearGradient2 = [ordered]@{
                                        min                   = @{ color = @{ Literal = @{ Value = "'$Low'" } } }
                                        max                   = @{ color = @{ Literal = @{ Value = "'$High'" } } }
                                        nullColoringStrategy = @{ strategy = @{ Literal = @{ Value = "'asZero'" } } } } } } } } } } }
            selector   = @{ data = @(@{ dataViewWildcard = @{ matchingOption = 1 } }) }
        })
}

function Get-PbirChartObjects([switch]$CategoricalAxis, [switch]$HideCategoryAxis, $DataPoint, [string]$Units = '0D') {
    $category = [ordered]@{ showAxisTitle = (New-PbirLiteral 'false'); gridlineShow = (New-PbirLiteral 'false'); labelColor = (New-PbirColor '#5C5C5C'); fontSize = (New-PbirLiteral '8D') }
    if ($CategoricalAxis) { $category.axisType = (New-PbirLiteral "'Categorical'") }
    if ($HideCategoryAxis) { $category.show = (New-PbirLiteral 'false') }
    $o = [ordered]@{
        categoryAxis = @(@{ properties = $category })
        valueAxis    = @(@{ properties = [ordered]@{ show = (New-PbirLiteral 'false'); gridlineShow = (New-PbirLiteral 'false') } })
        labels       = @(@{ properties = [ordered]@{ show = (New-PbirLiteral 'true'); color = (New-PbirColor '#5C5C5C'); fontSize = (New-PbirLiteral '9D'); labelDisplayUnits = (New-PbirLiteral $Units) } })
        legend       = @(@{ properties = @{ show = (New-PbirLiteral 'false') } })
    }
    $o.dataPoint = [object[]]$(if ($DataPoint) { $DataPoint } else { @{ properties = @{ fill = (New-PbirColor $script:Accent) } } })
    return $o
}

function New-PbirDataBars([string]$QueryRef, [string]$Color = '#F2C4D1') {
    return @{
        properties = @{ dataBars = [ordered]@{
                positiveColor = (New-PbirColor $Color); negativeColor = (New-PbirColor '#DC2626'); axisColor = (New-PbirColor '#DEDEDE')
                reverseDirection = (New-PbirLiteral 'false'); hideText = (New-PbirLiteral 'false') } }
        selector   = @{ metadata = $QueryRef }
    }
}

function New-PbirColumnWidth([hashtable]$Widths) {
    foreach ($k in $Widths.Keys) { @{ properties = @{ value = (New-PbirLiteral "$($Widths[$k])D") }; selector = @{ metadata = $k } } }
}
function New-PbirTopN([string]$Name, [string]$Entity, [string]$Property, [string]$MeasureEntity, [string]$Measure, [int]$Top) {
    $sub = @{ Version = 2; From = @(@{ Name = 's'; Entity = $Entity; Type = 0 }, @{ Name = 'm'; Entity = $MeasureEntity; Type = 0 })
        Select = @(@{ Column = @{ Expression = @{ SourceRef = @{ Source = 's' } }; Property = $Property }; Name = 'field' })
        OrderBy = @(@{ Direction = 2; Expression = @{ Measure = @{ Expression = @{ SourceRef = @{ Source = 'm' } }; Property = $Measure } } })
        Top = $Top }
    return [ordered]@{
        name = $Name; field = (New-PbirField $Entity $Property); type = 'TopN'
        filter = @{ Version = 2
            From = @(@{ Name = 'subquery'; Expression = @{ Subquery = @{ Query = $sub } }; Type = 2 }, @{ Name = 's'; Entity = $Entity; Type = 0 })
            Where = @(@{ Condition = @{ In = @{ Expressions = @(@{ Column = @{ Expression = @{ SourceRef = @{ Source = 's' } }; Property = $Property } }); Table = @{ SourceRef = @{ Source = 'subquery' } } } } })
        }
        howCreated = 'User'
    }
}

function Get-PbirFilterSlicers([string]$Prefix, $Slots) {
    return @(
        New-PbirSlicer "${Prefix}sDate" $Slots.f_date 'Messages' 'Date' 'Between'
        New-PbirSlicer "${Prefix}sLine" $Slots.f_line 'Senders' 'Business line'
        New-PbirSlicer "${Prefix}sEntity" $Slots.f_entity 'Senders' 'Entity'
        New-PbirSlicer "${Prefix}sSite" $Slots.f_site 'Senders' 'Site'
        New-PbirSlicer "${Prefix}sMgr2" $Slots.f_mgr2 'Senders' 'Manager N+2'
        New-PbirSlicer "${Prefix}sMgr" $Slots.f_mgr 'Senders' 'Manager'
        New-PbirSlicer "${Prefix}sSender" $Slots.f_sender 'Senders' 'Name'
    )
}

function New-ReportDefinition([string]$SemanticModelId, [string]$Title) {
    $layout = Get-Content (Join-Path $script:ReportAssets 'layout.json') -Raw | ConvertFrom-Json -AsHashtable
    $bands = $layout.bands
    $pages = [ordered]@{}

    # ---- Overview -------------------------------------------------------------------------------------------------
    $l = $layout.overview
    $bandPoints = @(foreach ($b in $bands) { @{ properties = @{ fill = (New-PbirColor $b.color) }; selector = @{ metadata = "Messages.$($b.name)" } } })
    $strip = [ordered]@{
        categoryAxis = @(@{ properties = @{ show = (New-PbirLiteral 'false') } })
        valueAxis    = @(@{ properties = @{ show = (New-PbirLiteral 'false'); gridlineShow = (New-PbirLiteral 'false') } })
        legend       = @(@{ properties = @{ show = (New-PbirLiteral 'false') } })
        labels       = @(@{ properties = @{ show = (New-PbirLiteral 'false') } })
        dataPoint    = $bandPoints
    }
    $pages['overview'] = @{ Display = 'Overview'; Background = 'overview'; Visuals = @(
            New-PbirCard 'ovRange' $l.range 'Messages' 'Detection range' '#9A1A41' '11D' 'Segoe UI'
            Get-PbirFilterSlicers 'ov' $l
            New-PbirCard 'ovT1' $l.tile1 'Messages' 'Messages' '#FFFFFF' '26D'
            New-PbirCard 'ovT2' $l.tile2 'Messages' 'Distinct senders' '#242424' '26D'
            New-PbirCard 'ovT3' $l.tile3 'Messages' 'Average recipients' '#242424' '26D'
            New-PbirCard 'ovT4' $l.tile4 'Messages' 'Largest message' '#242424' '26D'
            for ($i = 0; $i -lt $bands.Count; $i++) { New-PbirCard "ovBand$($i + 1)" $l["band$($i + 1)"] 'Messages' ($bands[$i].name -replace ' recipients', ' display') '#242424' '10D' }
            New-PbirVisual -Name 'ovStrip' -Slot $l.strip -Type 'hundredPercentStackedBarChart' -Objects $strip `
                -QueryState @{ Y = @{ projections = @($bands | ForEach-Object { New-PbirMeasure $_.name }) } }
            New-PbirVisual -Name 'ovLine' -Slot $l.byline -Type 'clusteredBarChart' -KeepHeader -Objects (Get-PbirChartObjects -DataPoint (New-PbirGradient 'Messages' 'Messages')) `
                -QueryState @{ Category = @{ projections = @((New-PbirProjection 'Senders' 'Business line')) }; Y = @{ projections = @((New-PbirMeasure 'Messages')) } } `
                -Sort @{ field = (New-PbirField 'Messages' 'Messages' -Measure); direction = 'Descending' }
            New-PbirVisual -Name 'ovDay' -Slot $l.perday -Type 'clusteredColumnChart' -KeepHeader -Objects (Get-PbirChartObjects -CategoricalAxis -Units '1000D') `
                -QueryState @{ Category = @{ projections = @((New-PbirProjection 'Messages' 'Date')) }; Y = @{ projections = @((New-PbirMeasure 'Messages')) } } `
                -Sort @{ field = (New-PbirField 'Messages' 'Date'); direction = 'Ascending' }
            New-PbirVisual -Name 'ovTop' -Slot $l.topsenders -Type 'clusteredBarChart' -KeepHeader -Objects (Get-PbirChartObjects -DataPoint (New-PbirGradient 'Messages' 'Messages')) `
                -QueryState @{ Category = @{ projections = @((New-PbirProjection 'Senders' 'Name' -DisplayName 'Sender')) }; Y = @{ projections = @((New-PbirMeasure 'Messages')) } } `
                -Sort @{ field = (New-PbirField 'Messages' 'Messages' -Measure); direction = 'Descending' } -Filters @((New-PbirTopN 'topSenders' 'Senders' 'Name' 'Messages' 'Messages' 10))
            New-PbirVisual -Name 'ovMgr' -Slot $l.topmanagers -Type 'clusteredBarChart' -KeepHeader -Objects (Get-PbirChartObjects -DataPoint (New-PbirGradient 'Messages' 'Messages')) `
                -QueryState @{ Category = @{ projections = @((New-PbirProjection 'Senders' 'Manager')) }; Y = @{ projections = @((New-PbirMeasure 'Messages')) } } `
                -Sort @{ field = (New-PbirField 'Messages' 'Messages' -Measure); direction = 'Descending' } -Filters @((New-PbirTopN 'topManagers' 'Senders' 'Manager' 'Messages' 'Messages' 10))
        )
    }

    # ---- Messages -------------------------------------------------------------------------------------------------
    $l = $layout.messages
    $pages['messages'] = @{ Display = 'Messages'; Background = 'messages'; Visuals = @(
            New-PbirCard 'msRange' $l.range 'Messages' 'Detection range' '#9A1A41' '11D' 'Segoe UI'
            Get-PbirFilterSlicers 'ms' $l
            New-PbirVisual -Name 'msTable' -Slot $l.table -Type 'tableEx' -KeepHeader -Objects @{ columnFormatting = @((New-PbirDataBars 'Messages.Recipient count')) } `
                -QueryState @{ Values = @{ projections = @(
                            (New-PbirProjection 'Messages' 'Detected at'), (New-PbirProjection 'Senders' 'Name' -DisplayName 'Sender'), (New-PbirProjection 'Senders' 'Business line'),
                            (New-PbirProjection 'Senders' 'Manager'), (New-PbirProjection 'Messages' 'Subject'), (New-PbirProjection 'Messages' 'Recipient count'),
                            (New-PbirProjection 'Messages' 'Sender' -DisplayName 'Sender address'), (New-PbirProjection 'Messages' 'Message ID')) } } `
                -Sort @{ field = (New-PbirField 'Messages' 'Detected at'); direction = 'Descending' }
        )
    }

    # ---- Hierarchy ------------------------------------------------------------------------------------------------
    $l = $layout.hierarchy
    $treemap = @{
        labels         = @(@{ properties = [ordered]@{ show = (New-PbirLiteral 'true'); color = (New-PbirColor '#FFFFFF'); fontSize = (New-PbirLiteral '9D') } })
        categoryLabels = @(@{ properties = [ordered]@{ show = (New-PbirLiteral 'true'); color = (New-PbirColor '#FFFFFF'); fontSize = (New-PbirLiteral '10D') } })
        legend         = @(@{ properties = @{ show = (New-PbirLiteral 'false') } })
    }
    $pages['hierarchy'] = @{ Display = 'Hierarchy'; Background = 'hierarchy'; Visuals = @(
            New-PbirCard 'hiRange' $l.range 'Messages' 'Detection range' '#9A1A41' '11D' 'Segoe UI'
            Get-PbirFilterSlicers 'hi' $l
            New-PbirVisual -Name 'hiMatrix' -Slot $l.matrix -Type 'pivotTable' -KeepHeader -Objects @{ columnFormatting = @((New-PbirDataBars 'Messages.Messages')); columnWidth = @(New-PbirColumnWidth @{ 'Senders.Business line' = 230; 'Messages.Messages' = 124; 'Messages.Recipients' = 106; 'Messages.Largest message' = 122 }) } `
                -QueryState @{
                    Rows   = @{ projections = @((New-PbirProjection 'Senders' 'Business line'), (New-PbirProjection 'Senders' 'Manager N+2'), (New-PbirProjection 'Senders' 'Manager'), (New-PbirProjection 'Senders' 'Name')) }
                    Values = @{ projections = @((New-PbirMeasure 'Messages'), (New-PbirMeasure 'Recipients'), (New-PbirMeasure 'Largest message')) }
                } -Sort @{ field = (New-PbirField 'Messages' 'Messages' -Measure); direction = 'Descending' }
            New-PbirVisual -Name 'hiTree' -Slot $l.treemap -Type 'treemap' -KeepHeader -Objects $treemap `
                -QueryState @{ Group = @{ projections = @((New-PbirProjection 'Senders' 'Business line')) }; Details = @{ projections = @((New-PbirProjection 'Senders' 'Manager')) }; Values = @{ projections = @((New-PbirMeasure 'Messages')) } }
        )
    }

    # ---- About ----------------------------------------------------------------------------------------------------
    $l = $layout.about
    $pages['about'] = @{ Display = 'About'; Background = 'about'; Visuals = @(
            New-PbirCard 'abRange' $l.range 'Messages' 'Detection range' '#9A1A41' '11D' 'Segoe UI'
            New-PbirCard 'abP1' $l.pub1 'Publication' 'Last published' '#242424' '18D'
            New-PbirCard 'abP2' $l.pub2 'Publication' 'Period covered' '#242424' '16D'
            New-PbirCard 'abP3' $l.pub3 'Messages' 'Messages' '#FFFFFF' '26D'
            New-PbirCard 'abP4' $l.pub4 'Publication' 'Coverage %' '#242424' '26D'
        )
    }

    # ---- Parts ----------------------------------------------------------------------------------------------------
    $parts = [ordered]@{}
    $binary = [ordered]@{}
    $json = { param($o) $o | ConvertTo-Json -Depth 60 }
    $themeName = 'PurviewDlpReportTheme.json'
    $images = [ordered]@{}
    foreach ($p in $pages.Keys) { $images[$p] = "PurviewDlpReportBg$((Get-Culture).TextInfo.ToTitleCase($pages[$p].Background)).png" }
    $parts['definition.pbir'] = & $json ([ordered]@{
            '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/2.0.0/schema.json'
            version = '4.0'; datasetReference = @{ byConnection = @{ connectionString = "semanticmodelid=$SemanticModelId" } }
        })
    $parts['definition/version.json'] = & $json ([ordered]@{ '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definition/versionMetadata/1.0.0/schema.json'; version = '2.0.0' })
    $parts['definition/report.json'] = & $json ([ordered]@{
            '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definition/report/3.1.0/schema.json'
            themeCollection = [ordered]@{
                baseTheme   = [ordered]@{ name = 'CY25SU12'; reportVersionAtImport = [ordered]@{ visual = '2.5.0'; report = '3.1.0'; page = '2.3.0' }; type = 'SharedResources' }
                customTheme = [ordered]@{ name = $themeName; reportVersionAtImport = [ordered]@{ visual = '2.5.0'; report = '3.1.0'; page = '2.3.0' }; type = 'RegisteredResources' }
            }
            resourcePackages = @(
                @{ name = 'SharedResources'; type = 'SharedResources'; items = @(@{ name = 'CY25SU12'; path = 'BaseThemes/CY25SU12.json'; type = 'BaseTheme' }) }
                @{ name = 'RegisteredResources'; type = 'RegisteredResources'; items = @(
                        @{ name = $themeName; path = $themeName; type = 'CustomTheme' }
                        $images.Values | ForEach-Object { @{ name = $_; path = $_; type = 'Image' } }
                    ) }
            )
            settings = [ordered]@{ useStylableVisualContainerHeader = $true; defaultFilterActionIsDataFilter = $true; defaultDrillFilterOtherVisuals = $true; allowChangeFilterTypes = $true; useEnhancedTooltips = $true }
        })
    $parts['definition/pages/pages.json'] = & $json ([ordered]@{
            '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definition/pagesMetadata/1.0.0/schema.json'
            pageOrder = @($pages.Keys); activePageName = 'overview'
        })
    foreach ($page in $pages.Keys) {
        $img = $images[$page]
        $parts["definition/pages/$page/page.json"] = & $json ([ordered]@{
                '$schema' = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definition/page/2.0.0/schema.json'
                name = $page; displayName = $pages[$page].Display; displayOption = 'FitToPage'; height = 720; width = 1280
                objects = [ordered]@{
                    background = @(@{ properties = [ordered]@{
                                image        = @{ image = [ordered]@{ name = (New-PbirLiteral "'$img'"); url = @{ expr = @{ ResourcePackageItem = [ordered]@{ PackageName = 'RegisteredResources'; PackageType = 1; ItemName = $img } } }; scaling = (New-PbirLiteral "'Fit'") } }
                                transparency = (New-PbirLiteral '0D') } })
                    outspace   = @(@{ properties = @{ color = (New-PbirColor '#F7F4EF') } })
                }
            })
        foreach ($visual in $pages[$page].Visuals) { $parts["definition/pages/$page/visuals/$($visual.name)/visual.json"] = & $json $visual }
        $binary["StaticResources/RegisteredResources/$img"] = [IO.File]::ReadAllBytes((Join-Path $script:ReportAssets "bg-$($pages[$page].Background).png"))
    }
    $parts["StaticResources/RegisteredResources/$themeName"] = Get-Content (Join-Path $script:ReportAssets 'PurviewDlpReport.theme.json') -Raw
    $list = @($parts.Keys | ForEach-Object { @{ path = $_; payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($parts[$_])); payloadType = 'InlineBase64' } })
    $list += @($binary.Keys | ForEach-Object { @{ path = $_; payload = [Convert]::ToBase64String($binary[$_]); payloadType = 'InlineBase64' } })
    return @{ parts = $list }
}
