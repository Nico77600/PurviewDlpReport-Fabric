#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Offline tests of Purview DLP Report for Microsoft Fabric: no connection to Microsoft 365 or Fabric.
    The functions of Publish-DlpReportToFabric.ps1 are loaded from its syntax tree, without running its main block.

        Invoke-Pester -Path .\tests
#>

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:PackageRoot = Join-Path $script:RepoRoot 'package'
    $script:MainScript = Join-Path $script:PackageRoot 'Publish-DlpReportToFabric.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($MainScript, [ref]$null, [ref]$null)
    $definitions = @($ast.EndBlock.Statements | Where-Object {
            $_ -is [Management.Automation.Language.FunctionDefinitionAst] -or
            ($_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -like '$script:*')
        })
    . ([scriptblock]::Create(($definitions | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine))
    $script:Root = $PackageRoot
    . (Join-Path $PackageRoot 'src\ReportDefinition.ps1')
    . (Join-Path $PackageRoot 'src\AiDefinition.ps1')
    if (-not ('PurviewDlpReportFabric.Normalizer' -as [type])) {
        Add-Type -Path (Join-Path $PackageRoot 'src\PurviewDlpReport.Fabric.cs') -ReferencedAssemblies @(
            'System.Runtime', 'System.IO', 'System.Collections', 'System.Collections.NonGeneric', 'System.Runtime.Extensions', 'System.Text.Encoding.Extensions',
            'System.Data.Common', 'System.ComponentModel.TypeConverter', 'System.ComponentModel.Primitives', 'System.Xml.ReaderWriter')
    }
    function Write-Info { }
    function Write-Warn { }

    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ('dlpfabric-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($Work)

    function New-TestFile([string]$Name, [string]$Text) {
        $path = Join-Path $script:Work $Name
        [IO.File]::WriteAllText($path, $Text, [Text.UTF8Encoding]::new($false))
        return $path
    }
    function ConvertFrom-Parts($Definition) {
        # Fabric item definition (base64 parts) -> path => text.
        $map = [ordered]@{}
        foreach ($p in $Definition.parts) { $map[$p.path] = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p.payload)) }
        return $map
    }
    function New-TestConfig([hashtable]$Values) {
        # The configuration template with test values (fictitious GUIDs).
        $text = [IO.File]::ReadAllText((Join-Path $script:PackageRoot 'config\PurviewDlpReport-Fabric.config.psd1'))
        $defaults = [ordered]@{
            TenantId = '11111111-1111-1111-1111-111111111111'; ApplicationId = '22222222-2222-2222-2222-222222222222'
            CertificateThumbprint = 'ABCDEF0123456789ABCDEF0123456789ABCDEF01'; WorkspaceId = '33333333-3333-3333-3333-333333333333'
            WarehouseId = '44444444-4444-4444-4444-444444444444'
        }
        foreach ($k in $Values.Keys) { $defaults[$k] = $Values[$k] }
        foreach ($k in $defaults.Keys) { $text = [regex]::Replace($text, "(?m)^(\s*$k\s*=\s*)'[^']*'", "`$1'$($defaults[$k])'") }
        return New-TestFile ("config-$([guid]::NewGuid().ToString('N').Substring(0, 6)).psd1") $text
    }
    $script:Warehouse = [pscustomobject]@{ id = '44444444-4444-4444-4444-444444444444'; displayName = 'PurviewDlpReport'; properties = [pscustomobject]@{ connectionString = 'example.datawarehouse.fabric.microsoft.com' } }
}

