// =============================================================================
// Project Critical Orbit — per-squadron lab environment
//
// Deploys a single squadron's isolated lab stack into THIS resource group:
//   Storage · Key Vault · Azure AI Services (Foundry resource) · model
//   deployments (chat + embeddings) · Azure AI Search · Foundry project
//
// Authentication is keyless end-to-end: every participant listed in
// principalObjectIds receives data-plane RBAC role assignments; no keys or
// secrets are emitted as outputs or written anywhere.
//
// Scope: resource group. Deploy with:
//   az deployment group create -g rg-corbit-sq<NN> -f main.bicep \
//     --parameters teamNumber=<N> principalObjectIds='["<oid>", ...]'
//
// Verified against Microsoft Learn ARM/Bicep reference on 2026-09-30.
// Re-verify API versions/model versions before each delivery — see README
// "Verified versions" table.
// =============================================================================

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Squadron number (1-99). Determines the two-digit team id used in all resource names.')
@minValue(1)
@maxValue(99)
param teamNumber int

@description('Azure region for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Object IDs (Entra users) that receive data-plane RBAC roles — typically the deploying user plus all squadron members. Resolved from e-mail addresses by setup-squadron.sh.')
param principalObjectIds array = []

@description('Optional seed that perturbs the deterministic name hash. Only set this when a globally-unique name collided and you are retrying.')
param nameSeed string = ''

@description('Chat model for the Foundry deployment. Must be multimodal-capable (Day 2 analyses an image).')
param chatModelName string = 'gpt-4.1'

@description('Chat model version. Verify with `az cognitiveservices account list-models` in the target region.')
param chatModelVersion string = '2025-04-14'

@description('Chat model capacity in thousands of tokens-per-minute (GlobalStandard).')
@minValue(1)
param chatModelCapacityK int = 20

@description('Embedding model for vector search ingestion.')
param embeddingModelName string = 'text-embedding-3-large'

@description('Embedding model version.')
param embeddingModelVersion string = '1'

@description('Embedding model capacity in thousands of tokens-per-minute (GlobalStandard).')
@minValue(1)
param embeddingModelCapacityK int = 20

@description('AI Search SKU. Basic is the default (semantic ranker standard plan requires Basic+; the free plan works on all tiers).')
@allowed(['free', 'basic', 'standard'])
param searchSku string = 'basic'

@description('Semantic ranker billing plan. "free" = monthly free allowance; "standard" = pay-as-you-go (Basic+ only).')
@allowed(['disabled', 'free', 'standard'])
param semanticSearchPlan string = 'free'

// ---------------------------------------------------------------------------
// Naming — deterministic per squadron
// ---------------------------------------------------------------------------
// uniqueString() is deterministic per input and reduces — but does NOT
// guarantee — global DNS uniqueness. setup-squadron.sh runs a name
// availability preflight; if a collision is hit, re-run with --name-seed.

var teamId = padLeft('${teamNumber}', 2, '0')
var hashSeed = empty(nameSeed) ? resourceGroup().id : '${resourceGroup().id}|${nameSeed}'
var hash = substring(uniqueString(hashSeed), 0, 6)

var storageName = take('stcorbit${teamId}${hash}', 24) // 3-24 chars, lowercase alnum
var keyVaultName = take('kv-corbit-${teamId}-${hash}', 24) // 3-24 chars, starts with letter
var aiServicesName = 'ais-corbit-${teamId}-${hash}' // 2-64 chars, alnum + hyphen
var searchName = 'srch-corbit-${teamId}-${hash}' // 2-60 chars, lowercase alnum + hyphen
var projectName = 'prj-corbit-${teamId}'
var containerName = 'lab-data'

var tags = {
  bootcamp: 'critical-orbit'
  squadron: teamId
}

// ---------------------------------------------------------------------------
// RBAC — built-in role definition IDs (well-known GUIDs; re-verify before use)
// ---------------------------------------------------------------------------

var roleIds = {
  cognitiveServicesOpenAIUser: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
  cognitiveServicesUser: 'a97b65f3-01c7-47bc-a750-80ecdd0f89d6'
  searchServiceContributor: '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
  searchIndexDataContributor: '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
  storageBlobDataContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  keyVaultSecretsOfficer: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
}

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

resource storage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: true // control-plane convenience; data plane uses Entra
    networkAcls: {
      defaultAction: 'Allow' // lab scope: public network, Entra-gated data plane
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: storage
  name: 'default'
}

resource labDataContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  parent: blobService
  name: containerName
  properties: { publicAccess: 'None' }
}

// ---------------------------------------------------------------------------
// Key Vault — RBAC-mode vault. Soft delete intentionally LEFT ENABLED
// (Azure default); never disable it for redeploy convenience.
// ---------------------------------------------------------------------------

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    enabledForDeployment: false
    enabledForTemplateDeployment: false
    enabledForDiskEncryption: false
    publicNetworkAccess: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// Azure AI Services (Foundry resource) — kind AIServices, S0 is the only SKU.
