using System.Security.Cryptography;
using System.Text;

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/alive", () => Results.Text("Healthy"));

// Reports whether the Key Vault reference was resolved and a short fingerprint
// of the value, so rotation can be verified without ever exposing the secret.
app.MapGet("/secret-info", (IConfiguration config) =>
{
    var value = config["PasarelaPagos:ApiKey"];
    if (string.IsNullOrEmpty(value))
    {
        return Results.Ok(new { configured = false, resolved = false, fingerprint = (string?)null });
    }

    var unresolved = value.StartsWith("@Microsoft.KeyVault(", StringComparison.Ordinal);
    string? fingerprint = unresolved
        ? null
        : Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)))[..8];

    return Results.Ok(new { configured = true, resolved = !unresolved, fingerprint });
});

app.Run();
