# Purview DLP Report for Microsoft Fabric

Publishes the rows of Purview DLP Report to Microsoft Fabric so each business line, manager or employee sees only the messages that concern them in Power BI and through an agent in Microsoft Teams.

This folder contains everything needed to run the tool: Publish-DlpReportToFabric.ps1, the configuration, the report and agent definitions and the guides. Tests and build tools stay outside it, in the repository.

> [!IMPORTANT]
> Files downloaded from the Internet may be blocked by Windows. Unblock them once, from this folder:
>
> ```powershell
> Get-ChildItem . -Recurse -File | Unblock-File
> ```

## Requirements
- Purview DLP Report 2.1 or later, with its daily collection, on the same server.
- PowerShell 7.4 or later, with Az.Accounts.
- A Fabric capacity for the workspace; F2 or larger for the data agent.
- Publication and model reader applications with the documented permissions.
- Directory attributes, compliance/viewer groups and one correspondent group per business line.
- HTTPS to Microsoft Entra ID, Graph, Fabric and Power BI; TCP 1433 to the Fabric warehouse.

## Quick start
```powershell
notepad .\config\PurviewDlpReport-Fabric.config.psd1     # tenant, application, workspace, warehouse, connection, groups

.\Publish-DlpReportToFabric.ps1                          # first publication: creates and loads the four tables
.\Publish-DlpReportToFabric.ps1 -Mode Deploy             # semantic model, row-level security, report (and the data agent)
.\Publish-DlpReportToFabric.ps1 -Mode Status             # what is published
.\Publish-DlpReportToFabric.ps1 -Mode AgentInstructions  # texts to paste into the data agent and the Copilot Studio agent
```

## Content
| Item | Role |
|---|---|
| `config\` | Example configuration file. |
| `docs\` | User and developer guides in Markdown and HTML, with images. |
| `src\` | Report, semantic model, data agent and Copilot Studio definitions. |
| `Publish-DlpReportToFabric.ps1` | Entry script to run. |
| `LICENSE` | MIT license. |
| `README.md` | This package quick start. |

## Documentation
- [User guide](docs/PurviewDlpReport-Fabric-UserGuide.md) - also `docs/PurviewDlpReport-Fabric-UserGuide.html`, a single file to open locally
- [Developer guide](docs/PurviewDlpReport-Fabric-Guide.md) - also `docs/PurviewDlpReport-Fabric-Guide.html`

Project page, releases and change log: https://github.com/Nico77600/PurviewDlpReport-Fabric

License: [MIT](LICENSE).
