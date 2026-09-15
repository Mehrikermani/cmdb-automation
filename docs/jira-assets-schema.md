# Jira Assets CMDB model

This project uses Jira Service Management Assets as the CMDB. Assets is organized as a hierarchy of **object schemas → object types → objects → attributes**. Atlassian describes an object schema as a collection of related information, while an object type defines the common shape of similar objects. citeturn0search0turn0search2

## 1. Schema

A schema is the top-level CMDB container. In the production environment, the synchronization uses a schema ID configured as `$SchemaId`.

The schema ID is **not** the switch itself. It identifies the Assets data model in which the switch object type lives.

Conceptually:

```text
Jira Assets workspace
└── IT Assets schema
    └── Hardware Assets (parent)
        └── Switches (object type)
            ├── Switch object 1
            ├── Switch object 2
            └── Switch object N
```

The portfolio version deliberately uses `<assets-schema-id>` instead of publishing an environment-specific ID.

## 2. Object type

`$SwitchObjectTypeId` identifies the **Switches object type** inside the schema.

This value is critical because the create payload contains:

```json
{
  "objectTypeId": "<switch-object-type-id>",
  "attributes": []
}
```

The object type determines which attributes are valid for the object. Atlassian's Assets API requires `objectTypeId` when creating an object. citeturn0search1

## 3. Attributes

The `$Attr` PowerShell hashtable is the mapping between the CMDB model and the API payload.

| Code variable | Production role | Source |
|---|---|---|
| `Name` | Assets object/display name | Meraki device name or model + serial |
| `SerialNumber` | Stable device identity | Meraki `serial` |
| `Model` | Hardware model | Meraki `model` |
| `MacAddress` | Layer-2 identity | Meraki `mac` |
| `LanIp` | Local management address | Meraki `lanIp` |
| `Firmware` | Installed firmware | Meraki `firmware` |
| `NetworkId` | Meraki network identifier | Meraki `networkId` |
| `ProductType` | Device family | Meraki `productType` |
| `Source` | Data provenance | Constant: `Cisco Meraki` |
| `LastSynced` | CMDB synchronization timestamp | Runbook UTC time |
| `Floor` | Physical location | Parsed from device name |
| `PublicIp` | Internet-facing address | Meraki status endpoint |
| `Office` | Office/location | Runbook configuration |
| `Area` | Rack/IDF/MDF area | Parsed from device name |
| `DeviceNumber` | Local device identifier | Parsed from device name |
| `MerakiDashboardUrl` | Source-system link | Meraki device URL |
| `SwitchStatus` | Operational state | Meraki status → CMDB status |
| `LastReportedAt` | Last Meraki telemetry timestamp | Meraki status endpoint |
| `MerakiNetworkName` | Human-readable network | Meraki network endpoint |

Assets attributes have their own system names/IDs and can hold text, IP addresses, statuses and object references depending on their configured type. citeturn0search3turn0search6

## 4. How an attribute ID is used

The code converts an attribute mapping into the Assets API structure through `Add-AssetAttribute`:

```powershell
@{
    objectTypeAttributeId = $AttributeId
    objectAttributeValues = @(
        @{ value = $stringValue }
    )
}
```

For example, conceptually:

```text
Meraki device.serial
       ↓
$Attr.SerialNumber
       ↓
objectTypeAttributeId
       ↓
Jira Assets Serial Number attribute
```

This means the script does **not** need to know the display name of the attribute at runtime. It sends the numeric Assets attribute identifier configured for that environment.

## 5. Why the serial number is the synchronization key

The script uses the Meraki serial number to determine whether the device already exists:

```text
Meraki serial
    ↓
Escape for AQL
    ↓
AQL: objectTypeId = Switches AND "Serial Number" = "..."
    ↓
Jira Assets
    ├── found → PUT existing object
    └── not found → POST new object
```

This makes the synchronization idempotent: running the same synchronization again does not create another switch when the serial number already exists.

Assets exposes a POST `/object/aql` endpoint for searching objects with AQL and POST `/object/create` and PUT `/object/{id}` for object creation/update. citeturn0search1

## 6. AQL and attribute names

The synchronization uses AQL to locate an existing switch. AQL references the Assets entity/system name, not the user-facing display name. Special characters must be escaped, which is why the script contains `Escape-AqlValue`. citeturn0search5

## 7. IDs versus names

There are several different identifiers in this design:

| Identifier | Meaning |
|---|---|
| Assets schema ID | Which CMDB schema contains the model |
| Switch object type ID | Which type of object is being synchronized |
| Attribute ID | Which field receives a value |
| Assets object ID | The individual switch object being updated |
| Meraki organization ID | Meraki tenant/organization context |
| Meraki network ID | The network/location from which devices are selected |
| Workspace ID | Jira Assets API workspace context |
| Serial number | Cross-system device identity used by the sync |

Keeping these concepts separate is important. A schema ID does not identify a switch; an attribute ID does not identify an object; and a Meraki network ID is not the same thing as a Jira Assets object type ID.