AfterAll {
    if ($script:Work -and (Test-Path $script:Work)) { Remove-Item $script:Work -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Repository' {
    It 'parses every PowerShell file without error' {
        $files = Get-ChildItem $RepoRoot -Recurse -Include '*.ps1', '*.psd1' -File | Where-Object FullName -notmatch '\\(\.git|work|logs)\\'
        $files.Count | Should -BeGreaterThan 4
        foreach ($f in $files) {
            $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty -Because $f.Name
        }
    }

    It 'has the same version in the script, the guide and the changelog' {
        $version = $script:Version
        $version | Should -Match '^\d+\.\d+\.\d+$'
        (Get-Content $MainScript -Raw) | Should -Match "Version : $([regex]::Escape($version))"
        (Get-Content (Join-Path $PackageRoot 'docs\PurviewDlpReport-Fabric-Guide.md') -Raw) | Should -Match "(?m)^version: $([regex]::Escape($version))\r?$"
        (Get-Content (Join-Path $RepoRoot 'CHANGELOG.md') -Raw) | Should -Match "(?m)^## $([regex]::Escape($version)) "
    }

    It 'ships a configuration template without tenant values' {
        $c = Import-PowerShellDataFile (Join-Path $PackageRoot 'config\PurviewDlpReport-Fabric.config.psd1')
        foreach ($section in 'Source', 'Authentication', 'Fabric', 'Directory', 'Access', 'Local') { $c.Keys | Should -Contain $section }
        $c.Authentication.TenantId | Should -BeNullOrEmpty
        $c.Authentication.ApplicationId | Should -BeNullOrEmpty
        $c.Fabric.WorkspaceId | Should -BeNullOrEmpty
        $c.Fabric.ConnectionId | Should -BeNullOrEmpty
    }

    It 'has every image linked by the guide and the README' {
        foreach ($doc in 'package\docs\PurviewDlpReport-Fabric-Guide.md', 'README.md') {
            $text = Get-Content (Join-Path $RepoRoot $doc) -Raw
            $links = [regex]::Matches($text, '(?:!\[[^\]]*\]\(|src="|srcset=")([^)"\s?]+\.png)') | ForEach-Object { $_.Groups[1].Value }
            @($links).Count | Should -BeGreaterThan 0 -Because $doc
            $base = Split-Path (Join-Path $RepoRoot $doc) -Parent
            foreach ($l in $links) { Join-Path $base $l | Should -Exist -Because "$doc links $l" }
        }
    }
}

Describe 'Read-Configuration' {
    It 'refuses the template as it is (no tenant)' {
        { Read-Configuration (Join-Path $PackageRoot 'config\PurviewDlpReport-Fabric.config.psd1') } | Should -Throw '*TenantId must be a GUID*'
    }
    It 'accepts a complete certificate configuration' {
        $c = Read-Configuration (New-TestConfig @{})
        $c.Fabric.WorkspaceId | Should -Be '33333333-3333-3333-3333-333333333333'
        $c.ConfigFile | Should -Exist
    }
    It 'refuses <Case>' -ForEach @(
        @{ Case = 'a thumbprint that is not 40 hexadecimal characters'; Values = @{ CertificateThumbprint = 'ABC' }; Message = '*CertificateThumbprint*' }
        @{ Case = 'a workspace that is not a GUID'; Values = @{ WorkspaceId = 'Purview DLP Report' }; Message = '*Fabric.WorkspaceId*' }
        @{ Case = 'a connection that is not a GUID'; Values = @{ ConnectionId = 'my connection' }; Message = '*ConnectionId*' }
        @{ Case = 'an unknown sign-in mode'; Values = @{ Mode = 'Password' }; Message = '*Authentication.Mode*' }
    ) {
        { Read-Configuration (New-TestConfig $Values) } | Should -Throw $Message
    }
    It 'needs no application in interactive mode' {
        $c = Read-Configuration (New-TestConfig @{ Mode = 'Interactive'; ApplicationId = ''; CertificateThumbprint = '' })
        $c.Authentication.Mode | Should -Be 'Interactive'
    }
}

Describe 'Export-Source (Purview DLP Report run with -NoCollect)' {
    BeforeAll {
        # A stand-in for Invoke-PurviewDlpReport.ps1: records its arguments and writes one CSV file.
        $tool = Join-Path $Work 'tool'
        [void][IO.Directory]::CreateDirectory((Join-Path $tool 'config'))
        [IO.File]::WriteAllText((Join-Path $tool 'config\PurviewDlpReport.config.psd1'), "@{`n    Report = @{`n        Formats      = @('Csv', 'Html')`n        CsvDelimiter = ';'`n    }`n}`n")
        [IO.File]::WriteAllText((Join-Path $tool 'Invoke-PurviewDlpReport.ps1'), @'
param($Mode, $Range, $Start, $End, [switch]$NoCollect, [switch]$IncludeRecipientDetails, $SplitBy, $MaxRowsPerFile, $OutputPath, $ConfigPath)
$null = New-Item -ItemType Directory -Path $OutputPath -Force
@{ Mode = $Mode; Range = $Range; Start = $Start; End = $End; NoCollect = [bool]$NoCollect; Recipients = [bool]$IncludeRecipientDetails; Config = (Get-Content $ConfigPath -Raw) } |
    ConvertTo-Json | Set-Content (Join-Path $OutputPath 'arguments.json')
Set-Content (Join-Path $OutputPath 'report.csv') "Detection time (UTC);Sender;Subject;Recipient count;Message ID`n2026-09-28 10:00:00;a@contoso.com;Hello;30;<1@contoso.com>"
'  Messages     1'
'  Coverage     50% (12 of 24 hours)'
exit 2
'@)
        $script:SourceConfig = @{ Source = @{ ToolPath = $tool; ConfigPath = ''; HistoryDays = 7 } }
    }
    It 'runs the tool in report mode on complete days, CSV only, without collection' {
        $out = Join-Path $Work 'export'; [void][IO.Directory]::CreateDirectory($out)
        $s = Export-Source $SourceConfig $out 7
        @($s.Files).Count | Should -Be 1
        $s.Delimiter | Should -Be ';'
        $s.Start | Should -Be (Get-Date).Date.AddDays(-7).ToString('yyyy-MM-dd')
        $s.End | Should -Be (Get-Date).Date.ToString('yyyy-MM-dd')
        $s.Complete | Should -BeFalse
        $s.Coverage | Should -Be '50% (12 of 24 hours)'
        $a = Get-Content (Join-Path $out 'source\arguments.json') -Raw | ConvertFrom-Json
        $a.Mode | Should -Be 'Report'; $a.Range | Should -Be 'Custom'
        $a.NoCollect | Should -BeTrue; $a.Recipients | Should -BeFalse
        $a.Config | Should -Match "Formats\s*=\s*@\('Csv'\)"
    }
    It 'stops when the tool is not found' {
        { Export-Source @{ Source = @{ ToolPath = (Join-Path $Work 'missing'); ConfigPath = '' } } $Work 7 } | Should -Throw '*Purview DLP Report not found*'
    }
}

Describe 'Normalizer (CSV of Purview DLP Report)' {
    BeforeAll {
        $script:Addresses = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
        $Addresses['alice@contoso.com'] = 'id-alice'; $Addresses['bob@contoso.com'] = 'id-bob'
        $first = New-TestFile 'part1.csv' ("Detection time (Europe/Paris);Sender;Recipients;Subject;Recipient count;Message ID`r`n" +
            "2026-09-28 10:00:00;Alice@Contoso.com;x@contoso.com;Quarterly results;30;<m1@contoso.com>`r`n" +
            "2026-09-28 11:00:00;bob@contoso.com;x@contoso.com;""Budget; draft`nline two"";42;<m2@contoso.com>`r`n" +
            "2026-09-28 12:00:00;'=cmd@fabrikam.com;x@contoso.com;'=SUM(A1);n/a;<m3@contoso.com>`r`n")
        $second = New-TestFile 'part2.csv' ("Detection time (Europe/Paris);Sender;Subject;Recipient count;Message ID`n" +
            "2026-09-29 09:00:00;alice@contoso.com;Quarterly results;30;<m1@contoso.com>`n" +
            "2026-09-29 09:30:00;carol@fabrikam.com;Hello, everyone;27;<m4@contoso.com>`n")
        $script:Output = Join-Path $Work 'dlp_messages.csv'
        $script:Result = [PurviewDlpReportFabric.Normalizer]::Run([string[]]@($first, $second), ';', $Addresses, $Output)
        $script:Rows = @(Import-Csv $Output)
    }
    It 'keeps one row per Message ID across files' {
        $Result.Rows | Should -Be 4
        $Result.Duplicates | Should -Be 1
        @($Rows.MessageId) | Should -Be @('<m1@contoso.com>', '<m2@contoso.com>', '<m3@contoso.com>', '<m4@contoso.com>')
        $Rows[0].DetectedAt | Should -Be '2026-09-28 10:00:00'
    }
    It 'reads the time zone, the period and the columns with or without recipients' {
        $Result.TimeZoneLabel | Should -Be 'Europe/Paris'
        $Result.FirstDetection | Should -Be '2026-09-28 10:00:00'
        $Result.LastDetection | Should -Be '2026-09-29 09:30:00'
        $Rows[3].DetectedDate | Should -Be '2026-09-29'
    }
    It 'matches senders to directory users, case-insensitive' {
        $Rows[0].SenderAddress | Should -Be 'alice@contoso.com'
        $Rows[0].SenderId | Should -Be 'id-alice'
        @($Result.SenderIds | Sort-Object) | Should -Be @('id-alice', 'id-bob')
        $Result.UnresolvedRows | Should -Be 2
        @($Result.UnresolvedSenders | Sort-Object) | Should -Be @('=cmd@fabrikam.com', 'carol@fabrikam.com')
    }
    It 'keeps quoted values, removes the spreadsheet protection and drops invalid counts' {
        $Rows[1].Subject | Should -Be 'Budget; draft line two'
        $Rows[3].Subject | Should -Be 'Hello, everyone'
        $Rows[2].Subject | Should -Be '=SUM(A1)'
        $Rows[2].RecipientCount | Should -BeNullOrEmpty
        $Rows[1].RecipientCount | Should -Be '42'
    }
    It 'refuses a file that is not a report of Purview DLP Report' {
        $bad = New-TestFile 'bad.csv' "Date;From;Id`n2026-09-28;a@contoso.com;1`n"
        { [PurviewDlpReportFabric.Normalizer]::Run([string[]]@($bad), ';', $Addresses, (Join-Path $Work 'bad-out.csv')) } | Should -Throw '*Unexpected CSV header*'
    }
}

Describe 'CsvBatchReader (bulk load)' {
    It 'types the values, keeps empty values as null and cuts long text' {
        $csv = New-TestFile 'batch.csv' "Name,Count,When,Day,Flag`nabcdef,5,2026-09-28 10:00:00,2026-09-28 00:00:00,true`n,,,,0`n"
        $reader = [PurviewDlpReportFabric.CsvBatchReader]::new($csv, [string[]]@('Name', 'Count', 'When', 'Day', 'Flag'), [string[]]@('string', 'int', 'datetime', 'date', 'bool'), [int[]]@(3, 0, 0, 0, 0))
        try {
            $reader.ReadBatch(1) | Should -BeTrue
            $row = $reader.Table.Rows[0]
            $row.Name | Should -Be 'abc'; $row.Count | Should -Be 5; $row.When | Should -Be ([datetime]'2026-09-28 10:00:00'); $row.Day | Should -Be ([datetime]'2026-09-28'); $row.Flag | Should -BeTrue
            $reader.ReadBatch(10) | Should -BeTrue
            $reader.Table.Rows[0].Count | Should -Be ([DBNull]::Value); $reader.Table.Rows[0].Flag | Should -BeFalse
            $reader.ReadBatch(10) | Should -BeFalse
            $reader.Rows | Should -Be 2
        }
        finally { $reader.Dispose() }
    }
}

Describe 'Write-DirectoryTable (senders and management chain)' {
    BeforeAll {
        function New-User($Id, $Upn, $Name, $Manager, $Department = 'Sales', $Division) {
            [pscustomobject]@{ id = $Id; userPrincipalName = $Upn; displayName = $Name; mail = $Upn; department = $Department; companyName = 'Contoso'; officeLocation = 'Paris'
                jobTitle = 'Sales rep'; manager = $(if ($Manager) { [pscustomobject]@{ id = $Manager } }); employeeOrgData = [pscustomobject]@{ division = $Division } }
        }
        $users = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($u in @(
                (New-User 'u1' 'Alice@contoso.com' 'Alice' 'm1' 'Sales' 'Retail')
                (New-User 'm1' 'mgr1@contoso.com' 'Manager One' 'm2')
                (New-User 'm2' 'mgr2@contoso.com' 'Manager Two' 'm3')
                (New-User 'm3' 'ceo@contoso.com' 'Chief' $null)
                (New-User 'x1' 'loop1@contoso.com' 'Loop One' 'x2' '')
                (New-User 'x2' 'loop2@contoso.com' 'Loop Two' 'x1' '')
            )) { $users[$u.id] = $u }
        $script:Directory = [pscustomobject]@{ Users = $users; Addresses = @{}; Attribute = 'department' }
    }
    It 'writes the manager, the manager N+2 and the whole chain' {
        $path = Join-Path $Work 'users.csv'
        $r = Write-DirectoryTable $Directory @('u1', 'unknown') 15 $path
        $r.Rows | Should -Be 1; $r.WithBusinessLine | Should -Be 1; $r.WithManager | Should -Be 1
        $row = Import-Csv $path
        $row.UserPrincipalName | Should -Be 'alice@contoso.com'
        $row.BusinessLine | Should -Be 'Sales'
        $row.ManagerName | Should -Be 'Manager One'; $row.ManagerUpn | Should -Be 'mgr1@contoso.com'; $row.Manager2Name | Should -Be 'Manager Two'
        $row.ManagerChain | Should -Be '|mgr1@contoso.com|mgr2@contoso.com|ceo@contoso.com|'
    }
    It 'keeps every column in place when there is no manager N+2 or no manager' {
        $path = Join-Path $Work 'users-top.csv'
        Write-DirectoryTable $Directory @('m2', 'm3') 15 $path | Out-Null
        $rows = @(Import-Csv $path)
        $rows[0].ManagerName | Should -Be 'Chief'; $rows[0].Manager2Name | Should -BeNullOrEmpty; $rows[0].ManagerChain | Should -Be '|ceo@contoso.com|'
        $rows[1].ManagerName | Should -BeNullOrEmpty; $rows[1].ManagerChain | Should -BeNullOrEmpty
        (Get-Content $path | Select-Object -Skip 1 | ForEach-Object { ([PurviewDlpReportFabric.Normalizer]::ReadRecord([IO.StringReader]::new($_), ',')).Count }) | Should -Be @(13, 13)
    }
    It 'stops at MaxManagerLevels and on a loop of managers' {
        $path = Join-Path $Work 'users2.csv'
        Write-DirectoryTable $Directory @('u1') 2 $path | Out-Null
        (Import-Csv $path).ManagerChain | Should -Be '|mgr1@contoso.com|mgr2@contoso.com|'
        $r = Write-DirectoryTable $Directory @('x1') 15 $path
        $r.WithBusinessLine | Should -Be 0
        (Import-Csv $path).ManagerChain | Should -Be '|loop2@contoso.com|'
    }
    It 'reads a nested business-line attribute' {
        $path = Join-Path $Work 'users3.csv'
        $d = [pscustomobject]@{ Users = $Directory.Users; Addresses = @{}; Attribute = 'employeeOrgData.division' }
        Write-DirectoryTable $d @('u1') 15 $path | Out-Null
        (Import-Csv $path).BusinessLine | Should -Be 'Retail'
    }
}

Describe 'Semantic model definition (TMDL)' {
    BeforeAll {
        $script:Model = ConvertFrom-Parts (New-ModelDefinition $Warehouse @('Sales', 'Finance'))
    }
    It 'has the model, the four tables, the relationship, the two roles and the Copilot folder' {
        foreach ($p in 'definition.pbism', 'definition/model.tmdl', 'definition/expressions.tmdl', 'definition/relationships.tmdl',
            'definition/tables/Messages.tmdl', 'definition/tables/Senders.tmdl', 'definition/tables/Report access.tmdl', 'definition/tables/Publication.tmdl',
            'definition/roles/Compliance.tmdl', 'definition/roles/Scoped.tmdl', 'Copilot/Instructions/instructions.md', 'Copilot/schema.json', 'Copilot/settings.json', 'Copilot/examplePrompts.json') {
            $Model.Keys | Should -Contain $p
        }
        ($Model['definition.pbism'] | ConvertFrom-Json).version | Should -Be '5.0'
    }
    It 'reads the warehouse in Direct Lake' {
        $Model['definition/expressions.tmdl'] | Should -Match 'Sql\.Database\("example\.datawarehouse\.fabric\.microsoft\.com", "44444444-4444-4444-4444-444444444444"\)'
        foreach ($t in 'Messages', 'Senders', 'Report access', 'Publication') { $Model["definition/tables/$t.tmdl"] | Should -Match 'mode: directLake' }
        $Model['definition/tables/Messages.tmdl'] | Should -Match 'entityName: dlp_messages'
    }
    It 'filters the scoped role on the reader: own messages, management chain, business lines' {
        $scoped = $Model['definition/roles/Scoped.tmdl']
        $scoped | Should -Match 'modelPermission: read'
        $scoped | Should -Match 'tablePermission Senders = VAR me = LOWER \( USERPRINCIPALNAME \(\) \)'
        $scoped | Should -Match ([regex]::Escape('CONTAINSSTRING ( Senders[Manager chain], "|" & me & "|" )'))
        $scoped | Should -Match ([regex]::Escape("'Report access'[Viewer] = me"))
        $Model['definition/roles/Compliance.tmdl'] | Should -Not -Match 'tablePermission'
        $Model['definition/tables/Report access.tmdl'] | Should -Match '(?m)^\tisHidden'
    }
    It 'gives stable lineage tags' {
        $again = ConvertFrom-Parts (New-ModelDefinition $Warehouse @('Sales', 'Finance'))
        $again['definition/tables/Senders.tmdl'] | Should -Be $Model['definition/tables/Senders.tmdl']
    }
    It 'prepares the model for AI: business lines in the instructions, hidden fields hidden' {
        $Model['Copilot/Instructions/instructions.md'] | Should -Match '`Finance`, `Sales`'
        $schema = $Model['Copilot/schema.json'] | ConvertFrom-Json
        $senders = $schema.tables | Where-Object name -eq 'Senders'
        ($senders.columns | Where-Object name -eq 'Manager chain').visibility | Should -Be 'Hidden'
        ($senders.columns | Where-Object name -eq 'Business line').synonyms | Should -Contain 'service'
        ($schema.tables | Where-Object name -eq 'Report access').visibility | Should -Be 'Hidden'
        @(($Model['Copilot/examplePrompts.json'] | ConvertFrom-Json).prompts).Count | Should -BeGreaterThan 2
    }
}

Describe 'Report definition (PBIR)' {
    BeforeAll {
        $definition = New-ReportDefinition '55555555-5555-5555-5555-555555555555' 'Purview DLP Report'
        $script:Report = [ordered]@{}
        foreach ($p in $definition.parts) { $Report[$p.path] = $p.payload }
        $script:ReportText = [ordered]@{}
        foreach ($k in @($Report.Keys | Where-Object { $_ -notlike '*.png' })) { $ReportText[$k] = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Report[$k])) }
    }
    It 'binds the report to the semantic model and has four pages with their backgrounds' {
        ($ReportText['definition.pbir'] | ConvertFrom-Json).datasetReference.byConnection.connectionString | Should -Be 'semanticmodelid=55555555-5555-5555-5555-555555555555'
        $pages = ($ReportText['definition/pages/pages.json'] | ConvertFrom-Json).pageOrder
        @($pages).Count | Should -Be 4
        @($Report.Keys | Where-Object { $_ -like 'StaticResources/RegisteredResources/*.png' }).Count | Should -Be 4
    }
    It 'writes valid JSON in every part' {
        foreach ($k in $ReportText.Keys) { { $ReportText[$k] | ConvertFrom-Json -Depth 64 } | Should -Not -Throw -Because $k }
    }
    It 'uses only tables, columns and measures of the semantic model' {
        $known = @{}
        foreach ($entity in $script:Tables.Keys) {
            $t = $script:Tables[$entity]
            foreach ($c in $script:ModelColumns[$entity].Values) { $known["$t|$($c.Name)"] = $true }
            foreach ($m in @($script:Measures[$entity] | Where-Object { $_ })) { $known["$t|$($m.Name)"] = $true }
        }
        $refs = foreach ($k in @($ReportText.Keys | Where-Object { $_ -like '*/visual.json' })) {
            $visual = $ReportText[$k] | ConvertFrom-Json -Depth 64 -AsHashtable
            $stack = [Collections.Generic.Stack[object]]::new(); $stack.Push($visual)
            while ($stack.Count) {
                $node = $stack.Pop()
                if ($node -is [Collections.IDictionary]) {
                    foreach ($kind in 'Column', 'Measure') {
                        $f = $node[$kind]
                        if ($f -is [Collections.IDictionary] -and $f['Property'] -and $f['Expression'] -and $f['Expression']['SourceRef'] -and $f['Expression']['SourceRef']['Entity']) { "$($f['Expression']['SourceRef']['Entity'])|$($f['Property'])" }
                    }
                    foreach ($v in $node.Values) { if ($v -is [Collections.IEnumerable] -and $v -isnot [string]) { $stack.Push($v) } }
                }
                elseif ($node -is [Collections.IEnumerable] -and $node -isnot [string]) { foreach ($v in $node) { if ($null -ne $v -and $v -isnot [string]) { $stack.Push($v) } } }
            }
        }
        @($refs).Count | Should -BeGreaterThan 10
        foreach ($r in ($refs | Sort-Object -Unique)) { $known.ContainsKey($r) | Should -BeTrue -Because "the report uses $r" }
    }
}

