// Phase 6: Container Apps environment (in the VNet) and the Journal API app.
//
// Deployed by infra/06-app.sh. No secret values pass through this template:
//   - DATABASE_URL and OPENAI_API_KEY are Key Vault references, which Container
//     Apps resolves at runtime with the app's managed identity (and refreshes
//     every 30 minutes, so rotating a secret needs no redeploy)
//   - the image is pulled with the same identity (AcrPull), no registry password
//   - the Log Analytics key is read inside the deployment by listKeys(); it
//     never reaches the shell or the deployment's parameters

targetScope = 'resourceGroup'

param location string = resourceGroup().location
param tags object = {}

param environmentName string
param appName string

@description('Resource ID of snet-app, delegated to Microsoft.App/environments.')
param infrastructureSubnetId string

param logAnalyticsWorkspaceName string

@description('Resource ID of the user-assigned identity with AcrPull and Key Vault Secrets User.')
param identityId string

@description('e.g. myregistry.azurecr.io')
param registryServer string

@description('Full image reference, e.g. myregistry.azurecr.io/journal-api:<tag>')
param image string

@description('Vault URI with trailing slash, e.g. https://myvault.vault.azure.net/')
param keyVaultUri string

param databaseUrlSecretName string
param openAiKeySecretName string

@description('Responses API-compatible v1 endpoint (not secret).')
param openAiBaseUrl string

@description('Model or deployment name (not secret).')
param openAiModel string

@description('vCPU per replica, as a string because Bicep has no decimals (0.25, 0.5, ...).')
param cpu string = '0.25'
param memory string = '0.5Gi'

@minValue(1)
param minReplicas int = 1

@maxValue(10)
param maxReplicas int = 3

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource environment 'Microsoft.App/managedEnvironments@2025-07-01' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    // Workload profiles environment, Consumption profile only: pay per use,
    // no dedicated-plan charge, and app replicas get IPs in snet-app, which
    // the database NSG allows on 5432.
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    vnetConfiguration: {
      infrastructureSubnetId: infrastructureSubnetId
      // External: the ingress gets a public IP. Requirement #1.
      internal: false
    }
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
    zoneRedundant: false
  }
}

resource app 'Microsoft.App/containerApps@2025-07-01' = {
  name: appName
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    environmentId: environment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        // Requirement #1: public HTTPS on the environment's default domain,
        // with a Microsoft-managed, publicly trusted certificate. Plain HTTP
        // is redirected to HTTPS.
        external: true
        targetPort: 8000
        transport: 'auto'
        allowInsecure: false
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: [
        {
          server: registryServer
          identity: identityId
        }
      ]
      // Requirement #3: references only. Versionless URLs track the latest
      // secret version.
      secrets: [
        {
          name: 'database-url'
          keyVaultUrl: '${keyVaultUri}secrets/${databaseUrlSecretName}'
          identity: identityId
        }
        {
          name: 'openai-api-key'
          keyVaultUrl: '${keyVaultUri}secrets/${openAiKeySecretName}'
          identity: identityId
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'api'
          image: image
          resources: {
            cpu: json(cpu)
            memory: memory
          }
          env: [
            { name: 'DATABASE_URL', secretRef: 'database-url' }
            { name: 'OPENAI_API_KEY', secretRef: 'openai-api-key' }
            { name: 'OPENAI_BASE_URL', value: openAiBaseUrl }
            { name: 'OPENAI_MODEL', value: openAiModel }
          ]
          probes: [
            // The API answers /docs only after its startup (which opens the
            // database pool) has finished, so this also proves the database
            // connection before traffic is sent.
            {
              type: 'Startup'
              httpGet: { path: '/docs', port: 8000 }
              periodSeconds: 3
              failureThreshold: 20
            }
            {
              type: 'Readiness'
              httpGet: { path: '/docs', port: 8000 }
              periodSeconds: 10
            }
            {
              type: 'Liveness'
              tcpSocket: { port: 8000 }
              periodSeconds: 15
            }
          ]
        }
      ]
      // Requirement #4: always at least one replica, so the API keeps running
      // with nobody signed in. Up to 3 under load. Each replica's pool opens up
      // to 10 database connections; 3 x 10 fits the B1ms server's limit.
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
        rules: [
          {
            name: 'http'
            http: {
              metadata: {
                concurrentRequests: '50'
              }
            }
          }
        ]
      }
    }
  }
}

output fqdn string = app.properties.configuration.ingress.fqdn
output latestRevision string = app.properties.latestRevisionName
output outboundIps array = app.properties.outboundIpAddresses
