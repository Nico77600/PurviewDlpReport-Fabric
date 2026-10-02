#Requires -Version 7.4
<#
.SYNOPSIS
    Purview DLP Report for Microsoft Fabric - publishes the DLP report to a Fabric warehouse and a Power BI
    report in which every business line, manager or employee sees only the messages that concern them.

.DESCRIPTION
    Purview DLP Report produces one report with every message of the period: today it is sent to every
    business line, and each one has to look for its own rows. This optional companion publishes the same
    rows to Microsoft Fabric with the profile of each sender (Microsoft Entra ID: business line, entity,
    site, manager) and a row-level security that shows to each reader only:
      - the messages they sent;
      - the messages of the people who report to them, directly or not;
      - the business lines for which they are correspondents (security groups);
      - everything, for the compliance team.

    Purview DLP Report itself is not changed: this script runs it with -NoCollect (local database only)
    and uses its CSV output.

.PARAMETER Mode
    Publish (default) Exports the period from Purview DLP Report, reads the directory and the audience
                      groups, replaces the warehouse tables in one transaction and refreshes the semantic model.
    Deploy            Creates or updates the semantic model (Direct Lake, row-level security, prepared for AI),
                      the report and, if Fabric.DataAgentName is set, a Fabric data agent.
                      Run it once after the first publication, then after a change of the audience groups.
    Status            Shows the warehouse, the semantic model and the last publication. Changes nothing.
    AgentInstructions Writes the texts of the agents to the work folder, to paste into Fabric and Copilot Studio:
                      the instructions of the data agent (answer format) and its publication description, and the
                      instructions, tool description and language topic of the Copilot Studio agent for Teams.
                      Deploy never changes a data agent that already exists.

.PARAMETER ConfigPath
    Configuration file. Default: config\PurviewDlpReport-Fabric.config.psd1 next to this script.

.PARAMETER HistoryDays
    Overrides Source.HistoryDays for this execution.

.PARAMETER KeepWorkFiles
    Keeps the intermediate CSV files in the work folder (troubleshooting).

.EXAMPLE
    .\Publish-DlpReportToFabric.ps1
    Daily publication (scheduled task, after the collection of Purview DLP Report).

.EXAMPLE
    .\Publish-DlpReportToFabric.ps1 -Mode Deploy
    Creates the semantic model (first installation).

.EXAMPLE
    .\Publish-DlpReportToFabric.ps1 -Mode AgentInstructions
    Writes the texts to paste into the data agent and into the Copilot Studio agent.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.3.0
    Exit codes : 0 = success, 1 = failure, 2 = published, but the source period is incomplete.
    Documentation : docs\PurviewDlpReport-Fabric-Guide.md
#>
[CmdletBinding()]
param(
    [ValidateSet('Publish', 'Deploy', 'Status', 'AgentInstructions')]
    [string]$Mode = 'Publish',
    [string]$ConfigPath,
    [ValidateRange(1, 3660)]
    [int]$HistoryDays,
    [switch]$KeepWorkFiles
)

$ErrorActionPreference = 'Stop'
$script:Version = '1.3.0'
$script:Root = $PSScriptRoot
$script:Started = [Diagnostics.Stopwatch]::StartNew()

# =====================================================================================================
# Console and log
# =====================================================================================================
$script:LogFile = $null
$script:Warnings = [Collections.Generic.List[string]]::new()
function Write-Log([string]$Text) {
    if ($script:LogFile) { [IO.File]::AppendAllText($script:LogFile, ('{0:yyyy-MM-dd HH:mm:ss}  {1}{2}' -f (Get-Date), $Text, [Environment]::NewLine)) }
}
function Write-Step([int]$Number, [int]$Total, [string]$Text) {
    Write-Host ''; Write-Host ("  {0}/{1}  {2}" -f $Number, $Total, $Text) -ForegroundColor Cyan; Write-Log "STEP $Number/$Total $Text"
}
function Write-Info([string]$Text, [ConsoleColor]$Color = 'Gray') { Write-Host "       $Text" -ForegroundColor $Color; Write-Log "     $Text" }
function Write-Warn([string]$Text) { Write-Host "       ! $Text" -ForegroundColor Yellow; Write-Log "WARN $Text"; $script:Warnings.Add($Text) }

function Resolve-LocalPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $script:Root $Path))
}
function Format-Duration([TimeSpan]$Span) {
    if ($Span.TotalMinutes -ge 1) { return '{0} min {1:00} s' -f [int][Math]::Floor($Span.TotalMinutes), $Span.Seconds }
    return $Span.TotalSeconds.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + ' s'
}
function Format-Number($Value) { ([double]$Value).ToString('N0', [Globalization.CultureInfo]::InvariantCulture) }

# =====================================================================================================
# Configuration
# =====================================================================================================
function Read-Configuration([string]$Path) {
    if (-not $Path) { $Path = Join-Path $script:Root 'config\PurviewDlpReport-Fabric.config.psd1' }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Configuration file not found: $Path" }
    $c = Import-PowerShellDataFile -LiteralPath $Path
    foreach ($section in 'Source', 'Authentication', 'Fabric', 'Directory', 'Access', 'Local') {
        if (-not $c.ContainsKey($section)) { throw "Configuration: section '$section' is missing ($Path)." }
    }
    $guid = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
    if ($c.Authentication.TenantId -notmatch $guid) { throw 'Configuration: Authentication.TenantId must be a GUID.' }
    foreach ($k in 'WorkspaceId', 'WarehouseId') { if ($c.Fabric[$k] -notmatch $guid) { throw "Configuration: Fabric.$k must be a GUID." } }
    if ($c.Fabric.ConnectionId -and $c.Fabric.ConnectionId -notmatch $guid) { throw 'Configuration: Fabric.ConnectionId must be empty or a GUID.' }
    if ($c.Authentication.Mode -notin 'Certificate', 'Interactive') { throw 'Configuration: Authentication.Mode must be Certificate or Interactive.' }
    if ($c.Authentication.Mode -eq 'Certificate') {
        if ($c.Authentication.ApplicationId -notmatch $guid) { throw 'Configuration: Authentication.ApplicationId must be a GUID (Certificate mode).' }
        if ($c.Authentication.CertificateThumbprint -notmatch '^[0-9a-fA-F]{40}$') { throw 'Configuration: Authentication.CertificateThumbprint must be a 40-character thumbprint.' }
    }
    if ([int]$c.Source.HistoryDays -lt 1) { throw 'Configuration: Source.HistoryDays must be 1 or more.' }
    $c.ConfigFile = (Resolve-Path -LiteralPath $Path).Path
    return $c
}

# =====================================================================================================
# Sign-in and REST calls
# =====================================================================================================
$script:Resources = @{
    Fabric  = 'https://api.fabric.microsoft.com'
    Graph   = 'https://graph.microsoft.com'
    PowerBI = 'https://analysis.windows.net/powerbi/api'
    Sql     = 'https://database.windows.net/'
}
$script:Tokens = @{}

function Connect-Services($Config) {
    $module = Get-Module -ListAvailable Az.Accounts | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $module) { throw 'The module Az.Accounts is required: Install-Module Az.Accounts -Scope AllUsers' }
    Import-Module $module -ErrorAction Stop -WarningAction SilentlyContinue
    # The broker sign-in window (WAM) is not reliable in PowerShell 7 consoles: browser sign-in instead.
    try { Update-AzConfig -EnableLoginByWam $false -Scope Process -WarningAction SilentlyContinue | Out-Null } catch { }
    Disable-AzContextAutosave -Scope Process | Out-Null
    $a = $Config.Authentication
    $common = @{ Tenant = $a.TenantId; SkipContextPopulation = $true; WarningAction = 'SilentlyContinue'; ErrorAction = 'Stop' }
    if ($a.Mode -eq 'Certificate') {
        $cert = Get-Item -LiteralPath "Cert:\CurrentUser\My\$($a.CertificateThumbprint)" -ErrorAction SilentlyContinue
        if (-not $cert) { throw "Certificate $($a.CertificateThumbprint) not found in Cert:\CurrentUser\My of $env:USERNAME." }
        if ($cert.NotAfter -lt (Get-Date)) { throw "Certificate $($a.CertificateThumbprint) expired on $($cert.NotAfter.ToString('yyyy-MM-dd'))." }
        if ($cert.NotAfter -lt (Get-Date).AddDays(30)) { Write-Warn "The certificate expires on $($cert.NotAfter.ToString('yyyy-MM-dd'))." }
        Connect-AzAccount -ServicePrincipal -ApplicationId $a.ApplicationId -CertificateThumbprint $a.CertificateThumbprint @common | Out-Null
        return "application $($a.ApplicationId) (certificate)"
    }
    Write-Info 'Sign-in in the browser...'
    return (Connect-AzAccount @common).Context.Account.Id
}

