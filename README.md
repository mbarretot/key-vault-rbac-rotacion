# key-vault-rbac-rotacion

An App Service app reads a third-party API key from Azure Key Vault without storing it in its configuration. Access uses Azure RBAC with the least-privilege role on a single secret, the secret rotates without redeploying the app, purge protection blocks irreversible deletes, and every read is audited in Log Analytics.

- Article: [Key Vault: guardar los secretos que no puedes eliminar y saber quién los lee](https://www.planoarch.com/blog/key-vault-secretos)
- Lab: [planoarch.com/projects/key-vault-rbac-rotacion](https://www.planoarch.com/projects/key-vault-rbac-rotacion)

> This repository is built while running the lab. Commands and notes are updated with what actually happened during the run.

## Architecture

- Azure Key Vault (Standard) with the Azure RBAC permission model, purge protection and 7-day soft-delete retention.
- A secret, `pasarela-pagos-api-key`, with a random value that is never printed.
- A Log Analytics workspace receiving the vault's `AuditEvent` logs (table `AZKVAuditLogs`).
- An App Service (Linux, F1) with a system-assigned managed identity that has `Key Vault Secrets User` on that secret only.
- An app setting, `PasarelaPagos__ApiKey`, whose value is a Key Vault reference.
- A minimal .NET 10 API (`src/KeyVaultLab.Api`) that reports whether the setting is resolved and an 8-character SHA-256 fingerprint of it. It never returns the value.

## Prerequisites

- An Azure subscription where you can create a resource group and assign roles (Owner or User Access Administrator on the resource group).
- Azure Cloud Shell (Bash) or Azure CLI signed in.
- .NET SDK 10 to build the API.

## Run it yourself

`infra/lab.sh` contains the commands in order. Run them step by step, not as a single script:

1. Create the resource group, the Log Analytics workspace and the vault with RBAC and purge protection.
2. Give yourself `Key Vault Secrets Officer` on the vault. Owner alone cannot read or write secrets.
3. Send `AuditEvent` logs to the workspace.
4. Create the secret with a random value.
5. Create the App Service, enable its identity and add the Key Vault reference.
6. Give the identity `Key Vault Secrets User` on the secret.
7. Deploy the API and call `/secret-info`.
8. Rotate the secret, force the reference refresh and check that the fingerprint changes.
9. Run `queries/audit.kql` in the workspace.

## Cleanup

```bash
az group delete -n rg-key-vault-rbac-rotacion --yes
```

With purge protection enabled, the deleted vault stays in soft-delete for the retention period (7 days in this lab). Nobody can purge it and its name stays reserved until then.

## License

[MIT](LICENSE)
