#  Purview DLP Report for Microsoft Fabric - configuration
#  Publishes the messages collected by Purview DLP Report to a Fabric warehouse and a Power BI report
#  in which every business line, manager or employee sees only the messages that concern them.
#
#  Relative paths are relative to the folder of Publish-DlpReportToFabric.ps1.
#  Documentation: docs\PurviewDlpReport-Fabric-Guide.md
@{
    # ---- Purview DLP Report (source) -------------------------------------------------------------
    # The report tool is run with -NoCollect: it only reads its local database (no Microsoft 365 connection).
    Source = @{
        ToolPath    = 'C:\Scripts\PurviewDlpReport'   # folder that contains Invoke-PurviewDlpReport.ps1
        ConfigPath  = ''                              # tool configuration; empty = config\PurviewDlpReport.config.psd1 of the tool
        HistoryDays = 90                              # days published (yesterday included); at most the database retention
    }

    # ---- Sign-in -----------------------------------------------------------------------------------
    # Certificate : unattended (scheduled task) with a dedicated application and a certificate.
    # Interactive : an administrator signs in in the browser (first deployment, tests).
    Authentication = @{
        Mode                  = 'Certificate'
        TenantId              = ''                    # tenant ID (GUID)
        ApplicationId         = ''                    # Certificate mode: application (client) ID
        CertificateThumbprint = ''                    # Certificate mode: certificate in Cert:\CurrentUser\My or Cert:\LocalMachine\My
    }

    # ---- Microsoft Fabric --------------------------------------------------------------------------
    # The warehouse holds the tables (fixed schema, replaced in one transaction at each publication).
    # The semantic model reads them in Direct Lake; readers get no permission on the warehouse.
    Fabric = @{
        WorkspaceId       = ''                        # workspace ID (GUID), on a Fabric capacity
        WarehouseId       = ''                        # warehouse ID (GUID) in this workspace
        SemanticModelName = 'Purview DLP Report'
        ReportName        = 'Purview DLP Report'
        DataAgentName     = ''                        # Fabric data agent on the semantic model (paid capacity F2+); empty = none
        ConnectionId      = ''                        # cloud connection with a fixed identity (see the guide); empty = single sign-on
    }

    # ---- Directory (Microsoft Entra ID) --------------------------------------------------------------
    # Attribute that holds the business line of a user: department, companyName, officeLocation, jobTitle,
    # employeeOrgData.division, employeeOrgData.costCenter or onPremisesExtensionAttributes.extensionAttribute1..15
    Directory = @{
        BusinessLineAttribute = 'department'
        MaxManagerLevels      = 15                    # depth of the management chain
    }

    # ---- Audiences -----------------------------------------------------------------------------------
    # Compliance          : groups that see every message (RLS role 'Compliance'). The groups of the two roles are
    #                       assigned once in the Power BI service; -Mode Deploy checks them and recalls the assignment.
    # Viewers             : groups that may open the report and see what concerns them (RLS role 'Scoped'):
    #                       their own messages, the messages of the people who report to them (directly or not)
    #                       and the business lines for which they are correspondents.
    # BusinessLineGroups  : correspondents of a business line. Key = business line (value of the attribute
    #                       above), value = group object ID or display name.
    # BusinessLineGroupPrefix : alternative to the list: every group whose name starts with the prefix;
    #                       the rest of the name is the business line ('DLP Report - Business line - Sales' -> Sales).
    Access = @{
        ComplianceGroups        = @()
        ViewerGroups            = @()
        BusinessLineGroups      = @{}
        BusinessLineGroupPrefix = ''
    }

    # ---- Working files and log -----------------------------------------------------------------------
    Local = @{
        WorkPath         = '.\work'                   # temporary files, deleted after a successful publication
        LogPath          = '.\logs'
        LogRetentionDays = 30
    }
}