function Get-Token([string]$Resource) {
    $cached = $script:Tokens[$Resource]
    if ($cached -and $cached.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) { return $cached.Token }
    $t = Get-AzAccessToken -ResourceUrl $script:Resources[$Resource] -WarningAction SilentlyContinue -ErrorAction Stop
    $plain = if ($t.Token -is [securestring]) { ConvertFrom-SecureString -SecureString $t.Token -AsPlainText } else { [string]$t.Token }
    $script:Tokens[$Resource] = @{ Token = $plain; ExpiresOn = [DateTimeOffset]$t.ExpiresOn }
    return $plain
}

$script:Http = [Net.Http.HttpClient]::new()
$script:Http.Timeout = [TimeSpan]::FromMinutes(15)

function Invoke-Api {
    <# REST call with retries (429 and 5xx, Retry-After honoured). Returns the parsed JSON body, or with -Raw
       the status, headers and text. #>
    param(
        [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Resource,
        $Body, [hashtable]$Headers, [switch]$Raw, [switch]$AllowNotFound, [int]$MaxAttempts = 6
    )
    for ($attempt = 1; ; $attempt++) {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Url)
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', (Get-Token $Resource))
        if ($Headers) { foreach ($k in $Headers.Keys) { [void]$request.Headers.TryAddWithoutValidation($k, [string]$Headers[$k]) } }
        if ($null -ne $Body) {
            $json = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 40 -Compress }
            $request.Content = [Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
        }
        try { $response = $script:Http.SendAsync($request).GetAwaiter().GetResult() }
        catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Start-Sleep -Seconds ([Math]::Min(60, 5 * $attempt)); continue
        }
        $status = [int]$response.StatusCode
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (($status -eq 429 -or $status -ge 500) -and $attempt -lt $MaxAttempts) {
            $wait = 5 * $attempt
            if ($response.Headers.RetryAfter -and $response.Headers.RetryAfter.Delta) { $wait = [Math]::Max(1, [int]$response.Headers.RetryAfter.Delta.Value.TotalSeconds) }
            Write-Log "RETRY $Method $($Url -replace '\?.*$', '') -> $status, waiting $wait s"
            Start-Sleep -Seconds ([Math]::Min(120, $wait)); continue
        }
        if ($AllowNotFound -and $status -eq 404) { return $null }
        if (-not $response.IsSuccessStatusCode) {
            $short = if ($text.Length -gt 800) { $text.Substring(0, 800) } else { $text }
            throw "$Method $($Url -replace '\?.*$', '') -> $status $short"
        }
        if ($Raw) { return [pscustomobject]@{ Status = $status; Headers = $response.Headers; Text = $text } }
        if ($text) { return $text | ConvertFrom-Json -Depth 64 }
        return $null
    }
}

function Wait-FabricOperation {
    <# Follows a Fabric long-running operation (202 + Location). Returns the result, if any. #>
    param([Parameter(Mandatory)]$Response, [int]$TimeoutSeconds = 1800, [string]$What = 'operation')
    if ($Response.Status -ne 202) { return $(if ($Response.Text) { $Response.Text | ConvertFrom-Json -Depth 64 }) }
    $location = $Response.Headers.Location.AbsoluteUri
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $delay = 2
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $delay; $delay = [Math]::Min(10, $delay + 1)
        $state = Invoke-Api GET $location Fabric
        if ($state.status -in 'Succeeded', 'Failed', 'Undefined', 'Cancelled') {
            if ($state.status -ne 'Succeeded') { throw "$What $($state.status): $($state.error | ConvertTo-Json -Compress -Depth 10)" }
            try { return Invoke-Api GET "$location/result" Fabric -AllowNotFound } catch { if ("$_" -match 'OperationHasNoResult') { return $null }; throw }
        }
    }
    throw "$What still running after $TimeoutSeconds s ($location)."
}

# =====================================================================================================
# Warehouse (T-SQL over TDS, Microsoft Entra token)
# =====================================================================================================
# Fixed schema: one row per Message ID; types are explicit, nothing is inferred from the data.
# Text: [maximum characters, VARCHAR size in bytes] (UTF-8 collation: up to 4 bytes per character).
$script:Schema = [ordered]@{
    dlp_messages    = [ordered]@{
        MessageId = 'string:998:1000:NOT NULL'; DetectedAt = 'datetime::DATETIME2(0):NOT NULL'; DetectedDate = 'date::DATE:NOT NULL'
        SenderAddress = 'string:320:1280'; SenderId = 'string:36:36'; Subject = 'string:1000:4000'; RecipientCount = 'int::INT'
    }
    directory_users = [ordered]@{
        UserId = 'string:36:36:NOT NULL'; UserPrincipalName = 'string:320:1280'; DisplayName = 'string:256:1024'; Mail = 'string:320:1280'
        BusinessLine = 'string:256:1024'; Department = 'string:256:1024'; Company = 'string:256:1024'; Office = 'string:256:1024'
        JobTitle = 'string:256:1024'; ManagerName = 'string:256:1024'; ManagerUpn = 'string:320:1280'; Manager2Name = 'string:256:1024'
        ManagerChain = 'string:1990:8000'
    }
    report_access   = [ordered]@{ Viewer = 'string:320:1280:NOT NULL'; BusinessLine = 'string:256:1024'; GroupName = 'string:256:1024' }
    publish_info    = [ordered]@{
        PublishedUtc = 'datetime::DATETIME2(0):NOT NULL'; PeriodStart = 'date::DATE'; PeriodEnd = 'date::DATE'; TimeZone = 'string:64:256'
        Messages = 'bigint::BIGINT'; Senders = 'int::INT'; UnresolvedSenders = 'int::INT'; Complete = 'bool::BIT'; Coverage = 'string:200:800'
        ToolVersion = 'string:20:80'
    }
}
function Get-ColumnSpec([string]$Spec) {
    $p = $Spec.Split(':')
    $sqlType = if ($p[0] -eq 'string') { "VARCHAR($($p[2]))" } else { $p[2] }
    [pscustomobject]@{ Kind = $p[0]; MaxChars = $(if ($p[1]) { [int]$p[1] } else { 0 }); SqlType = $sqlType; Null = $(if ($p.Count -gt 3 -and $p[3]) { $p[3] } else { 'NULL' }) }
}

function Get-Warehouse($Config) {
    Invoke-Api GET "https://api.fabric.microsoft.com/v1/workspaces/$($Config.Fabric.WorkspaceId)/warehouses/$($Config.Fabric.WarehouseId)" Fabric
}

function Open-Warehouse($Warehouse) {
    $server = $Warehouse.properties.connectionString
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    # PowerShell exposes connection string builders as dictionaries: use the keywords.
    $builder['Data Source'] = "tcp:$server,1433"; $builder['Initial Catalog'] = $Warehouse.displayName
    $builder['Encrypt'] = $true; $builder['TrustServerCertificate'] = $false; $builder['Connect Timeout'] = 60
    $builder['Application Name'] = "PurviewDlpReport-Fabric $script:Version"
    $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
    $connection.AccessToken = Get-Token Sql
    for ($attempt = 1; ; $attempt++) {
        try { $connection.Open(); return $connection }
        catch { if ($attempt -ge 4) { throw "Connection to the warehouse $server failed: $($_.Exception.InnerException.Message)" }; Start-Sleep -Seconds (10 * $attempt) }
    }
}

function Invoke-Sql($Connection, [string]$Sql, $Transaction, [switch]$Scalar, [switch]$Rows) {
    $command = $Connection.CreateCommand()
    $command.CommandText = $Sql; $command.CommandTimeout = 3600
    if ($Transaction) { $command.Transaction = $Transaction }
    try {
        if ($Scalar) { return $command.ExecuteScalar() }
        if ($Rows) {
            $reader = $command.ExecuteReader(); $table = [Data.DataTable]::new(); $table.Load($reader); $reader.Dispose()
            return , $table
        }
        [void]$command.ExecuteNonQuery()
    }
    finally { $command.Dispose() }
}