// allowProjectManagement enables Foundry projects as child resources.
// disableLocalAuth=true enforces Entra-only data-plane auth (no API keys).
// ---------------------------------------------------------------------------

resource aiServices 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: aiServicesName
  location: location
  tags: tags
  kind: 'AIServices'
  sku: { name: 'S0' }
  identity: { type: 'SystemAssigned' }
  properties: {
    allowProjectManagement: true
    customSubDomainName: aiServicesName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    networkAcls: { defaultAction: 'Allow' }
  }
}

// Model deployments — GlobalStandard = pay-per-token, highest quota headroom.
// Model names/versions are parameters: verify availability in the target
// region (`az cognitiveservices account list-models`) before deployment.

resource chatDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: aiServices
  name: chatModelName
  sku: { name: 'GlobalStandard', capacity: chatModelCapacityK }
  properties: {
    model: {
      format: 'OpenAI'
      name: chatModelName
      version: chatModelVersion
    }
  }
}

resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: aiServices
  name: embeddingModelName
  dependsOn: [chatDeployment] // serialize deployment creation
  sku: { name: 'GlobalStandard', capacity: embeddingModelCapacityK }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingModelName
      version: embeddingModelVersion
    }
  }
}

// ---------------------------------------------------------------------------
// Azure AI Search — Basic tier (1 replica / 1 partition).
// semanticSearch 'free': monthly free allowance at no charge; switch to
// 'standard' (Basic+) if squadrons exhaust it — cost note in README.
// disableLocalAuth=true: Entra-only data plane.
// ---------------------------------------------------------------------------

resource search 'Microsoft.Search/searchServices@2025-05-01' = {
  name: searchName
  location: location
  tags: tags
  sku: { name: searchSku }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    semanticSearch: semanticSearchPlan
    disableLocalAuth: true
    publicNetworkAccess: 'enabled'
    networkRuleSet: { bypass: 'None' }
  }
}

// ---------------------------------------------------------------------------
// Foundry project (child resource of the AI Services account)
// ---------------------------------------------------------------------------

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-09-01' = {
  parent: aiServices
  name: projectName
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    displayName: 'Critical Orbit — Squadron ${teamId}'
    description: 'Project Critical Orbit bootcamp lab project (squadron ${teamId})'
  }
}

// ---------------------------------------------------------------------------
// RBAC role assignments — one set per principal, scoped to each resource.
// Deployer + squadron members get identical data-plane access.
// ---------------------------------------------------------------------------

resource raStorageBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for pid in principalObjectIds: {
    name: guid(storage.id, roleIds.storageBlobDataContributor, pid)
    scope: storage
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.storageBlobDataContributor)
      principalId: pid
      principalType: 'User'
    }
  }
]

resource raKeyVault 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for pid in principalObjectIds: {
    name: guid(keyVault.id, roleIds.keyVaultSecretsOfficer, pid)
    scope: keyVault
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.keyVaultSecretsOfficer)
      principalId: pid
      principalType: 'User'
    }
  }
]

resource raAiOpenAI 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for pid in principalObjectIds: {
    name: guid(aiServices.id, roleIds.cognitiveServicesOpenAIUser, pid)
    scope: aiServices
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.cognitiveServicesOpenAIUser)
      principalId: pid
      principalType: 'User'
    }
  }
]

resource raAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for pid in principalObjectIds: {
    name: guid(aiServices.id, roleIds.cognitiveServicesUser, pid)
    scope: aiServices
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.cognitiveServicesUser)
      principalId: pid
      principalType: 'User'
    }
  }
]

resource raSearchService 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for pid in principalObjectIds: {
    name: guid(search.id, roleIds.searchServiceContributor, pid)
    scope: search
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.searchServiceContributor)
      principalId: pid
      principalType: 'User'
    }
  }
]

resource raSearchIndex 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for pid in principalObjectIds: {
    name: guid(search.id, roleIds.searchIndexDataContributor, pid)
    scope: search
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.searchIndexDataContributor)
      principalId: pid
      principalType: 'User'
    }
  }
]

// ---------------------------------------------------------------------------
// Outputs — identifiers and endpoints ONLY. Never output keys/secrets.
// ---------------------------------------------------------------------------

output teamId string = teamId
output resourceGroupName string = resourceGroup().name

output aiServicesEndpoint string = aiServices.properties.endpoint
output aiServicesName string = aiServices.name

// Foundry project endpoint (verified format; see README "Verified versions").
output foundryProjectEndpoint string = 'https://${aiServices.name}.services.ai.azure.com/api/projects/${project.name}'
output foundryProjectName string = project.name

output searchEndpoint string = 'https://${search.name}.search.windows.net'
output searchName string = search.name

output storageAccountName string = storage.name
output storageContainerName string = containerName
output keyVaultName string = keyVault.name

output chatModelDeployment string = chatDeployment.name
output embeddingModelDeployment string = embeddingDeployment.name
