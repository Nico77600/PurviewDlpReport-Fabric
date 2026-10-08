---
title: Purview DLP Report for Microsoft Fabric
subtitle: User guide
version: 1.3.0
author: Nicolas Fabert
updated: 2026-10-08
---

# Purview DLP Report for Microsoft Fabric — User guide

> For the person who **deploys the companion and runs it every day**. It tells you what to have ready, how to set everything up once, in order, then how to **publish every day**, **check that the publication is good**, **open the report** and **answer the questions of the readers**. The internals, the design choices and every setting are in the [developer guide](PurviewDlpReport-Fabric-Guide.md).

> [!IMPORTANT]
> Files downloaded from the Internet may be blocked by Windows and fail to run. Before using this project, unblock every file in the downloaded folder:
>
> ```powershell
> Get-ChildItem "C:\Chemin\Du\Dossier" -Recurse -File -Force | Unblock-File
> ```
>
> Replace the example path with the folder where you downloaded or extracted this project.
>
> The `Install-Module` commands in this documentation use `-Force`, so they also update or reinstall a module that is already installed. If an older version still conflicts, close every PowerShell window, open a new one (as administrator for `-Scope AllUsers`), run `Uninstall-Module <ModuleName> -AllVersions -Force`, then run the `Install-Module` command again.

```cards
terminal | One script | `Publish-DlpReportToFabric.ps1`, with four modes: `Publish`, `Deploy`, `Status`, `AgentInstructions`.
clock | One run a day | After the collection of Purview DLP Report. It replaces the four tables of the warehouse in one transaction.
chart | What people open | A Power BI report where each reader sees only their scope, and an agent in Microsoft Teams.
shield | Nothing to change | Purview DLP Report is not modified: the companion only reads its local database.
```

# Part I · Start here

<!-- icon: checklist -->
## 1. Prerequisites

| Item | What you need |
|---|---|
| Source | **Purview DLP Report 2.1 or later**, with its daily collection, **on the same server** |
| Console | **PowerShell 7.4 or later**, module **Az.Accounts** (`Install-Module Az.Accounts -Scope AllUsers -Force`) |
| Fabric | A **Fabric capacity** (F SKU) for the workspace. The agent needs a **paid F2 or larger**. Under F64, every reader needs **Power BI Pro** (included in Microsoft 365 E5) |
| Identities | A **publication application** (certificate, Graph `User.Read.All` and `GroupMember.Read.All`, workspace **Contributor**) and a **model reader application** (workspace **Viewer**, secret in a Fabric cloud connection) |
| Directory | A user attribute with the business line (`department` by default) and the `manager` attribute filled in |
| Groups | **Compliance**, **Viewers**, and one **correspondent group per business line** |
| Agent in Teams *(optional)* | Copilot Studio and a **Microsoft 365 Copilot** license for the person who builds the agent |
| Network | HTTPS to `login.microsoftonline.com`, `graph.microsoft.com`, `api.fabric.microsoft.com`, `api.powerbi.com`; **TCP 1433** to `*.datawarehouse.fabric.microsoft.com` |

> [!NOTE]
> Two applications, because a Fabric cloud connection accepts a **client secret** only, while the publication runs unattended with a **certificate**.

<!-- icon: wrench -->
## 2. One-time setup

