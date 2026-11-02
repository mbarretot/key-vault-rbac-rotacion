#!/usr/bin/env bash
# Reference commands for the lab, in order.
# Run them step by step in Azure Cloud Shell (Bash), not as a single script.

RG="rg-key-vault-rbac-rotacion"
LOCATION="centralus"
SUFFIX="$RANDOM"
KV="kv-rbac-rot-$SUFFIX"          # vault names are global
LAW="log-key-vault-rbac-rotacion"
PLAN="asp-key-vault-rbac-rotacion"
APP="kv-rbac-rot-$SUFFIX"         # must be unique in *.azurewebsites.net
SECRET="pasarela-pagos-api-key"

# 1. Resource group, workspace and vault (RBAC, purge protection, 7-day retention)
az group create -n "$RG" -l "$LOCATION"
az monitor log-analytics workspace create -g "$RG" -n "$LAW" -l "$LOCATION"
az keyvault create -g "$RG" -n "$KV" -l "$LOCATION" --sku standard \
  --enable-rbac-authorization true --enable-purge-protection true --retention-days 7
KV_ID=$(az keyvault show -n "$KV" --query id -o tsv)

# 2. Data-plane role for the signed-in user (Owner alone cannot read or write secrets)
ME=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --role "Key Vault Secrets Officer" \
  --assignee-object-id "$ME" --assignee-principal-type User --scope "$KV_ID"

# 3. Audit logs to Log Analytics (resource-specific table AZKVAuditLogs)
LAW_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query id -o tsv)
az monitor diagnostic-settings create -n kv-audit --resource "$KV_ID" --workspace "$LAW_ID" \
  --export-to-resource-specific true --logs '[{"category":"AuditEvent","enabled":true}]'

# 4. The secret: a random value that is never printed
az keyvault secret set --vault-name "$KV" -n "$SECRET" \
  --value "$(openssl rand -hex 24)" --output none

# 5. App Service with a system-assigned identity and a Key Vault reference
az appservice plan create -g "$RG" -n "$PLAN" -l "$LOCATION" --is-linux --sku F1
az webapp create -g "$RG" -n "$APP" -p "$PLAN" --runtime "DOTNETCORE:10.0"
PRINCIPAL_ID=$(az webapp identity assign -g "$RG" -n "$APP" --query principalId -o tsv)
az webapp config appsettings set -g "$RG" -n "$APP" --settings \
  "PasarelaPagos__ApiKey=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/$SECRET)"

# 6. Least privilege: Key Vault Secrets User on this secret only
az role assignment create --role "Key Vault Secrets User" \
  --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --scope "$KV_ID/secrets/$SECRET"

# 7. Deploy the API
dotnet publish src/KeyVaultLab.Api -c Release -o ./publish
(cd publish && zip -r ../app.zip .)
az webapp deploy -g "$RG" -n "$APP" --src-path app.zip --type zip
curl -s "https://$APP.azurewebsites.net/secret-info"

# 8. Rotate the secret and force App Service to refetch its Key Vault references
az keyvault secret set --vault-name "$KV" -n "$SECRET" \
  --value "$(openssl rand -hex 24)" --output none
APP_RESOURCE_ID=$(az webapp show -g "$RG" -n "$APP" --query id -o tsv)
az rest --method post \
  --url "https://management.azure.com$APP_RESOURCE_ID/config/configreferences/appsettings/refresh?api-version=2022-03-01"
curl -s "https://$APP.azurewebsites.net/secret-info"
