using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;

namespace NethLocal;

internal sealed class PairingIdentity : IDisposable
{
    public X509Certificate2 Certificate { get; }
    public byte[] Secret { get; }

    public PairingIdentity(string directory)
    {
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "pairing.bin");
        if (!File.Exists(path))
        {
            using var key = RSA.Create(2048);
            var request = new CertificateRequest("CN=Neth Local Windows", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            request.CertificateExtensions.Add(new X509KeyUsageExtension(
                X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, critical: true));
            using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddYears(10));
            byte[] pfx = certificate.Export(X509ContentType.Pfx);
            byte[] identity = new byte[32 + pfx.Length];
            RandomNumberGenerator.Fill(identity.AsSpan(0, 32));
            pfx.CopyTo(identity, 32);
            try
            {
                File.WriteAllBytes(path + ".new", ProtectedData.Protect(identity, null, DataProtectionScope.CurrentUser));
                File.Move(path + ".new", path);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(identity);
                CryptographicOperations.ZeroMemory(pfx);
            }
        }

        byte[] stored = ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.CurrentUser);
        try
        {
            if (stored.Length <= 32) throw new CryptographicException("Invalid Windows pairing data.");
            Certificate = new X509Certificate2(stored.AsSpan(32), (string?)null, X509KeyStorageFlags.UserKeySet);
            Secret = stored.AsSpan(0, 32).ToArray();
        }
        finally
        {
            CryptographicOperations.ZeroMemory(stored);
        }
    }

    public string Code(Hotspot hotspot)
    {
        byte[] data = JsonSerializer.SerializeToUtf8Bytes(new
        {
            name = Environment.MachineName,
            address = hotspot.Address.ToString(),
            fingerprint = Certificate.GetCertHash(HashAlgorithmName.SHA256),
            secret = Secret
        });
        return "NETH36." + Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    public void Dispose()
    {
        Certificate.Dispose();
        CryptographicOperations.ZeroMemory(Secret);
    }
}