function Initialize-WarehouseSchema($Connection) {
    foreach ($table in $script:Schema.Keys) {
        $expected = $script:Schema[$table]
        $existing = Invoke-Sql $Connection "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = '$table' ORDER BY ORDINAL_POSITION" -Rows
        if ($existing.Rows.Count -eq 0) {
            $columns = foreach ($name in $expected.Keys) { $s = Get-ColumnSpec $expected[$name]; "[$name] $($s.SqlType) $($s.Null)" }
            Invoke-Sql $Connection "CREATE TABLE dbo.[$table] ($($columns -join ', '))"
            Write-Info "Table dbo.$table created"
            continue
        }
        $names = @($existing.Rows | ForEach-Object { $_.COLUMN_NAME })
        if (($names -join ',') -ne (@($expected.Keys) -join ',')) {
            throw "The table dbo.$table of the warehouse does not have the expected columns ($($names -join ', ')). Delete it in the warehouse (DROP TABLE dbo.$table) and publish again."
        }
    }
}

function Write-WarehouseTables($Connection, [System.Collections.IDictionary]$Files) {
    $transaction = $Connection.BeginTransaction()
    try {
        $counts = [ordered]@{}
        foreach ($table in $Files.Keys) {
            Invoke-Sql $Connection "DELETE FROM dbo.[$table]" $transaction
            $columns = $script:Schema[$table]
            $names = [string[]]@($columns.Keys)
            $specs = @($names | ForEach-Object { Get-ColumnSpec $columns[$_] })
            $reader = [PurviewDlpReportFabric.CsvBatchReader]::new($Files[$table], $names, [string[]]@($specs.Kind), [int[]]@($specs.MaxChars))
            $bulk = [System.Data.SqlClient.SqlBulkCopy]::new($Connection, [System.Data.SqlClient.SqlBulkCopyOptions]::Default, $transaction)
            try {
                $bulk.DestinationTableName = "dbo.[$table]"; $bulk.BulkCopyTimeout = 3600
                foreach ($n in $names) { [void]$bulk.ColumnMappings.Add($n, $n) }
                while ($reader.ReadBatch(100000)) { $bulk.WriteToServer($reader.Table) }
                $counts[$table] = $reader.Rows
            }
            finally { $bulk.Close(); $reader.Dispose() }
        }
        $transaction.Commit()
        return $counts
    }
    catch { try { $transaction.Rollback() } catch { }; throw }
}

# =====================================================================================================
# Source: Purview DLP Report
# =====================================================================================================
function Export-Source($Config, [string]$WorkPath, [int]$Days) {
    $tool = Resolve-LocalPath $Config.Source.ToolPath
    $toolScript = Join-Path $tool 'Invoke-PurviewDlpReport.ps1'
    if (-not (Test-Path -LiteralPath $toolScript)) { throw "Purview DLP Report not found: $toolScript (Source.ToolPath)." }
    $toolConfig = if ($Config.Source.ConfigPath) { Resolve-LocalPath $Config.Source.ConfigPath } else { Join-Path $tool 'config\PurviewDlpReport.config.psd1' }
    if (-not (Test-Path -LiteralPath $toolConfig)) { throw "Purview DLP Report configuration not found: $toolConfig." }

    # Copy of the tool configuration that writes the CSV only (relative paths stay relative to the tool folder).
    $text = Get-Content -LiteralPath $toolConfig -Raw
    $csvOnly = [regex]::Replace($text, '(?m)^(\s*Formats\s*=\s*)@\([^)]*\)', '$1@(''Csv'')')
    $delimiter = if ($text -match '(?m)^\s*CsvDelimiter\s*=\s*''(.)''') { $Matches[1] } else { ';' }
    $tempConfig = Join-Path $WorkPath 'source.config.psd1'
    Set-Content -LiteralPath $tempConfig -Value $csvOnly -Encoding utf8

    $today = (Get-Date).Date
    $start = $today.AddDays(-$Days).ToString('yyyy-MM-dd'); $end = $today.ToString('yyyy-MM-dd')
    $out = Join-Path $WorkPath 'source'
    Write-Info "Period: $start 00:00 -> $end 00:00 ($Days days, time zone of the report)"
    $pwsh = (Get-Process -Id $PID).Path
    $arguments = @('-NoProfile', '-NonInteractive', '-File', $toolScript, '-Mode', 'Report', '-Range', 'Custom', '-Start', $start, '-End', $end,
        '-NoCollect', '-IncludeRecipientDetails:$false', '-SplitBy', 'Rows', '-MaxRowsPerFile', '1048575', '-OutputPath', $out, '-ConfigPath', $tempConfig)
    $toolLog = Join-Path $WorkPath 'source.log'
    $errLog = Join-Path $WorkPath 'source.err.log'
    & $pwsh @arguments > $toolLog 2> $errLog
    $exit = $LASTEXITCODE
    $summary = @(Get-Content -LiteralPath $toolLog -ErrorAction SilentlyContinue | Where-Object { $_ -match 'Messages|Coverage|Error' } | ForEach-Object { $_.Trim() })
    foreach ($line in $summary) { Write-Log "     source: $line" }
    if ($exit -notin 0, 2) {
        $err = (@(Get-Content -LiteralPath $errLog -ErrorAction SilentlyContinue) + @($summary | Where-Object { $_ -match 'Error' })) -join ' '
        throw "Purview DLP Report failed (exit code $exit). See $toolLog. $err"
    }
    $files = @(Get-ChildItem -LiteralPath $out -Recurse -Filter '*.csv' -File | Sort-Object Name | ForEach-Object FullName)
    if (-not $files.Count) { throw "Purview DLP Report wrote no CSV file (see $toolLog)." }
    $coverage = ($summary | Where-Object { $_ -match 'Coverage' } | Select-Object -First 1) -replace '^.*?Coverage\s+', ''
    if ($exit -eq 2) { Write-Warn "The database of Purview DLP Report does not cover the whole period: $coverage" }
    return [pscustomobject]@{ Files = $files; Delimiter = $delimiter; Start = $start; End = $end; Complete = ($exit -eq 0); Coverage = $coverage }
}

# =====================================================================================================
# Directory and audiences (Microsoft Graph)
# =====================================================================================================
function Get-GraphPages([string]$Url) {
    $items = [Collections.Generic.List[object]]::new()
    while ($Url) {
        $page = Invoke-Api GET $Url Graph
        foreach ($v in $page.value) { $items.Add($v) }
        $Url = $page.'@odata.nextLink'
    }
    return $items
}

function Get-PropertyPath($Object, [string]$Path) {
    $v = $Object
    foreach ($part in $Path.Split('.')) { if ($null -eq $v) { return $null }; $v = $v.$part }
    return $v
}

function Read-Directory($Config) {
    $attribute = [string]$Config.Directory.BusinessLineAttribute
    $root = $attribute.Split('.')[0]
    $select = @('id', 'userPrincipalName', 'displayName', 'mail', 'proxyAddresses', 'department', 'companyName', 'officeLocation', 'jobTitle')
    if ($root -notin $select) { $select += $root }
    $users = Get-GraphPages "https://graph.microsoft.com/v1.0/users?`$select=$($select -join ',')&`$expand=manager(`$select=id)&`$top=999"
    $byId = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $addresses = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($u in $users) { $byId[$u.id] = $u }
    # Primary addresses first, then aliases, then user principal names.
    foreach ($u in $users) { if ($u.mail) { $a = $u.mail.ToLowerInvariant(); if (-not $addresses.ContainsKey($a)) { $addresses[$a] = $u.id } } }
    foreach ($u in $users) {
        foreach ($p in @($u.proxyAddresses)) { if ($p -match '^smtp:(.+)$') { $a = $Matches[1].ToLowerInvariant(); if (-not $addresses.ContainsKey($a)) { $addresses[$a] = $u.id } } }
    }
    foreach ($u in $users) { if ($u.userPrincipalName) { $a = $u.userPrincipalName.ToLowerInvariant(); if (-not $addresses.ContainsKey($a)) { $addresses[$a] = $u.id } } }
    return [pscustomobject]@{ Users = $byId; Addresses = $addresses; Attribute = $attribute }
}