Do these steps **in this order**. Each one is detailed in the developer guide, chapter [5](PurviewDlpReport-Fabric-Guide.md#5-setting-up-the-prerequisites) for the prerequisites and chapter [7](PurviewDlpReport-Fabric-Guide.md#7-deployment) for the deployment.

```steps
Capacity | Create the Fabric capacity in the Azure portal. **F2** is enough for the report; an **F8** was comfortable for the agent on 350,000 messages. You can pause it when nobody uses it, and resume it before the publication.
Tenant settings | Fabric admin portal: *Users can create Fabric items*, *Service principals can call Fabric public APIs* (for the group of the two applications), *Users can use Copilot and other features powered by Azure OpenAI*. Changes can take up to one hour.
Workspace and warehouse | A workspace on that capacity, then **New item > Warehouse**. Note the **workspace ID** and the **warehouse ID** from the URL of the warehouse.
Groups | `DLP Report - Compliance`, `DLP Report - Viewers`, `DLP Report - Fabric applications`, and one `DLP Report - Business line - <name>` per business line. The name after the prefix must be **the exact value of the business-line attribute**.
Publication application | Register it, upload the certificate created on the server, grant `User.Read.All` and `GroupMember.Read.All` with **admin consent**, add it to the group of applications, and give it **Contributor** on the workspace.
Model reader application | Register it with a **client secret**, add it to the group of applications, give it **Viewer** on the workspace, then create the Fabric **cloud connection** (SQL Server, the SQL endpoint of the warehouse, the warehouse ID as database, service principal, single sign-on off). Note the **connection ID** and add the publication application as **User** of the connection.
Server | Install **Az.Accounts**, copy the `package` folder of the repository (or the extracted release zip) next to Purview DLP Report, and unblock the files. Create the certificate **with the account that will run the scheduled task**.
Configuration | Fill in `config\PurviewDlpReport-Fabric.config.psd1` — chapter 6.
First publication | `.\Publish-DlpReportToFabric.ps1` creates the four tables and loads them. The semantic model does not exist yet: the script says so.
Deployment | `.\Publish-DlpReportToFabric.ps1 -Mode Deploy` writes the semantic model, its row-level security, the report, and the data agent if `Fabric.DataAgentName` is set.
Roles and sharing | In the Power BI service, once: semantic model > **Security**, role `Compliance` to the compliance group and role `Scoped` to the viewers group; then share the report with both groups, read only. The script recalls which group goes in which role.
Scheduled task | Every day, after the collection of Purview DLP Report — chapter 3 below.
```

> [!CAUTION]
> **Do not give the readers a workspace role.** Even *Viewer* lets them query the warehouse directly, without row-level security. Readers get access **only** through the report (sharing or app) and the data agent (sharing).

**The settings you have to fill in**

| Setting | Default | What to put there |
|---|---|---|
| `Source.ToolPath` | `C:\Scripts\PurviewDlpReport` | Folder of `Invoke-PurviewDlpReport.ps1` |
| `Source.ConfigPath` | *(empty)* | Configuration of Purview DLP Report; empty = its default file |
| `Source.HistoryDays` | `90` | Days published, yesterday included. At most the retention of the database |
| `Authentication.Mode` | `Certificate` | `Certificate` for the scheduled task, `Interactive` to sign in in the browser for a test |
| `Authentication.TenantId` / `ApplicationId` / `CertificateThumbprint` | — | The publication application |
| `Fabric.WorkspaceId` / `WarehouseId` | — | The two GUIDs of the URL of the warehouse |
| `Fabric.SemanticModelName` / `ReportName` | `Purview DLP Report` | Names of the items created by `-Mode Deploy` |
| `Fabric.DataAgentName` | *(empty)* | Name of the Fabric data agent; empty = no agent |
| `Fabric.ConnectionId` | *(empty)* | The cloud connection. **Empty = single sign-on**: readers would need access to the warehouse |
| `Directory.BusinessLineAttribute` | `department` | The attribute that holds the business line |
| `Access.ComplianceGroups` / `ViewerGroups` | — | Group names or IDs |
| `Access.BusinessLineGroupPrefix` | — | For example `DLP Report - Business line - `; the rest of the name is the business line |
| `Local.WorkPath` / `LogPath` / `LogRetentionDays` | `.\work` / `.\logs` / `30` | Temporary files, daily log and how long it is kept |

> [!NOTE]
> Relative paths are relative to the folder of `Publish-DlpReportToFabric.ps1`. Run the commands of this guide from that folder — the `package` folder of the repository or the folder where you extracted the release.

# Part II · Everyday use

<!-- icon: clock -->
## 3. Publish every day

One command, nothing else:

```powershell
.\Publish-DlpReportToFabric.ps1
```

It exports the period from Purview DLP Report with `-NoCollect` (local database only), reads the directory and the groups, **replaces the four tables in one transaction**, then refreshes the semantic model. Readers keep seeing the previous publication until the new one is complete.

Schedule it **after the collection of Purview DLP Report** — for example at 06:30 if the collection runs at 06:00. The task runs `pwsh.exe` with `-NoProfile -NonInteractive -File .\Publish-DlpReportToFabric.ps1`, with the folder of the companion as working directory and the service account that owns the certificate. The full `Register-ScheduledTask` command is in the developer guide, [chapter 8](PurviewDlpReport-Fabric-Guide.md#8-daily-publication).

| Step of the run | Duration on the demonstration data set |
|---|---|
| Export from Purview DLP Report | 7 to 16 s |
| Directory (Microsoft Graph) | 38 to 42 s |
| Preparing the tables | 4 s |
| Warehouse, 4 tables in one transaction | 34 to 45 s |
| Refresh of the semantic model | 9 s |
| **Total** | **1 min 30 s to 2 min 06 s** |

> [!NOTE]
> Measured on 350,514 messages, 1,600 senders and 11,679 directory users. At 30,000 to 50,000 messages a day and a directory of about 100,000 users, expect **15 to 20 minutes**. Reduce `Source.HistoryDays` if needed.

Two options are useful now and then:

| Option | What it does |
|---|---|
| `-HistoryDays <n>` | Publishes another number of days for this run only |
| `-KeepWorkFiles` | Keeps the intermediate CSV files in the work folder, to look at them |

<!-- icon: check -->
## 4. Check that the publication is good

```powershell
.\Publish-DlpReportToFabric.ps1 -Mode Status
```

It shows the warehouse and its SQL endpoint, the row count of each table, the semantic model, and the **last publication** with its period, its number of messages and its coverage. It changes nothing.

| Exit code | Meaning | What to do |
|---|---|---|
| `0` | Published; the source period is complete | Nothing |
| `2` | Published, but the database of Purview DLP Report does **not cover the whole period** | Check the daily collection of Purview DLP Report (`-Mode Status` of that tool) |
| `1` | Failure — **nothing changed** in the warehouse, the transaction is rolled back | Read the log, then chapter 8 below |

The end of each run prints the verdict, the duration and the path of the log. Logs are written in `logs\` as `PurviewDlpReport-Fabric_<date>.log`, one a day, kept `Local.LogRetentionDays` days (30 by default). The work folder is emptied after a success and **kept after a failure**, with `source.log` and `source.err.log` from Purview DLP Report.

The run also prints the counts worth a look: unique messages, senders **found** in the directory, senders **not found**, senders **with a business line** and **with a manager**, correspondents and business lines. The messages of senders not found in the directory are visible to the compliance team only.

<!-- icon: chart -->
## 5. Read the report

Four pages, with the same filters on the left of each one: date, business line, entity, site, manager N+2, manager, sender.

| Page | What it shows |
|---|---|
| **Overview** | Four tiles (matching messages, active senders, average recipients, largest audience), the recipient-count strip (26–30, 31–40, 41–60, 61+), messages by business line and per day, top 10 senders and top 10 managers |
| **Messages** | One row per message, newest first |
| **Hierarchy** | Business line › manager N+2 › manager › sender |
| **About** | What the reader sees, where the data comes from, the last publication and its coverage |

![Overview page, as seen by the compliance team](images/report-overview.png)

**Who sees what** — the report filters itself for each reader:

| Reader | Sees | Driven by |
|---|---|---|
| Compliance team | **Every message**, including the senders not found in the directory | Group in the role `Compliance` |
| Business-line correspondent | Every message of **their business lines** | Group `DLP Report - Business line - <name>` |
| Manager, director | The messages of **the people who report to them, directly or not** | `manager` attribute in Entra ID |
| Employee | **Their own messages** | User principal name |

A reader can combine several of these scopes: they add up. Someone in none of them sees nothing.

> [!TIP]
> To show the report of someone else without signing in as them: semantic model > **Security** > role `Scoped` > **Test as role** > *Now viewing as* that person. Readers can also **subscribe** to the report and receive their own view by e-mail.

<!-- icon: chat -->
## 6. Answer questions in Teams

If you deployed the agents, readers ask in **French or English** in Microsoft Teams — *who sends the most in Finance?* — and the answer is computed **with their own identity**, so they see exactly what their report shows.

![A question in French in Microsoft Teams](images/teams-team-lead-french.png)

```powershell
.\Publish-DlpReportToFabric.ps1 -Mode AgentInstructions
```

This writes `agent-instructions.txt`, `agent-publish-description.txt`, `copilot-studio-instructions.txt`, `copilot-studio-tool-description.txt` and `copilot-studio-language-topic.yaml` to the work folder: the texts to paste into the Fabric data agent and into the Copilot Studio agent. Use it the first time ([chapters 11 and 12](PurviewDlpReport-Fabric-Guide.md#11-questions-in-plain-language--the-fabric-data-agent)) and after an update of the companion that changes the answer format.

> [!NOTE]
> `-Mode Deploy` **never changes a data agent that already exists**, so that its publication is kept. New texts are pasted by hand, then the agent is published again.

<!-- icon: people -->
## 7. Keep the audiences right

Nothing to change in the report: everything follows the directory and the groups.

| Need | What to do | Effective |
|---|---|---|
| New correspondent for a business line | Add the person to `DLP Report - Business line - <name>` and to the viewers group | Next publication |
| New business line | Create the group with the exact attribute value after the prefix | Next publication |
| A manager changes, a person moves | Change the directory (`manager`, business-line attribute) | Next publication |
| Compliance team | Membership of the compliance group | Immediately |
| Everyone may open the report | Viewers group, for example a dynamic group of all employees | Immediately |

> [!WARNING]
> **The directory is the reference.** A missing manager or business line in Entra ID means a message that only the compliance team — and the managers above, if any — can see. The log of each publication gives the counts; the query of [chapter 10](PurviewDlpReport-Fabric-Guide.md#10-managing-the-audiences) lists the senders without business line or manager.

# Part III · Troubleshoot

<!-- icon: lifebuoy -->
## 8. Common situations

| Symptom | Cause | What to do |
|---|---|---|
| `Purview DLP Report failed (exit code 1)` | Configuration or database of the source tool | Open `work\<date>\source.log`, kept after a failure |
| `Connection to the warehouse … failed` | TCP 1433 blocked, or the application has no workspace role | Open `*.datawarehouse.fabric.microsoft.com:1433`; give the publication application **Contributor** |
| `The table dbo.<t> … does not have the expected columns` | Table created by another version | `DROP TABLE dbo.<t>` in the warehouse, then publish again |
| Exit code `2` | The database of Purview DLP Report does not cover the period | Check its daily collection with its own `-Mode Status` |
| Report: *QueryUserError — a connection could not be made to the data source* | The model is not bound to a connection with a fixed identity | Fill in `Fabric.ConnectionId`, check the connection (service principal, single sign-on off), then `-Mode Deploy` |
| Report: *QueryUserError* just after `-Mode Deploy` | The first queries while the model loads its columns | Wait one or two minutes and reload the page |
| Reader: *You don't have access* / `RLSNotAuthorizedForModel` | Not in a role, or report not shared | Put the groups in the roles (Security), share the report with them |
| A sender without business line or manager | Directory attributes empty | Fix Entra ID; effective at the next publication |
| The data agent answers with a bare table | Agent created by an older version, which `-Mode Deploy` never changes | `-Mode AgentInstructions`, paste the text into *Agent instructions*, publish again |
| Teams: *the data cannot be reached right now* | Capacity paused or throttled, or the reader cannot read the agent or the model | Resume or scale the capacity; share the data agent and the report with their group |
| Teams: a sign-in card, or *connection no longer valid* | First question, or new publication of the Copilot Studio agent | **Allow**, then ask again; if the conversation stays in error, start a new one |
| Teams: every reader sees the same figures | The data agent tool uses *Agent author authentication* | Set **User authentication** on the tool, then publish again |
| Teams: an English question gets a French answer | No secondary language or no language topic | Add English and the language topic to the Copilot Studio agent |

The full list, with the rarer cases, is in [Annex A](PurviewDlpReport-Fabric-Guide.md#annex-a--troubleshooting) of the developer guide.

> [!IMPORTANT]
> The secret of the model reader application **expires** (6 to 24 months). Before it expires: new secret in Entra ID, then **Manage connections and gateways > connection > Edit credentials**. Nothing else changes.

**Updating the companion** — replace the files except `config\`, run `Invoke-Pester -Path .\tests`, then `-Mode Deploy`. If the answer format of the agents changed, run `-Mode AgentInstructions` and paste the new texts.
