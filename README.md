# CMDB Automation — Intune + ABM → Jira Assets

PowerShell runbooks for syncing device and user data into Jira Service Management Assets.

## Scripts

### Daily-Full-Sync.ps1
Syncs all Intune-managed devices and Entra ID users into JSM Assets daily.
- Smart skip: only updates devices with missing or changed attributes
- Token auto-refresh for long runs
- Disabled users → PENDING RETURN
- Unassigned devices → IN STOCK
- Assigned devices → IN USE

### Retire-Devices.ps1
Detects devices removed from Intune and marks them RETIRED in JSM.
- Runs daily at 3:00 AM
- Compares Intune serial numbers against JSM IN USE devices
- Safe — only retires devices confirmed absent from Intune

### Daily-ABM-Sync.ps1
Syncs Apple Business Manager device enrollment data into JSM Assets.
- Filters devices purchased since January 2024
- New devices → IN STOCK
- Existing devices → updates ABM attributes only, never touches Asset Status
- Delta mode: only processes changed devices after first run

## Infrastructure

- Azure Automation Account: `Intune-Automation` (Resource Group: `Intune`)
- Key Vault: `kv-intune-assets-dev`
- Managed Identity: handles all authentication — no hardcoded credentials
- Schedules:
  - Daily-Full-Sync: 2:00 AM UTC daily
  - Retire-Devices: 3:00 AM UTC daily
  - Daily-ABM-Sync: 6:00 AM UTC daily

## Key Vault Secrets Required

| Secret name | Description |
|---|---|
| graph-tenant-id | Entra ID tenant ID |
| graph-client-id | App Registration client ID |
| graph-client-secret | App Registration secret |
| jira-email | JSM service account email |
| asset-jira-token | JSM API token |
| jira-workspace-id | JSM Assets workspace ID |
| abm-key-id | Apple Business Manager key ID |
| abm-client-id | ABM client ID |
| abm-private-key-b64 | ABM private key (base64 encoded) |
| abm-org-name | ABM organization name |

## JSM Schema

### IT Assets schema
- Hardware Assets (15) — abstract parent
  - Macbooks (56)
  - Windows (55)
  - Phones (16)
  - Switches (59)
  - Cameras (60)
  - Network (58)

### People schema
- Employee (141)
- Department (102)
- Role (103)

### Offices schema
- Locations (66) — countries
- Offices (61) — cities