function Write-DirectoryTable($Directory, $SenderIds, [int]$MaxLevels, [string]$Path) {
    $w = [IO.StreamWriter]::new($Path, $false, [Text.UTF8Encoding]::new($false)); $w.NewLine = "`n"
    $w.WriteLine(($script:Schema.directory_users.Keys -join ','))
    $n = 0; $withLine = 0; $withManager = 0
    try {
        foreach ($id in $SenderIds) {
            $u = $Directory.Users[$id]; if (-not $u) { continue }
            $chain = [Collections.Generic.List[string]]::new(); $names = [Collections.Generic.List[string]]::new()
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); [void]$seen.Add($u.id)
            $m = $u.manager
            for ($level = 0; $m -and $level -lt $MaxLevels; $level++) {
                if (-not $seen.Add($m.id)) { break }
                $mu = $Directory.Users[$m.id]; if (-not $mu) { break }
                $chain.Add(([string]$mu.userPrincipalName).ToLowerInvariant()); $names.Add([string]$mu.displayName)
                $m = $mu.manager
            }
            $line = [string](Get-PropertyPath $u $Directory.Attribute)
            if ($line) { $withLine++ }; if ($chain.Count) { $withManager++ }
            # Explicit values: an empty $(if ...) would drop its element from the array and shift the columns.
            $managerName = if ($names.Count) { $names[0] } else { $null }
            $managerUpn = if ($chain.Count) { $chain[0] } else { $null }
            $manager2Name = if ($names.Count -gt 1) { $names[1] } else { $null }
            $managerChain = if ($chain.Count) { '|' + ($chain -join '|') + '|' } else { $null }
            $values = @(
                $u.id, ([string]$u.userPrincipalName).ToLowerInvariant(), $u.displayName, ([string]$u.mail).ToLowerInvariant(), $line,
                $u.department, $u.companyName, $u.officeLocation, $u.jobTitle, $managerName, $managerUpn, $manager2Name, $managerChain
            )
            $w.WriteLine((($values | ForEach-Object { [PurviewDlpReportFabric.Normalizer]::Csv([string]$_) }) -join ',')); $n++
        }
    }
    finally { $w.Dispose() }
    return [pscustomobject]@{ Rows = $n; WithBusinessLine = $withLine; WithManager = $withManager }
}