Describe 'Texts of the agents' {
    It 'tells the data agent to answer in the language of the question, with English labels' {
        $text = New-DataAgentInstructions 'https://app.powerbi.com/groups/g/reports/r'
        $text | Should -Match '# Language'
        $text | Should -Match 'In short'
        $text | Should -Match 'Key points'
        $text | Should -Match 'https://app.powerbi.com/groups/g/reports/r'
        $text | Should -Match 'a table never has more than 5 columns'
    }
    It 'asks Microsoft 365 Copilot to show the answer as returned' {
        New-DataAgentPublishDescription | Should -Match 'Show it exactly as returned'
    }
    It 'writes the Copilot Studio instructions: always the tool, relayed as returned, English on request' {
        $text = New-CopilotStudioInstructions 'https://app.powerbi.com/groups/g/reports/r'
        $text | Should -Match '"Purview DLP Report agent"'
        $text | Should -Match 'Answer in English\.'
        $text | Should -Match 'character for character'
        $text | Should -Match 'https://app.powerbi.com/groups/g/reports/r'
        (New-CopilotStudioInstructions $null) | Should -Match 'the link to the Power BI report'
        New-CopilotStudioToolDescription | Should -Match 'row-level security'
    }
    It 'ships the conversation language topic for Copilot Studio' {
        $yaml = Get-Content (Join-Path $PackageRoot 'src\copilot-studio\conversation-language.yaml') -Raw
        $yaml | Should -Match '(?m)^kind: AdaptiveDialog'
        $yaml | Should -Match 'variable: System\.User\.Language'
        $yaml | Should -Match 'value: English'
        $yaml | Should -Match 'value: French'
    }
    It 'creates a draft data agent on the semantic model, without hidden fields' {
        $config = @{ Fabric = @{ WorkspaceId = '33333333-3333-3333-3333-333333333333' } }
        $model = [pscustomobject]@{ id = '66666666-6666-6666-6666-666666666666'; displayName = 'Purview DLP Report' }
        $parts = ConvertFrom-Parts (New-DataAgentDefinition $config $model 'Test agent' 'https://example/report' -DraftOnly)
        @($parts.Keys) | Should -Be @('Files/Config/data_agent.json', 'Files/Config/draft/stage_config.json', 'Files/Config/draft/semantic_model-Purview DLP Report/datasource.json')
        $source = $parts['Files/Config/draft/semantic_model-Purview DLP Report/datasource.json'] | ConvertFrom-Json -Depth 20
        $source.artifactId | Should -Be $model.id
        $source.elements.display_name | Should -Not -Contain 'Report access'
        $source.elements.children.display_name | Should -Not -Contain 'Manager chain'
        ($parts['Files/Config/draft/stage_config.json'] | ConvertFrom-Json).aiInstructions | Should -Match 'https://example/report'
    }
}

