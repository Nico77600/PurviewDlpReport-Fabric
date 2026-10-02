# Changelog — Purview DLP Report for Microsoft Fabric

All notable changes are listed here. Versions follow MAJOR.MINOR.PATCH.
Author: Nicolas Fabert.

## 1.3.0 — 2026-10-02

First public release.

### Added
- **Agent in Microsoft Teams with Copilot Studio** (guide, chapter 12): a Copilot Studio agent whose only tool is the Fabric data agent, with **user authentication**, so that every reader queries the data agent with their own identity and keeps the row-level security of the report. `-Mode AgentInstructions` now also writes its texts: `copilot-studio-instructions.txt` (route every question to the data agent, relay the answer as it is), `copilot-studio-tool-description.txt` and `copilot-studio-language-topic.yaml`.
- `src\copilot-studio\conversation-language.yaml`: a topic that sets the language of the conversation from the words of each message (Power Fx, no AI prompt), so that Copilot Studio does not translate the answers into its primary language.
- **Answers in French or English**: the data agent answers in the language of the question, with English labels and formats in English (*In short*, *Key points*, *Go further*, 42,076 · 32.0 · 12.5%); data values are never translated.
- Offline Pester tests (`tests\`): configuration, export, CSV and bulk load, directory, semantic model and row-level security, report, agent texts, repository consistency.
- `tools\New-DocumentationImages.ps1`: renders the README graphics from the guide (light and dark).

### Changed
- Answer format of the data agent made for a chat window: at most five columns, short headers, a bar of coloured squares with the share in the same cell (🟥🟥🟥⬜⬜ 12.0 %), shares written with one decimal.
- Guide rewritten as a step-by-step procedure: prerequisites and how to set them up (capacity, tenant settings, workspace, groups, the two applications, cloud connection, server), configuration, deployment, daily publication, data agent, Copilot Studio agent, tests with reference results, security model, troubleshooting, licensing.

### Fixed
- `-Mode Deploy` failed when it created the data agent: the definition sent to Fabric was never computed.
- A directory user without manager could shift the columns of the `directory_users` table (an empty value dropped from the row).

## 1.2.0 — 2026-10-01

### Added
- Report with the visual identity of the HTML report of Purview DLP Report: page backgrounds drawn as HTML/CSS (`tools\new_report_backgrounds.py`), `layout.json`, custom theme, transparent visuals, recipient-count strip with count and share per band.
- Structured answers of the data agent: title, key figures, ranking with medals, shares and bars, key points, scope line, follow-up questions, link to the report.
- `-Mode AgentInstructions`: writes the instructions and the publication description of the data agent, to apply them to an agent that is already published.

### Changed
- The data agent is created once, as a draft; its first publication is done by a person (Microsoft 365 registers the first publisher as its owner). `-Mode Deploy` never changes an existing agent.

## 1.1.0 — 2026-10-01

### Added
- Preparation of the semantic model for AI: descriptions, AI data schema with synonyms, AI instructions, example prompts.
- Fabric data agent on the semantic model (`Fabric.DataAgentName`), with the row-level security of the report.

## 1.0.0 — 2026-10-01

### Added
- Publication of the messages of Purview DLP Report (one row per Message ID) to a Fabric warehouse with the profile of each sender from Microsoft Entra ID, in one transaction.
- Direct Lake semantic model with row-level security (compliance team, business-line correspondents, management chain, own messages) bound to a fixed identity, and a Power BI report (PBIR).
- Unattended publication with a certificate; modes `Publish`, `Deploy` and `Status`.
