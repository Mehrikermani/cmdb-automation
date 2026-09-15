# CMDB Automation — Device Lifecycle & Network Asset Synchronization

An automation project for building and maintaining a Jira Service Management Assets CMDB from multiple infrastructure sources.

The project demonstrates how PowerShell runbooks can collect authoritative data from endpoint-management, identity, Apple Business Manager and network platforms, normalize that data, and create or update CMDB objects through APIs.

> **Portfolio note:** This repository contains sanitized reference implementations. Environment-specific credentials, tenant identifiers, workspace identifiers, internal URLs and production object IDs are intentionally replaced with placeholders where applicable.

## What this project solves

A CMDB becomes difficult to maintain when inventory is updated manually across several systems. This project automates the synchronization layer between source systems and Jira Assets.

```text
                 ┌─────────────────────┐
                 │ Microsoft Intune    │
                 └──────────┬──────────┘
                            │
                 ┌──────────▼──────────┐
                 │ Entra ID / Graph    │
                 └──────────┬──────────┘
                            │
┌────────────────┐          │          ┌────────────────────┐
│ Apple Business │──────────┼──────────│ Cisco Meraki       │
│ Manager        │          │          │ Dashboard          │
└───────┬────────┘          │          └─────────┬──────────┘
        │                   │                    │
        └───────────────────┼────────────────────┘
                            ▼
                 ┌─────────────────────┐
                 │ Azure Automation    │
                 │ PowerShell Runbooks │
                 └──────────┬──────────┘
                            │
                            ▼
                 ┌─────────────────────┐
                 │ Jira Assets / CMDB  │
                 └─────────────────────┘
```

## Current synchronization capabilities

### Endpoint & identity

**Daily-Full-Sync.ps1**

- Synchronizes Intune-managed devices and Entra ID user information into Jira Assets.
- Uses change-aware processing to avoid unnecessary updates.
- Handles lifecycle states such as assigned, unassigned and disabled users.
- Supports long-running synchronization through token refresh handling.

**Retire-Devices.ps1**

- Detects devices that are no longer present in the source inventory.
- Marks confirmed missing devices as retired instead of deleting CMDB history.
- Uses serial numbers as the device identity for comparison.

### Apple Business Manager

**Daily-ABM-Sync.ps1**

- Synchronizes Apple Business Manager enrollment information.
- Adds new devices to the CMDB.
- Updates ABM-specific information without unintentionally changing unrelated lifecycle state.
- Supports delta-style processing after the initial inventory load.

### Network CMDB — Meraki

**Meraki-Jira-sync.ps1**

The first version of the network synchronization focuses on Meraki switches.

- Loads credentials securely from Azure Key Vault.
- Retrieves Meraki networks, devices and operational status.
- Filters devices by product type and network.
- Maps Meraki data to a Jira Assets Switch object type.
- Parses device naming conventions into floor, area and device number.
- Uses serial number as the synchronization key.
- Creates missing CMDB objects.
- Updates existing objects.
- Imports offline/dormant devices because inventory presence is separate from operational status.
- Supports dry-run mode and a test limit before production changes are enabled.

The network design is documented in [`docs/meraki-networking-and-sync.md`](docs/meraki-networking-and-sync.md).

## Jira Assets CMDB model

The CMDB is modeled using Assets concepts:

```text
Object Schema
│
├── Hardware Assets
│   ├── Macbooks
│   ├── Windows
│   ├── Phones
│   ├── Switches
│   ├── Cameras
│   └── Network
│
├── People
│   ├── Employee
│   ├── Department
│   └── Role
│
└── Offices
    ├── Locations
    └── Offices
```

The repository documents how schema IDs, object type IDs, attribute IDs, object IDs, Meraki IDs and serial numbers differ and how they participate in the synchronization process.

See [`docs/jira-assets-schema.md`](docs/jira-assets-schema.md).

## Meraki → Jira Assets synchronization flow

```text
Meraki Organization
       │
       ▼
Networks ──────────────► resolve network name
       │
       ▼
Devices
       │
       ├── productType = switch
       ├── networkId = configured network
       └── serial exists
       │
       ▼
Device Statuses
       │
       └── indexed by serial
       │
       ▼
Normalize + map attributes
       │
       ▼
AQL lookup by Serial Number
       │
       ├── Existing → PUT
       └── Missing  → POST
       │
       ▼
Jira Assets CMDB
```

### Why serial number is the key

Device names can change. Serial numbers are a more stable hardware identity, so the synchronization searches Jira Assets using the serial number before deciding whether to create or update an object.

This makes the synchronization idempotent and prevents duplicate CMDB records during repeated runs.

## Safety controls

The Meraki synchronization uses two rollout controls:

```powershell
$ApplyChanges = $false
$TestLimit = 5
```

Recommended deployment sequence:

1. Run against a small test set.
2. Keep `ApplyChanges = $false`.
3. Review the proposed create/update counts and mappings.
4. Validate AQL matching by serial number.
5. Enable changes.
6. Remove the test limit only after validation.

The same principle should be applied to the other runbooks: **discover → validate → preview → apply**.

## Security architecture

Secrets are designed to come from Azure Key Vault rather than being embedded in the scripts.

Typical secret categories include:

| Secret | Purpose |
|---|---|
| Meraki API key | Meraki Dashboard API authentication |
| Meraki organization ID | Source organization context |
| Jira service identity | Jira Assets API authentication |
| Jira API token | API authentication |
| Jira Assets workspace ID | Assets API routing |
| Graph / endpoint credentials | Microsoft source integrations |
| ABM credentials | Apple Business Manager integration |

Production values are intentionally not published in this repository.

## Repository structure

```text
cmdb-automation/
├── README.md
├── scripts/
│   ├── Daily-Full-Sync.ps1
│   ├── Retire-Devices.ps1
│   ├── Daily-ABM-Sync.ps1
│   └── Meraki-Jira-sync.ps1
└── docs/
    ├── jira-assets-schema.md
    └── meraki-networking-and-sync.md
```

## Engineering patterns demonstrated

- PowerShell automation and reusable functions
- REST API integration
- Jira Assets REST API
- Assets Query Language (AQL)
- Cisco Meraki Dashboard API
- Microsoft Graph / endpoint-management integration
- Azure Automation
- Azure Key Vault secret management
- Idempotent synchronization
- Source-to-CMDB field mapping
- Device lifecycle management
- Dry-run / controlled rollout patterns
- Error isolation and operational logging
- CMDB data modeling

## Roadmap — full network CMDB

The switch synchronization is intentionally the first version of the network CMDB integration.

Planned expansion:

- Switches
- Wireless access points
- Security appliances / firewalls
- Cellular gateways
- Network/site objects
- Relationships between network devices and locations
- Cross-source reconciliation
- Sync metrics and operational reporting
- Configuration-driven object-type mappings
- Stronger validation of naming conventions and CMDB uniqueness

The long-term architecture is to make device-type mappings reusable rather than creating a separate copy of the synchronization logic for every Meraki product family.

## Portfolio context

This project demonstrates a practical automation problem: keeping a CMDB synchronized with systems that are authoritative for different parts of an organization's infrastructure.

The important engineering problem is not simply moving API data. It is maintaining **identity, consistency, lifecycle state, error handling, security and repeatability** across systems.