function Resolve-Group([string]$Value) {
    if ($Value -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
        $g = Invoke-Api GET "https://graph.microsoft.com/v1.0/groups/$Value`?`$select=id,displayName" Graph -AllowNotFound
    }
    else {
        $filter = [Uri]::EscapeDataString("displayName eq '$($Value -replace "'", "''")'")
        $g = @((Invoke-Api GET "https://graph.microsoft.com/v1.0/groups?`$filter=$filter&`$select=id,displayName" Graph).value) | Select-Object -First 1
    }
    if (-not $g) { throw "Group not found: $Value" }
    return $g
}

function Write-AccessTable($Config, [string]$Path) {
    $lines = [ordered]@{}
    foreach ($k in $Config.Access.BusinessLineGroups.Keys) { $lines[[string]$k] = Resolve-Group ([string]$Config.Access.BusinessLineGroups[$k]) }
    $prefix = [string]$Config.Access.BusinessLineGroupPrefix
    if ($prefix) {
        $filter = [Uri]::EscapeDataString("startswith(displayName,'$($prefix -replace "'", "''")')")
        foreach ($g in (Get-GraphPages "https://graph.microsoft.com/v1.0/groups?`$filter=$filter&`$select=id,displayName&`$top=999")) {
            $name = $g.displayName.Substring($prefix.Length).Trim()
            if ($name -and -not $lines.Contains($name)) { $lines[$name] = $g }
        }
    }
    $w = [IO.StreamWriter]::new($Path, $false, [Text.UTF8Encoding]::new($false)); $w.NewLine = "`n"
    $w.WriteLine(($script:Schema.report_access.Keys -join ','))
    $rows = 0; $viewers = [Collections.Generic.HashSet[string]]::new()
    try {
        foreach ($line in $lines.Keys) {
            $g = $lines[$line]
            $members = Get-GraphPages "https://graph.microsoft.com/v1.0/groups/$($g.id)/transitiveMembers/microsoft.graph.user?`$select=id,userPrincipalName&`$top=999"
            foreach ($upn in ($members | Where-Object userPrincipalName | ForEach-Object { $_.userPrincipalName.ToLowerInvariant() } | Sort-Object -Unique)) {
                $w.WriteLine(('{0},{1},{2}' -f [PurviewDlpReportFabric.Normalizer]::Csv($upn), [PurviewDlpReportFabric.Normalizer]::Csv($line), [PurviewDlpReportFabric.Normalizer]::Csv($g.displayName)))
                $rows++; [void]$viewers.Add($upn)
            }
        }
    }
    finally { $w.Dispose() }
    return [pscustomobject]@{ BusinessLines = $lines.Count; Rows = $rows; Viewers = $viewers.Count }
}

# =====================================================================================================
# Semantic model (Direct Lake on the warehouse, TMDL)
# =====================================================================================================
$script:Tables = [ordered]@{ dlp_messages = 'Messages'; directory_users = 'Senders'; report_access = 'Report access'; publish_info = 'Publication' }
$script:TableInfo = @{
    dlp_messages    = @{ Description = 'One row per e-mail message (one Message ID) detected by the Microsoft Purview DLP rule because it was sent to more than 25 recipients.'; Synonyms = @('messages', 'mails', 'e-mails', 'courriels', 'envois') }
    directory_users = @{ Description = 'The person who sent the messages, from the company directory (Microsoft Entra ID) on the day of the publication.'; Synonyms = @('expéditeurs', 'émetteurs', 'personnes', 'collaborateurs', 'utilisateurs') }
    report_access   = @{ Description = 'Business-line correspondents (security). Used only by the row-level security.'; Synonyms = @() }
    publish_info    = @{ Description = 'Date and period of the last publication of the data.'; Synonyms = @('publication', 'mise à jour', 'fraîcheur des données') }
}
$script:ModelColumns = @{
    dlp_messages    = @{
        MessageId      = @{ Name = 'Message ID'; Description = 'Internet Message ID, the unique key of a message.'; Synonyms = @('identifiant du message') }
        DetectedAt     = @{ Name = 'Detected at'; Format = 'yyyy-mm-dd hh:nn:ss'; Description = 'When the DLP rule detected the message, in the time zone of the report.'; Synonyms = @('heure', 'date et heure', 'détection') }
        DetectedDate   = @{ Name = 'Date'; Format = 'yyyy-mm-dd'; Description = 'Day of the detection (time zone of the report). Use it for periods.'; Synonyms = @('jour', 'date') }
        SenderAddress  = @{ Name = 'Sender'; Description = 'E-mail address of the sender.'; Synonyms = @("adresse de l'expéditeur", 'adresse expéditeur', 'sender address') }
        SenderId       = @{ Name = 'Sender ID'; Hidden = $true }
        Subject        = @{ Name = 'Subject'; Description = 'Subject of the message.'; Synonyms = @('objet', 'sujet') }
        RecipientCount = @{ Name = 'Recipient count'; Format = '#,0'; Description = 'Number of recipients of the message (always more than 25).'; Synonyms = @('nombre de destinataires', 'destinataires') }
    }
    directory_users = @{
        UserId            = @{ Name = 'Sender ID'; Hidden = $true }
        UserPrincipalName = @{ Name = 'User principal name'; Description = 'Sign-in name of the sender.'; AiHidden = $true }
        DisplayName       = @{ Name = 'Name'; Description = 'Name of the sender.'; Synonyms = @('expéditeur', 'émetteur', 'nom', 'personne', 'collaborateur', 'sender') }
        Mail              = @{ Name = 'Address'; Description = 'E-mail address of the sender in the directory.'; Synonyms = @('adresse mail', 'e-mail') }
        BusinessLine      = @{ Name = 'Business line'; Description = 'Business line (service) of the sender.'; Synonyms = @('service', 'métier', 'direction', 'pôle', 'ligne métier', 'BU') }
        Department        = @{ Name = 'Department'; Description = 'Department attribute of the directory.'; Synonyms = @('département') }
        Company           = @{ Name = 'Entity'; Description = 'Company or legal entity of the sender.'; Synonyms = @('entité', 'société', 'filiale') }
        Office            = @{ Name = 'Site'; Description = 'Office location of the sender.'; Synonyms = @('site', 'bureau', 'localisation', 'ville') }
        JobTitle          = @{ Name = 'Job title'; Description = 'Job title of the sender.'; Synonyms = @('fonction', 'poste', 'intitulé de poste') }
        ManagerName       = @{ Name = 'Manager'; Description = 'Direct manager (N+1) of the sender.'; Synonyms = @('manager', 'responsable', 'chef', 'N+1', 'supérieur hiérarchique') }
        ManagerUpn        = @{ Name = 'Manager UPN'; Hidden = $true }
        Manager2Name      = @{ Name = 'Manager N+2'; Description = 'Manager of the manager (N+2) of the sender.'; Synonyms = @('N+2', 'directeur', 'responsable du manager') }
        ManagerChain      = @{ Name = 'Manager chain'; Hidden = $true }
    }
    report_access   = @{ Viewer = @{ Name = 'Viewer' }; BusinessLine = @{ Name = 'Business line' }; GroupName = @{ Name = 'Group' } }
    publish_info    = @{
        PublishedUtc      = @{ Name = 'Published (UTC)'; Format = 'yyyy-mm-dd hh:nn'; Description = 'When the data was published (UTC).'; Synonyms = @('date de publication', 'dernière mise à jour') }
        PeriodStart       = @{ Name = 'Period start'; Format = 'yyyy-mm-dd'; Description = 'First day of the published period.'; Synonyms = @('début de période') }
        PeriodEnd         = @{ Name = 'Period end'; Format = 'yyyy-mm-dd'; Description = 'Day after the last day of the published period.'; Synonyms = @('fin de période') }
        TimeZone          = @{ Name = 'Time zone'; Description = 'Time zone of the dates of the messages.' }
        Messages          = @{ Name = 'Messages published'; Format = '#,0'; Description = 'Number of messages published (all business lines).' }
        Senders           = @{ Name = 'Senders published'; Format = '#,0'; Description = 'Number of senders published.' }
        UnresolvedSenders = @{ Name = 'Senders not in the directory'; Format = '#,0'; Description = 'Senders whose address is not in the directory.' }
        Complete          = @{ Name = 'Complete'; Description = 'True when the source database covers the whole period.' }
        Coverage          = @{ Name = 'Coverage'; Description = 'Share of the period covered by the source database.'; Synonyms = @('couverture') }
        ToolVersion       = @{ Name = 'Publisher version'; AiHidden = $true }
    }
}
$script:Measures = @{
    dlp_messages = @(
        @{ Name = 'Messages'; Expression = 'COUNTROWS ( Messages )'; Format = '#,0'; Description = 'Number of messages (each one sent to more than 25 recipients).'; Synonyms = @('nombre de messages', 'nombre de mails', 'volume', 'combien de messages') }
        @{ Name = 'Distinct senders'; Expression = 'DISTINCTCOUNT ( Messages[Sender] )'; Format = '#,0'; Description = 'Number of different senders.'; Synonyms = @("nombre d'expéditeurs", 'expéditeurs distincts') }
        @{ Name = 'Recipients'; Expression = 'SUM ( Messages[Recipient count] )'; Format = '#,0'; Description = 'Total number of recipients of the messages.'; Synonyms = @('total des destinataires', 'destinataires cumulés') }
        @{ Name = 'Average recipients'; Expression = 'DIVIDE ( [Recipients], [Messages] )'; Format = '#,0.0'; Description = 'Average number of recipients per message.'; Synonyms = @('moyenne de destinataires') }
        @{ Name = 'Largest message'; Expression = 'MAX ( Messages[Recipient count] )'; Format = '#,0'; Description = 'Highest number of recipients of one message.'; Synonyms = @('plus gros envoi', 'maximum de destinataires') }
        @{ Name = '26-30 recipients'; Expression = 'CALCULATE ( [Messages], Messages[Recipient count] <= 30 )'; Format = '#,0'; Description = 'Messages sent to 26 to 30 recipients.'; Synonyms = @('26 à 30 destinataires') }
        @{ Name = '31-40 recipients'; Expression = 'CALCULATE ( [Messages], Messages[Recipient count] >= 31, Messages[Recipient count] <= 40 )'; Format = '#,0'; Description = 'Messages sent to 31 to 40 recipients.'; Synonyms = @('31 à 40 destinataires') }
        @{ Name = '41-60 recipients'; Expression = 'CALCULATE ( [Messages], Messages[Recipient count] >= 41, Messages[Recipient count] <= 60 )'; Format = '#,0'; Description = 'Messages sent to 41 to 60 recipients.'; Synonyms = @('41 à 60 destinataires') }
        @{ Name = '61+ recipients'; Expression = 'CALCULATE ( [Messages], Messages[Recipient count] >= 61 )'; Format = '#,0'; Description = 'Messages sent to 61 recipients or more.'; Synonyms = @('plus de 60 destinataires') }
        @{ Name = '26-30 display'; Expression = 'VAR n = [26-30 recipients] + 0 RETURN FORMAT ( n, "#,0" ) & "  ·  " & FORMAT ( DIVIDE ( n, [Messages], 0 ), "0%" )'; Description = 'Report display text: count and share of messages sent to 26 to 30 recipients.'; Hidden = $true }
        @{ Name = '31-40 display'; Expression = 'VAR n = [31-40 recipients] + 0 RETURN FORMAT ( n, "#,0" ) & "  ·  " & FORMAT ( DIVIDE ( n, [Messages], 0 ), "0%" )'; Description = 'Report display text: count and share of messages sent to 31 to 40 recipients.'; Hidden = $true }
        @{ Name = '41-60 display'; Expression = 'VAR n = [41-60 recipients] + 0 RETURN FORMAT ( n, "#,0" ) & "  ·  " & FORMAT ( DIVIDE ( n, [Messages], 0 ), "0%" )'; Description = 'Report display text: count and share of messages sent to 41 to 60 recipients.'; Hidden = $true }
        @{ Name = '61+ display'; Expression = 'VAR n = [61+ recipients] + 0 RETURN FORMAT ( n, "#,0" ) & "  ·  " & FORMAT ( DIVIDE ( n, [Messages], 0 ), "0%" )'; Description = 'Report display text: count and share of messages sent to 61 recipients or more.'; Hidden = $true }
        @{ Name = 'Detection range'; Expression = 'VAR a = MIN ( Messages[Detected at] ) VAR b = MAX ( Messages[Detected at] ) RETURN IF ( ISBLANK ( a ), "No message in your scope", FORMAT ( a, "yyyy-mm-dd hh:nn" ) & "  →  " & FORMAT ( b, "yyyy-mm-dd hh:nn" ) )'; Description = 'First and last detection time of the messages in view.' }
    )
    publish_info = @(
        @{ Name = 'Data as of'; Expression = '"Published " & FORMAT ( MAX ( Publication[Published (UTC)] ), "yyyy-mm-dd hh:nn" ) & " UTC  ·  period " & FORMAT ( MAX ( Publication[Period start] ), "yyyy-mm-dd" ) & " → " & FORMAT ( MAX ( Publication[Period end] ) - 1, "yyyy-mm-dd" )'; Description = 'Date of the publication and period covered.' }
        @{ Name = 'Last published'; Expression = 'FORMAT ( MAX ( Publication[Published (UTC)] ), "yyyy-mm-dd hh:nn" )'; Description = 'When the data was last published (UTC).'; Synonyms = @('dernière publication', 'mise à jour') }
        @{ Name = 'Period covered'; Expression = 'FORMAT ( MAX ( Publication[Period start] ), "yyyy-mm-dd" ) & " → " & FORMAT ( MAX ( Publication[Period end] ) - 1, "yyyy-mm-dd" )'; Description = 'First and last day of the published period.'; Synonyms = @('période couverte') }
        @{ Name = 'Coverage %'; Expression = 'VAR t = MAX ( Publication[Coverage] ) RETURN LEFT ( t, SEARCH ( "%", t, 1, LEN ( t ) ) )'; Description = 'Share of the period collected by Purview DLP Report.'; Synonyms = @('taux de couverture') }
    )
}
function Get-StableGuid([string]$Text) {
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("PurviewDlpReport-Fabric|$Text"))
    return [guid]::new([byte[]]$hash[0..15]).ToString()
}
function Format-TmdlName([string]$Name) { if ($Name -match '^[A-Za-z_][A-Za-z0-9_]*$') { $Name } else { "'" + ($Name -replace "'", "''") + "'" } }

