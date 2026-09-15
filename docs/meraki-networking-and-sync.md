# Meraki networking and CMDB synchronization

## Overview

`Meraki-Jira-sync.ps1` treats Cisco Meraki Dashboard as the operational source of truth for network devices and Jira Assets as the CMDB destination.

```text
Cisco Meraki Dashboard
        │
        ├── Organizations
        │      └── Networks
        │             └── Devices
        │                    └── Status
        │
        ▼
Azure Automation Runbook
        │
        ├── Filter product type
        ├── Filter network
        ├── Parse naming convention
        ├── Map source fields → CMDB attributes
        └── Find by serial number
                  │
          ┌───────┴────────┐
          │                │
       exists           missing
          │                │
        PUT              POST
          │                │
          └───────┬────────┘
                  ▼
             Jira Assets
                  │
                  ▼
                 CMDB
```

## 1. Meraki organization

The Meraki organization ID identifies the Dashboard organization from which the Runbook retrieves networks, devices and statuses.

It is loaded from Key Vault rather than hard-coded as a secret value in the portfolio implementation.

## 2. Meraki network

The configured `$NetworkId` is the scope used for this first version. The script retrieves all organization networks and resolves the configured network to a human-readable `$NetworkName`.

The same network ID is then used when selecting devices:

```powershell
$_.productType -eq $ProductTypeFilter -and
$_.networkId -eq $NetworkId
```

For the original implementation this was a Berlin-only synchronization. The portfolio version makes the network and office configuration explicit so the same pattern can be extended to additional sites.

## 3. Device discovery

The Runbook retrieves the organization's devices and filters them by:

1. `productType` — for version 1 this is `switch`.
2. `networkId` — only devices belonging to the configured network.
3. `serial` — devices without a serial number are ignored because serial is the synchronization identity.

A test limit can then reduce the selected set before changes are applied.

## 4. Operational status

Meraki device metadata and operational status are retrieved separately.

The status endpoint is indexed by serial number:

```text
status.serial → statusBySerial[serial]
```

This allows the device loop to combine configuration data with operational telemetry without repeatedly searching the full status response.

The synchronization normalizes Meraki statuses into CMDB values:

| Meraki | Jira Assets |
|---|---|
| `online` | `Online` |
| `offline` | `Offline` |
| `alerting` | `Alerting` |
| `dormant` | `Dormant` |
| unknown/empty | `Unknown` |

The script also maps public IP and last-reported timestamp when available.

## 5. Network versus physical location

A Meraki network is not the same concept as a physical floor, rack or area.

The Runbook therefore keeps these dimensions separate:

```text
Meraki network
    → Network ID / Network Name

Office
    → Office

Physical naming convention
    → Floor
    → Area
    → Device Number
```

This is important for CMDB reporting. A network can represent a logical or site-level grouping, while floor/area information describes physical placement.

## 6. Naming convention parsing

The first implementation derives physical metadata from the Meraki device name.

Examples supported by the original pattern include:

```text
BER-F08-R01-SW01
BER-F07-IDF-SW02
BER-F08-RACK01-SW01
```

The parser identifies:

- `F08` → Floor
- `R01`, `IDF`, `MDF`, `RACK01` → Area
- `SW01`, `ASW01`, `CSW01`, etc. → Device Number

This is a pragmatic integration pattern: the source naming convention is transformed into structured CMDB attributes.

A future improvement would be to validate naming conventions and report devices whose names cannot be parsed instead of silently leaving location attributes empty.

## 7. Create/update decision

The synchronization is intentionally based on a stable hardware identifier rather than the device name.

```text
Serial number
     │
     ▼
Search Jira Assets with AQL
     │
     ├── Existing object
     │      └── PUT /object/{id}
     │
     └── No object
            └── POST /object/create
```

Changing a Meraki device name therefore does not create a duplicate CMDB object as long as the serial number remains the same.

## 8. Dry-run safety

Two controls are used during rollout:

### `TestLimit`

Limits the number of devices processed during testing.

```powershell
$TestLimit = 5
```

Set to `0` only when the synchronization is ready for the full scope.

### `ApplyChanges`

Controls whether the Runbook actually writes to Jira Assets.

```powershell
$ApplyChanges = $false
```

With changes disabled, the Runbook reports how many objects would be created or updated without changing the CMDB.

Recommended rollout:

```text
TestLimit = 5
ApplyChanges = false
        ↓
validate mappings
        ↓
validate AQL matching
        ↓
review proposed creates/updates
        ↓
ApplyChanges = true
        ↓
TestLimit = 0
```

## 9. Error isolation

Each device is processed inside its own `try/catch` block. A failure for one switch increments the failure counter but does not stop the complete synchronization loop.

This is important for a CMDB integration because one malformed device, API response or object should not prevent the remaining inventory from being synchronized.

## 10. Extending from switches to a full network CMDB

Version 1 deliberately starts with switches. The same architecture can be extended to:

```text
Network
├── Switches
├── Wireless Access Points
├── Security Appliances / Firewalls
├── Cellular Gateways
└── Other supported Meraki device types
```

The next architectural step is to separate common synchronization logic from device-specific mappings. For example:

```text
Meraki device
    ↓
Common identity / source metadata
    ↓
Device-type mapper
    ├── Switch mapper
    ├── Access Point mapper
    ├── Firewall mapper
    └── Gateway mapper
    ↓
Jira Assets object type
```

That makes the CMDB integration easier to maintain as the number of object types grows.
