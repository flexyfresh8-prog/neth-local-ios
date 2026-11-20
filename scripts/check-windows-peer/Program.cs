using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;

namespace NethLocal;

// CI has no hotspot. Exercise the production protocol and worker with a
// localhost-only test adapter; the shipping app uses Windows/Hotspot.cs.
internal sealed record Hotspot(IPAddress Address)
{
    public static Hotspot Read(Hotspot? current = null) => new(IPAddress.Loopback);
    public bool Accepts(IPAddress address) => IPAddress.IsLoopback(address);
}

internal static class CheckWindowsPeer
{
    public static async Task Main()
    {
        string directory = Path.Combine(Path.GetTempPath(), "NethLocalCheck-" + Guid.NewGuid().ToString("N"));
        try
        {
            using var stop = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            using var identity = new PairingIdentity(directory);
            using var worker = new LayerWorker(Path.Combine(directory, "not-loaded.gguf"));
            await worker.ProbeAsync(stop.Token);
            try
            {
                // A configure command without its arguments leaves the child blocked in a pipe read.
                await worker.ExchangeAsync([1], Memory<byte>.Empty, TimeSpan.FromMilliseconds(400), stop.Token)
                    .WaitAsync(TimeSpan.FromSeconds(5), stop.Token);
                throw new InvalidOperationException("A stalled worker should have timed out.");
            }
            catch (TimeoutException error) when (error.Message == "The Qwen worker took too long to respond.") { }
            await worker.ProbeAsync(stop.Token);

            byte[] pin = identity.Certificate.GetCertHash(HashAlgorithmName.SHA256);
            byte[] hello = new byte[40];
            "NETH36/1"u8.CopyTo(hello);
            identity.Secret.CopyTo(hello, 8);
            await using (var server = new ComputeServer(Hotspot.Read(), identity, worker, _ => { }, _ => { }))
            {
                using var idle = new TcpClient();
                await idle.ConnectAsync(IPAddress.Loopback, ComputeServer.Port, stop.Token);

                using var check = new TcpClient();
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                deadline.CancelAfter(TimeSpan.FromSeconds(5));
                await check.ConnectAsync(IPAddress.Loopback, ComputeServer.Port, deadline.Token);
                using var tls = new SslStream(check.GetStream(), leaveInnerStreamOpen: false,
                    (_, certificate, _, _) => certificate?.GetCertHash(HashAlgorithmName.SHA256).SequenceEqual(pin) == true);
                await tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
                {
                    TargetHost = "Neth Local Windows", AllowRenegotiation = false,
                }, deadline.Token);
                await tls.WriteAsync(hello, deadline.Token);
                var response = new byte[3];
                await tls.ReadExactlyAsync(response, deadline.Token);
                if (!response.SequenceEqual(new byte[3]))
                    throw new InvalidOperationException("The authenticated pairing probe failed.");
                await server.DisposeAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5), stop.Token);
            }
            Console.WriteLine("Windows TLS pairing works alongside an idle client. The worker restarts after a pipe timeout and the server stops with open clients.");
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }
}