function New-ModelDefinition($Warehouse, [string[]]$BusinessLines) {
    $parts = [ordered]@{}
    $server = $Warehouse.properties.connectionString
    # Format 5.0: the Copilot folder (instructions, AI data schema) is part of the definition.
    $parts['definition.pbism'] = '{ "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/semanticModel/definitionProperties/1.0.0/schema.json", "version": "5.0", "settings": { "qnaEnabled": true } }'
    $parts['definition/database.tmdl'] = "database`n`tcompatibilityLevel: 1604`n"
    $parts['definition/model.tmdl'] = "model Model`n`tculture: en-US`n`tdefaultPowerBIDataSourceVersion: powerBI_V3`n`tsourceQueryCulture: en-US`n`tdataAccessOptions`n`t`tlegacyRedirects`n`t`treturnErrorValuesAsNull`n`nannotation PurviewDlpReportFabric = $script:Version`n"
    $parts['definition/expressions.tmdl'] = "expression DatabaseQuery =`n`t`tlet`n`t`t    database = Sql.Database(`"$server`", `"$($Warehouse.id)`")`n`t`tin`n`t`t    database`n`tlineageTag: $(Get-StableGuid 'expression')`n"
    foreach ($entity in $script:Tables.Keys) {
        $tableName = $script:Tables[$entity]
        $sb = [Text.StringBuilder]::new()
        [void]$sb.AppendLine("/// $($script:TableInfo[$entity].Description)")
        [void]$sb.AppendLine("table $(Format-TmdlName $tableName)")
        [void]$sb.AppendLine("`tlineageTag: $(Get-StableGuid "table|$entity")")
        [void]$sb.AppendLine("`tsourceLineageTag: [dbo].[$entity]")
        if ($entity -eq 'report_access') { [void]$sb.AppendLine("`tisHidden") }
        [void]$sb.AppendLine()
        foreach ($m in @($script:Measures[$entity])) {
            if (-not $m) { continue }
            if ($m.Description) { [void]$sb.AppendLine("`t/// $($m.Description)") }
            [void]$sb.AppendLine("`tmeasure $(Format-TmdlName $m.Name) = $($m.Expression)")
            if ($m.Format) { [void]$sb.AppendLine("`t`tformatString: $($m.Format)") }
            if ($m.Hidden) { [void]$sb.AppendLine("`t`tisHidden") }
            [void]$sb.AppendLine("`t`tlineageTag: $(Get-StableGuid "measure|$entity|$($m.Name)")")
            [void]$sb.AppendLine()
        }
        foreach ($source in $script:Schema[$entity].Keys) {
            $meta = $script:ModelColumns[$entity][$source]
            $type = switch ((Get-ColumnSpec $script:Schema[$entity][$source]).Kind) { 'string' { 'string' } { $_ -in 'int', 'bigint' } { 'int64' } { $_ -in 'datetime', 'date' } { 'dateTime' } 'bool' { 'boolean' } }
            if ($meta.Description) { [void]$sb.AppendLine("`t/// $($meta.Description)") }
            [void]$sb.AppendLine("`tcolumn $(Format-TmdlName $meta.Name)")
            [void]$sb.AppendLine("`t`tdataType: $type")
            if ($meta.Format) { [void]$sb.AppendLine("`t`tformatString: $($meta.Format)") }
            if ($meta.Hidden) { [void]$sb.AppendLine("`t`tisHidden") }
            [void]$sb.AppendLine("`t`tlineageTag: $(Get-StableGuid "column|$entity|$source")")
            [void]$sb.AppendLine("`t`tsourceLineageTag: $source")
            [void]$sb.AppendLine("`t`tsummarizeBy: none")
            [void]$sb.AppendLine("`t`tsourceColumn: $source")
            [void]$sb.AppendLine()
        }
        [void]$sb.AppendLine("`tpartition $(Format-TmdlName $tableName) = entity")
        [void]$sb.AppendLine("`t`tmode: directLake")
        [void]$sb.AppendLine("`t`tsource")
        [void]$sb.AppendLine("`t`t`tentityName: $entity")
        [void]$sb.AppendLine("`t`t`tschemaName: dbo")
        [void]$sb.AppendLine("`t`t`texpressionSource: DatabaseQuery")
        $parts["definition/tables/$tableName.tmdl"] = $sb.ToString()
    }
    $parts['definition/relationships.tmdl'] = "relationship $(Get-StableGuid 'relationship|sender')`n`tfromColumn: Messages.'Sender ID'`n`ttoColumn: Senders.'Sender ID'`n"
    # Row-level security. Scoped = own messages + people who report to the reader + business lines of the reader.
    $scoped = 'VAR me = LOWER ( USERPRINCIPALNAME () ) RETURN Senders[User principal name] = me || CONTAINSSTRING ( Senders[Manager chain], "|" & me & "|" ) || Senders[Business line] IN SELECTCOLUMNS ( FILTER ( ''Report access'', ''Report access''[Viewer] = me ), "Line", ''Report access''[Business line] )'
    # The members of the roles are not part of an item definition: they are assigned in the Power BI service and kept by updates.
    $roles = [ordered]@{
        Compliance = @()
        Scoped     = @("tablePermission Senders = $scoped", "tablePermission 'Report access' = 'Report access'[Viewer] = LOWER ( USERPRINCIPALNAME () )")
    }
    foreach ($role in $roles.Keys) {
        $sb = [Text.StringBuilder]::new()
        [void]$sb.AppendLine("role $role")
        [void]$sb.AppendLine("`tmodelPermission: read")
        [void]$sb.AppendLine()
        foreach ($p in $roles[$role]) { [void]$sb.AppendLine("`t$p"); [void]$sb.AppendLine() }
        $parts["definition/roles/$role.tmdl"] = $sb.ToString()
    }
    foreach ($k in ($copilot = New-CopilotParts $BusinessLines).Keys) { $parts[$k] = $copilot[$k] }
    return @{ parts = @($parts.Keys | ForEach-Object { @{ path = $_; payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($parts[$_])); payloadType = 'InlineBase64' } }) }
}

function Get-WorkspaceItem($Config, [string]$Type, [string]$Name) {
    $items = Invoke-Api GET "https://api.fabric.microsoft.com/v1/workspaces/$($Config.Fabric.WorkspaceId)/items?type=$Type" Fabric
    return @($items.value | Where-Object displayName -eq $Name) | Select-Object -First 1
}

function Get-RoleGroups($Config) {
    # Checks that the audience groups exist; returns their names for the reminder of -Mode Deploy.
    return [ordered]@{
        Compliance = @($Config.Access.ComplianceGroups | Where-Object { $_ } | ForEach-Object { (Resolve-Group $_).displayName })
        Scoped     = @($Config.Access.ViewerGroups | Where-Object { $_ } | ForEach-Object { (Resolve-Group $_).displayName })
    }
}

function Publish-Model($Config, $Warehouse, [string[]]$BusinessLines) {
    $definition = New-ModelDefinition $Warehouse $BusinessLines
    $api = "https://api.fabric.microsoft.com/v1/workspaces/$($Config.Fabric.WorkspaceId)/semanticModels"
    $model = Get-WorkspaceItem $Config 'SemanticModel' $Config.Fabric.SemanticModelName
    if ($model) {
        Wait-FabricOperation (Invoke-Api POST "$api/$($model.id)/updateDefinition" Fabric -Body @{ definition = $definition } -Raw) -What 'Update of the semantic model' | Out-Null
        Write-Info "Semantic model updated: $($model.displayName) ($($model.id))"
    }
    else {
        $body = @{ displayName = $Config.Fabric.SemanticModelName; description = 'Purview DLP Report - messages per business line, manager and sender (Direct Lake, row-level security).'; definition = $definition }
        Wait-FabricOperation (Invoke-Api POST $api Fabric -Body $body -Raw) -What 'Creation of the semantic model' | Out-Null
        $model = Get-WorkspaceItem $Config 'SemanticModel' $Config.Fabric.SemanticModelName
        Write-Info "Semantic model created: $($model.displayName) ($($model.id))"
    }
    if ($Config.Fabric.ConnectionId) {
        $body = @{ connectionBinding = @{ id = $Config.Fabric.ConnectionId; connectivityType = 'ShareableCloud'; connectionDetails = @{ type = 'SQL'; path = "$($Warehouse.properties.connectionString);$($Warehouse.id)" } } }
        Invoke-Api POST "$api/$($model.id)/bindConnection" Fabric -Body $body -Raw | Out-Null
        Write-Info "Data access through the cloud connection $($Config.Fabric.ConnectionId) (fixed identity)"
    }
    else { Write-Warn 'Fabric.ConnectionId is empty: readers need access to the warehouse (single sign-on). See the guide, fixed identity.' }
    return $model
}

