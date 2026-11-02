#!/usr/bin/env bash
# Reference commands for the lab, in the order they were run.
# Run them step by step in Azure Cloud Shell (Bash), not as a single script.

RG="rg-key-vault-rbac-rotacion"
LOCATION="centralus"
SUFFIX="${SUFFIX:-4817}"         # vault names are global: change the suffix if it is taken
KV="kv-rbac-rot-$SUFFIX"
LAW="log-key-vault-rbac-rotacion"
PLAN="asp-key-vault-rbac-rotacion"
APP="kv-rbac-rot-$SUFFIX"         # must be unique in *.azurewebsites.net
SECRET="pasarela-pagos-api-key"

# 1. Resource group and vault (RBAC, purge protection, 7-day retention).
#    In the lab run these two were created from the portal; the CLI equivalent below was not run.
az group create -n "$RG" -l "$LOCATION"
az keyvault create -g "$RG" -n "$KV" -l "$LOCATION" --sku standard \
  --enable-rbac-authorization true --enable-purge-protection true --retention-days 7
KV_ID=$(az keyvault show -n "$KV" --query id -o tsv)

# 2. Data-plane role for the signed-in user (Owner alone cannot read or write secrets)
ME=$(az ad signed-in-user show --query id -o tsv)
az role assignment create --role "Key Vault Secrets Officer" \
  --assignee-object-id "$ME" --assignee-principal-type User --scope "$KV_ID"

# 3. Workspace and audit logs (resource-specific table AZKVAuditLogs)
az monitor log-analytics workspace create -g "$RG" -n "$LAW" -l "$LOCATION"
az provider register -n Microsoft.Insights --wait      # was NotRegistered in the lab subscription
LAW_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query id -o tsv)
az monitor diagnostic-settings create -n kv-audit --resource "$KV_ID" --workspace "$LAW_ID" \
  --export-to-resource-specific true --logs '[{"category":"AuditEvent","enabled":true}]'

# 4. The secret: a random value that is never printed
az keyvault secret set --vault-name "$KV" -n "$SECRET" \
  --value "$(openssl rand -hex 24)" --output none

# 5. App Service with a system-assigned identity and a Key Vault reference.
#    The identity has no role yet, so the reference reports AccessToKeyVaultDenied.
az appservice plan create -g "$RG" -n "$PLAN" -l "$LOCATION" --is-linux --sku F1
az webapp create -g "$RG" -n "$APP" -p "$PLAN" --runtime "DOTNETCORE:10.0"
PRINCIPAL_ID=$(az webapp identity assign -g "$RG" -n "$APP" --query principalId -o tsv)
az webapp config appsettings set -g "$RG" -n "$APP" --settings \
  "PasarelaPagos__ApiKey=@Microsoft.KeyVault(SecretUri=https://$KV.vault.azure.net/secrets/$SECRET)" \
  --query "[].name" -o tsv

# 6. Least privilege: Key Vault Secrets User on this secret only, then force the reference to resolve
az role assignment create --role "Key Vault Secrets User" \
  --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --scope "$KV_ID/secrets/$SECRET"
APP_RESOURCE_ID=$(az webapp show -g "$RG" -n "$APP" --query id -o tsv)
REFS="https://management.azure.com$APP_RESOURCE_ID/config/configreferences/appsettings"
az rest --method post --url "$REFS/refresh?api-version=2022-03-01"
az rest --method get  --url "$REFS?api-version=2022-03-01" --query "value[0].properties.status" -o tsv

# 7. Deploy the API. Cloud Shell ships .NET SDK 9; install SDK 10 in the ephemeral session.
curl -sSL https://dot.net/v1/dotnet-install.sh -o dotnet-install.sh
bash dotnet-install.sh --channel 10.0 --install-dir "$HOME/.dotnet"
export DOTNET_ROOT="$HOME/.dotnet" PATH="$HOME/.dotnet:$PATH"
dotnet publish src/KeyVaultLab.Api -c Release -o ./publish
(cd publish && zip -qr ../app.zip .)
az webapp deploy -g "$RG" -n "$APP" --src-path app.zip --type zip
curl -s "https://$APP.azurewebsites.net/secret-info"

# 8. Rotate the secret and measure how long the app takes to see the new version
URL="https://$APP.azurewebsites.net/secret-info"
OLD=$(curl -s "$URL")
az keyvault secret set --vault-name "$KV" -n "$SECRET" \
  --value "$(openssl rand -hex 24)" --output none
sleep 30; curl -s "$URL"          # still the old fingerprint: the reference is cached
az rest --method post --url "$REFS/refresh?api-version=2022-03-01"
T0=$(date +%s)
while [ "$(curl -s "$URL")" = "$OLD" ]; do sleep 10; done
echo "new value after $(( $(date +%s) - T0 ))s"

# 9. Audit: run queries/audit.kql in the Log Analytics workspace

# 10. Purge protection: delete a test secret and try to purge it (expected: Forbidden)
az keyvault secret set --vault-name "$KV" -n secreto-de-prueba \
  --value "$(openssl rand -hex 16)" --output none
az keyvault secret delete --vault-name "$KV" -n secreto-de-prueba \
  --query "{name:name, scheduledPurgeDate:scheduledPurgeDate}" -o json
az keyvault secret purge --vault-name "$KV" -n secreto-de-prueba
