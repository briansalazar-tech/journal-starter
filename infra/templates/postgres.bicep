// Phase 3: Azure Database for PostgreSQL Flexible Server, private access only.
//
// Deployed by infra/03-database.sh, which passes the admin password as a Key
// Vault reference so its value never passes through the shell. @secure() keeps
// it out of deployment history and logs.
//
// "Private access" (VNet integration) gives the server only a private IP in the
// delegated subnet; it has no public endpoint at all. This is fixed at creation
// and can't later be switched to public access, or the reverse.

targetScope = 'resourceGroup'

@description('Globally unique server name; becomes <name>.postgres.database.azure.com.')
param serverName string

param location string = resourceGroup().location
param tags object = {}

@allowed(['16', '17', '18'])
param postgresVersion string = '17'

param skuName string = 'Standard_B1ms'

@allowed(['Burstable', 'GeneralPurpose', 'MemoryOptimized'])
param skuTier string = 'Burstable'

@description('Availability zone (1, 2 or 3), or empty to let Azure choose. Capacity for a SKU can differ by zone.')
@allowed(['', '1', '2', '3'])
param availabilityZone string = ''

@minValue(32)
param storageSizeGB int = 32

@minValue(7)
@maxValue(35)
param backupRetentionDays int = 7

@description('Password-auth server admin login name.')
param administratorLogin string

@secure()
@description('Server admin password (pass as a Key Vault reference).')
param administratorLoginPassword string

@description('Resource ID of the subnet delegated to Microsoft.DBforPostgreSQL/flexibleServers.')
param delegatedSubnetId string

@description('Resource ID of the <name>.private.postgres.database.azure.com zone linked to the VNet.')
param privateDnsZoneId string

param databaseName string = 'career_journal'

@description('Object ID of the Microsoft Entra principal to make database admin. Empty = no Entra admin.')
param entraAdminObjectId string = ''

@description('Display name / UPN of that principal; it becomes the PostgreSQL role name.')
param entraAdminPrincipalName string = ''

@allowed(['User', 'Group', 'ServicePrincipal'])
param entraAdminPrincipalType string = 'User'

var useEntraAdmin = !empty(entraAdminObjectId)

resource server 'Microsoft.DBforPostgreSQL/flexibleServers@2025-08-01' = {
  name: serverName
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: skuTier
  }
  properties: {
    version: postgresVersion
    availabilityZone: empty(availabilityZone) ? null : availabilityZone
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorLoginPassword
    authConfig: {
      // Password auth stays on for the app's least-privilege role (phase 4).
      passwordAuth: 'Enabled'
      activeDirectoryAuth: useEntraAdmin ? 'Enabled' : 'Disabled'
      tenantId: tenant().tenantId
    }
    storage: {
      storageSizeGB: storageSizeGB
      // Off for cost predictability; 32 GB is far more than journal entries need.
      autoGrow: 'Disabled'
    }
    backup: {
      // Requirement #4: automated daily backups plus point-in-time restore.
      backupRetentionDays: backupRetentionDays
      geoRedundantBackup: 'Disabled'
    }
    highAvailability: {
      mode: 'Disabled'
    }
    network: {
      // Requirement #2: no public endpoint; reachable only inside the VNet.
      delegatedSubnetResourceId: delegatedSubnetId
      privateDnsZoneArmResourceId: privateDnsZoneId
    }
    createMode: 'Default'
  }
}

resource entraAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2025-08-01' = if (useEntraAdmin) {
  parent: server
  name: useEntraAdmin ? entraAdminObjectId : 'unused'
  properties: {
    principalType: entraAdminPrincipalType
    principalName: entraAdminPrincipalName
    tenantId: tenant().tenantId
  }
}

resource database 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2025-08-01' = {
  parent: server
  name: databaseName
  properties: {
    charset: 'UTF8'
    collation: 'en_US.utf8'
  }
  // A server runs one management operation at a time; serialize the children.
  dependsOn: [
    entraAdmin
  ]
}

output serverName string = server.name
output fqdn string = server.properties.fullyQualifiedDomainName
output databaseName string = database.name