function Publish-DataAgent($Config, $Model, $Report) {
    # The agent is created once, as a draft. A person publishes it in Fabric (Publish, and Publish to Microsoft 365
    # Copilot): Microsoft 365 registers the first person who publishes as its owner. An existing agent is never
    # changed by this script, so that its publication is kept.
    $agent = Get-WorkspaceItem $Config 'DataAgent' $Config.Fabric.DataAgentName
    if ($agent) {
        Write-Info "Data agent kept as it is: $($agent.displayName) ($($agent.id)). New answer format or instructions: -Mode AgentInstructions (guide, chapter 11)." DarkGray
        return $agent
    }
    $description = 'Answers questions about the e-mail messages sent to more than 25 recipients that the Microsoft Purview DLP rule detected: who sends them, in which business line (service), entity, site, under which manager, when, and how many recipients. Answers are limited to what the person who asks is allowed to see.'
    $reportUrl = if ($Report) { "https://app.powerbi.com/groups/$($Config.Fabric.WorkspaceId)/reports/$($Report.id)" } else { $null }
    $definition = New-DataAgentDefinition $Config $Model $description $reportUrl -DraftOnly
    $body = @{ displayName = $Config.Fabric.DataAgentName; type = 'DataAgent'; description = 'Questions about the messages sent to more than 25 recipients (Purview DLP Report), per business line, manager and sender.'; definition = $definition }
    Wait-FabricOperation (Invoke-Api POST "https://api.fabric.microsoft.com/v1/workspaces/$($Config.Fabric.WorkspaceId)/items" Fabric -Body $body -Raw) -What 'Creation of the data agent' | Out-Null
    $agent = Get-WorkspaceItem $Config 'DataAgent' $Config.Fabric.DataAgentName
    Write-Info "Data agent created (draft): $($agent.displayName) ($($agent.id))"
    Write-Info 'Publish it once in Fabric: open the agent > Publish, with the description written by -Mode AgentInstructions (guide, chapter 11).' Yellow
    return $agent
}
function Publish-Report($Config, $Model) {
    $definition = New-ReportDefinition $Model.id $Config.Fabric.ReportName
    $api = "https://api.fabric.microsoft.com/v1/workspaces/$($Config.Fabric.WorkspaceId)/reports"
    $report = Get-WorkspaceItem $Config 'Report' $Config.Fabric.ReportName
    if ($report) {
        Wait-FabricOperation (Invoke-Api POST "$api/$($report.id)/updateDefinition" Fabric -Body @{ definition = $definition } -Raw) -What 'Update of the report' | Out-Null
        Write-Info "Report updated: $($report.displayName) ($($report.id))"
    }
    else {
        $body = @{ displayName = $Config.Fabric.ReportName; description = 'Purview DLP Report - messages per business line, manager and sender.'; definition = $definition }
        Wait-FabricOperation (Invoke-Api POST $api Fabric -Body $body -Raw) -What 'Creation of the report' | Out-Null
        $report = Get-WorkspaceItem $Config 'Report' $Config.Fabric.ReportName
        Write-Info "Report created: $($report.displayName) ($($report.id))"
    }
    Write-Info "https://app.powerbi.com/groups/$($Config.Fabric.WorkspaceId)/reports/$($report.id)" DarkGray
    return $report
}

function Update-ModelData($Config, $Model) {
    $url = "https://api.powerbi.com/v1.0/myorg/groups/$($Config.Fabric.WorkspaceId)/datasets/$($Model.id)/refreshes"
    $r = Invoke-Api POST $url PowerBI -Body @{ type = 'full'; retryCount = 1 } -Raw
    $location = if ($r.Headers.Location) { $r.Headers.Location.AbsoluteUri } else { "$url/$($r.Headers.GetValues('RequestId') | Select-Object -First 1)" }
    $deadline = [DateTime]::UtcNow.AddMinutes(30)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 3
        $state = Invoke-Api GET $location PowerBI
        if ($state.status -in 'Completed', 'Failed', 'Cancelled', 'Disabled') {
            if ($state.status -ne 'Completed') { throw "Refresh of the semantic model: $($state.status) $($state.messages | ConvertTo-Json -Compress -Depth 6)" }
            return
        }
    }
    throw 'Refresh of the semantic model still running after 30 min.'
}