Describe 'Publish-DataAgent' {
    BeforeAll {
        $script:AgentConfig = @{ Fabric = @{ WorkspaceId = '33333333-3333-3333-3333-333333333333'; DataAgentName = 'Purview DLP Report agent' } }
        $script:AgentModel = [pscustomobject]@{ id = '66666666-6666-6666-6666-666666666666'; displayName = 'Purview DLP Report' }
    }
    It 'creates the agent once, as a draft with its definition' {
        $script:calls = 0
        Mock Get-WorkspaceItem { $script:calls++; if ($script:calls -gt 1) { [pscustomobject]@{ id = 'a1'; displayName = 'Purview DLP Report agent' } } }
        Mock Invoke-Api { $script:posted = $Body; 'response' }
        Mock Wait-FabricOperation { }
        $agent = Publish-DataAgent $AgentConfig $AgentModel ([pscustomobject]@{ id = 'r1' })
        $agent.id | Should -Be 'a1'
        Should -Invoke Invoke-Api -Times 1 -Exactly
        $script:posted.type | Should -Be 'DataAgent'
        $parts = ConvertFrom-Parts $script:posted.definition
        $parts.Keys | Should -Contain 'Files/Config/draft/stage_config.json'
        $parts.Keys | Should -Not -Contain 'Files/Config/published/stage_config.json'
        ($parts['Files/Config/draft/stage_config.json'] | ConvertFrom-Json).aiInstructions | Should -Match '/reports/r1'
    }
    It 'never changes an agent that exists' {
        Mock Get-WorkspaceItem { [pscustomobject]@{ id = 'a1'; displayName = 'Purview DLP Report agent' } }
        Mock Invoke-Api { }
        (Publish-DataAgent $AgentConfig $AgentModel $null).id | Should -Be 'a1'
        Should -Invoke Invoke-Api -Times 0 -Exactly
    }
}

Describe 'Publish-DlpReportToFabric.ps1' {
    It 'stops with exit code 1 when the configuration is missing, before any connection' {
        $pwsh = (Get-Process -Id $PID).Path
        $output = & $pwsh -NoProfile -NonInteractive -File $MainScript -Mode Status -ConfigPath (Join-Path $Work 'missing.psd1') 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -Match 'Configuration file not found'
    }
}