# =====================================================================================================
# Main
# =====================================================================================================
$exitCode = 0
$work = $null
$connection = $null
try {
    $config = Read-Configuration $ConfigPath
    $logPath = Resolve-LocalPath $config.Local.LogPath
    [void][IO.Directory]::CreateDirectory($logPath)
    $script:LogFile = Join-Path $logPath ('PurviewDlpReport-Fabric_{0:yyyyMMdd}.log' -f (Get-Date))
    Get-ChildItem -LiteralPath $logPath -Filter 'PurviewDlpReport-Fabric_*.log' -File |
        Where-Object LastWriteTime -lt (Get-Date).AddDays(-[int]$config.Local.LogRetentionDays) | Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host "  Purview DLP Report for Microsoft Fabric $script:Version  -  $Mode" -ForegroundColor White
    Write-Log "===== $Mode (version $script:Version, $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME, config $($config.ConfigFile))"
    . (Join-Path $script:Root 'src\ReportDefinition.ps1')
    . (Join-Path $script:Root 'src\AiDefinition.ps1')
    if (-not ('PurviewDlpReportFabric.Normalizer' -as [type])) {
        Add-Type -Path (Join-Path $script:Root 'src\PurviewDlpReport.Fabric.cs') -ErrorAction Stop -ReferencedAssemblies @(
            'System.Runtime', 'System.IO', 'System.Collections', 'System.Collections.NonGeneric', 'System.Runtime.Extensions', 'System.Text.Encoding.Extensions',
            'System.Data.Common', 'System.ComponentModel.TypeConverter', 'System.ComponentModel.Primitives', 'System.Xml.ReaderWriter')
    }

    switch ($Mode) {
        'Publish' {
            $days = if ($PSBoundParameters.ContainsKey('HistoryDays')) { $HistoryDays } else { [int]$config.Source.HistoryDays }
            $work = Join-Path (Resolve-LocalPath $config.Local.WorkPath) ('{0:yyyyMMdd_HHmmss}' -f (Get-Date))
            [void][IO.Directory]::CreateDirectory($work)
            $total = 6
            $t = [Diagnostics.Stopwatch]::StartNew()

            Write-Step 1 $total 'Exporting the messages from Purview DLP Report (local database, -NoCollect)'
            $source = Export-Source $config $work $days
            Write-Info "$($source.Files.Count) CSV file(s) in $(Format-Duration $t.Elapsed)"

            Write-Step 2 $total 'Signing in'
            Write-Info "Signed in: $(Connect-Services $config)"

            Write-Step 3 $total 'Reading the directory (Microsoft Entra ID)'
            $t.Restart()
            $directory = Read-Directory $config
            Write-Info ('{0} users, {1} addresses, in {2}' -f (Format-Number $directory.Users.Count), (Format-Number $directory.Addresses.Count), (Format-Duration $t.Elapsed))

            Write-Step 4 $total 'Preparing the tables'
            $files = [ordered]@{}
            foreach ($table in $script:Schema.Keys) { $files[$table] = Join-Path $work "$table.csv" }
            $n = [PurviewDlpReportFabric.Normalizer]::Run([string[]]$source.Files, $source.Delimiter, $directory.Addresses, $files.dlp_messages)
            Write-Info ('Messages: {0} unique  ·  senders found in the directory: {1}  ·  not found: {2} ({3} messages)' -f (Format-Number $n.Rows), (Format-Number $n.SenderIds.Count), (Format-Number $n.UnresolvedSenders.Count), (Format-Number $n.UnresolvedRows))
            if ($n.UnresolvedSenders.Count) {
                Write-Log ('     senders not found: ' + (($n.UnresolvedSenders | Select-Object -First 50) -join ', '))
                Write-Info 'The messages of senders not found in the directory are visible to the compliance team only.' DarkGray
            }
            $d = Write-DirectoryTable $directory $n.SenderIds ([int]$config.Directory.MaxManagerLevels) $files.directory_users
            Write-Info ('Senders: {0}  ·  with a business line ({1}): {2}  ·  with a manager: {3}' -f (Format-Number $d.Rows), $directory.Attribute, (Format-Number $d.WithBusinessLine), (Format-Number $d.WithManager))
            if ($d.Rows -and $d.WithBusinessLine -lt $d.Rows) { Write-Warn ('{0} sender(s) without business line: only their managers and the compliance team see their messages.' -f (Format-Number ($d.Rows - $d.WithBusinessLine))) }
            $a = Write-AccessTable $config $files.report_access
            Write-Info ('Correspondents: {0} business line(s), {1} person(s)' -f $a.BusinessLines, $a.Viewers)
            $coverage = if ($source.Complete) { '100%' } else { $source.Coverage }
            $values = @(('{0:yyyy-MM-dd HH:mm:ss}' -f [DateTime]::UtcNow), $source.Start, $source.End, $n.TimeZoneLabel, $n.Rows, $d.Rows, $n.UnresolvedSenders.Count,
                $source.Complete.ToString().ToLowerInvariant(), $coverage, $script:Version)
            $info = "$($script:Schema.publish_info.Keys -join ',')`n" + (($values | ForEach-Object { [PurviewDlpReportFabric.Normalizer]::Csv([string]$_) }) -join ',')
            [IO.File]::WriteAllText($files.publish_info, "$info`n", [Text.UTF8Encoding]::new($false))

            Write-Step 5 $total 'Replacing the warehouse tables (one transaction)'
            $t.Restart()
            $warehouse = Get-Warehouse $config
            $connection = Open-Warehouse $warehouse
            Initialize-WarehouseSchema $connection
            $counts = Write-WarehouseTables $connection $files
            Write-Info ('{0}  ·  {1}  in {2}' -f $warehouse.displayName, (($counts.Keys | ForEach-Object { "$_ $(Format-Number $counts[$_])" }) -join '  ·  '), (Format-Duration $t.Elapsed))

            Write-Step 6 $total 'Refreshing the semantic model'
            $t.Restart()
            $model = Get-WorkspaceItem $config 'SemanticModel' $config.Fabric.SemanticModelName
            if (-not $model) { Write-Info "No semantic model '$($config.Fabric.SemanticModelName)' yet: run -Mode Deploy once." Yellow }
            else { Update-ModelData $config $model; Write-Info "$($model.displayName) refreshed in $(Format-Duration $t.Elapsed)" }

            if (-not $source.Complete) { $exitCode = 2 }
            if (-not $KeepWorkFiles) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue; $work = $null }
        }
        'Deploy' {
            Write-Step 1 4 'Signing in'
            Write-Info "Signed in: $(Connect-Services $config)"
            Write-Step 2 4 'Semantic model (Direct Lake, row-level security)'
            $warehouse = Get-Warehouse $config
            $connection = Open-Warehouse $warehouse
            Initialize-WarehouseSchema $connection
            $lines = @((Invoke-Sql $connection 'SELECT DISTINCT BusinessLine FROM dbo.directory_users WHERE BusinessLine IS NOT NULL' -Rows).Rows | ForEach-Object { [string]$_.BusinessLine })
            $model = Publish-Model $config $warehouse $lines
            Write-Info "Prepared for AI: descriptions, synonyms, instructions ($($lines.Count) business lines), example prompts"
            Write-Step 3 4 'Refreshing the semantic model'
            Update-ModelData $config $model
            Write-Info 'Done.'
            Write-Step 4 4 'Report and data agent'
            $report = Publish-Report $config $model
            if ($config.Fabric.DataAgentName) { $agent = Publish-DataAgent $config $model $report }
            $groups = Get-RoleGroups $config
            Write-Info 'Once, in the Power BI service (semantic model > Security), if not done yet:' Yellow
            foreach ($r in $groups.Keys) { Write-Info ("  role {0,-11} <- {1}" -f $r, $(if ($groups[$r]) { $groups[$r] -join ', ' } else { '(no group in the configuration)' })) Yellow }
            Write-Info 'Then share the report with these groups (read only) or publish an app. See the guide, chapter 7.' Yellow
        }
        'AgentInstructions' {
            Write-Step 1 2 'Signing in'
            Write-Info "Signed in: $(Connect-Services $config)"
            Write-Step 2 2 'Texts of the data agent and of the Copilot Studio agent'
            $report = Get-WorkspaceItem $config 'Report' $config.Fabric.ReportName
            $reportUrl = if ($report) { "https://app.powerbi.com/groups/$($config.Fabric.WorkspaceId)/reports/$($report.id)" } else { $null }
            $folder = Resolve-LocalPath $config.Local.WorkPath
            [void][IO.Directory]::CreateDirectory($folder)
            $texts = [ordered]@{
                'agent-instructions.txt'               = New-DataAgentInstructions $reportUrl
                'agent-publish-description.txt'        = New-DataAgentPublishDescription
                'copilot-studio-instructions.txt'      = New-CopilotStudioInstructions $reportUrl
                'copilot-studio-tool-description.txt'  = New-CopilotStudioToolDescription
                'copilot-studio-language-topic.yaml'   = [IO.File]::ReadAllText((Join-Path $script:Root 'src\copilot-studio\conversation-language.yaml'))
            }
            foreach ($name in $texts.Keys) {
                $file = Join-Path $folder $name
                [IO.File]::WriteAllText($file, $texts[$name], [Text.UTF8Encoding]::new($false))
                Write-Info "Written: $file"
            }
            Write-Info 'Fabric data agent: Agent instructions = agent-instructions.txt, then Publish with the description agent-publish-description.txt.' Yellow
            Write-Info 'Copilot Studio agent (Teams): instructions, tool description and language topic from the copilot-studio-* files (guide, chapter 12).' Yellow
        }
        'Status' {
            Write-Step 1 2 'Signing in'
            Write-Info "Signed in: $(Connect-Services $config)"
            Write-Step 2 2 'Fabric items'
            $warehouse = Get-Warehouse $config
            Write-Info "Warehouse       $($warehouse.displayName) ($($warehouse.id))"
            Write-Info "SQL endpoint    $($warehouse.properties.connectionString)"
            $connection = Open-Warehouse $warehouse
            foreach ($table in $script:Schema.Keys) {
                $exists = Invoke-Sql $connection "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA = 'dbo' AND TABLE_NAME = '$table'" -Scalar
                $count = if ($exists) { Format-Number (Invoke-Sql $connection "SELECT COUNT_BIG(*) FROM dbo.[$table]" -Scalar) } else { 'missing' }
                Write-Info ('Table {0,-16} {1}' -f $table, $count)
            }
            $model = Get-WorkspaceItem $config 'SemanticModel' $config.Fabric.SemanticModelName
            Write-Info "Semantic model  $(if ($model) { "$($model.displayName) ($($model.id))" } else { 'missing (-Mode Deploy)' })"
            if (Invoke-Sql $connection "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'publish_info'" -Scalar) {
                $last = Invoke-Sql $connection 'SELECT TOP 1 * FROM dbo.publish_info ORDER BY PublishedUtc DESC' -Rows
                foreach ($r in $last.Rows) {
                    Write-Info ('Last publication {0:yyyy-MM-dd HH:mm} UTC  ·  period {1:yyyy-MM-dd} -> {2:yyyy-MM-dd}  ·  {3} messages  ·  coverage {4}' -f $r.PublishedUtc, $r.PeriodStart, $r.PeriodEnd, (Format-Number $r.Messages), $r.Coverage)
                }
            }
        }
    }
}
catch {
    $exitCode = 1
    Write-Host ''
    Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Log "ERROR $($_.Exception.Message)"
    Write-Log "$($_.ScriptStackTrace)"
}
finally {
    if ($connection) { try { $connection.Dispose() } catch { } }
    try { Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null } catch { }
    $verdict = switch ($exitCode) { 0 { 'Done' } 2 { 'Done, but the source period is incomplete' } default { 'Failed' } }
    Write-Host ''
    Write-Host ("  {0} in {1}{2}" -f $verdict, (Format-Duration $script:Started.Elapsed), $(if ($script:LogFile) { "  ·  log $script:LogFile" })) -ForegroundColor $(if ($exitCode -eq 1) { 'Red' } elseif ($exitCode -eq 2 -or $script:Warnings.Count) { 'Yellow' } else { 'Green' })
    if ($work -and $exitCode -eq 1) { Write-Host "  Work files kept: $work" -ForegroundColor DarkGray }
    Write-Log "===== end: $verdict (exit $exitCode) in $(Format-Duration $script:Started.Elapsed)"
}
exit $exitCode
