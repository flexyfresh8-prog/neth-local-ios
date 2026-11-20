using System.Buffers.Binary;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Text;

namespace NethLocal;

internal sealed class ComputeServer : IAsyncDisposable
{
    public const int Port = 52436;
    private const int BatchLimit = 128;
    private const int ContextLimit = 32_768;
    private const int ActivationSize = 2560 * sizeof(float);
    private static readonly byte[] Magic = "NETH36/1"u8.ToArray();

    private readonly Hotspot hotspot;
    private readonly PairingIdentity identity;
    private readonly LayerWorker worker;
    private readonly TcpListener listener;
    private readonly CancellationTokenSource stop = new();
    private readonly Task serverTask;
    private readonly Task watcherTask;
    private readonly Action<string> status;
    private readonly Action<string> stopped;
    private int stopping;
    private int disposed;

    public ComputeServer(Hotspot hotspot, PairingIdentity identity, string model,
                         Action<string> status, Action<string> stopped)
    {
        this.hotspot = hotspot;
        this.identity = identity;
        this.status = status;
        this.stopped = stopped;
        listener = new TcpListener(hotspot.Address, Port) { ExclusiveAddressUse = true };
        listener.Start(backlog: 3);
        worker = new LayerWorker(model);
        serverTask = Task.Run(AcceptAsync);
        watcherTask = Task.Run(WatchHotspotAsync);
    }

    private async Task WatchHotspotAsync()
    {
        try
        {
            while (!stop.IsCancellationRequested)
            {
                await Task.Delay(1_500, stop.Token);
                if (Hotspot.Read() != hotspot)
                    throw new InvalidOperationException("The 5 GHz hotspot changed. Start the server again after reconnecting.");
            }
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
        catch (Exception error)
        {
            Stop();
            stopped(error.Message);
        }
    }

    private async Task AcceptAsync()
    {
        try
        {
            while (!stop.IsCancellationRequested)
            {
                using var client = await listener.AcceptTcpClientAsync(stop.Token);
                if (client.Client.RemoteEndPoint is not IPEndPoint remote || !hotspot.Accepts(remote.Address)) continue;
                client.NoDelay = true;
                try { await ServeAsync(client, stop.Token); }
                catch (OperationCanceledException) { }
                catch (IOException) { }
                catch (AuthenticationException) { }
                catch (SocketException) { }
                finally { if (!stop.IsCancellationRequested) status("Ready for the paired iPad."); }
            }
        }
        catch (Exception) when (stop.IsCancellationRequested) { }
        catch (Exception error)
        {
            Stop();
            stopped(error.Message);
        }
    }

    private async Task ServeAsync(TcpClient client, CancellationToken serverStop)
    {
        using var stream = new SslStream(client.GetStream(), leaveInnerStreamOpen: false);
        using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(serverStop))
        {
            deadline.CancelAfter(TimeSpan.FromSeconds(8));
            await stream.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            {
                ServerCertificate = identity.Certificate,
                EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                AllowRenegotiation = false
            }, deadline.Token);
            byte[] hello = new byte[Magic.Length + identity.Secret.Length];
            await stream.ReadExactlyAsync(hello, deadline.Token);
            if (!hello.AsSpan(0, Magic.Length).SequenceEqual(Magic) ||
                !CryptographicOperations.FixedTimeEquals(hello.AsSpan(Magic.Length), identity.Secret)) return;
            await WriteStatusAsync(stream, null, deadline.Token);
        }

        bool configured = false;
        int context = 0;
        int nextPosition = 0;
        long statusAfter = 0;
        var header = new byte[9];
        var activation = new byte[3 + BatchLimit * ActivationSize];
        while (!serverStop.IsCancellationRequested)
        {
            using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(serverStop))
            {
                deadline.CancelAfter(TimeSpan.FromSeconds(90));
                await stream.ReadExactlyAsync(header, deadline.Token);
            }
            int first = BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(1));
            int second = BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(5));
            switch (header[0])
            {
                case 1 when !configured && (first is 4 or 8 or 12 or 16) && second is >= 512 and <= ContextLimit:
                    status($"Preparing {first} Qwen layers on the Windows CPU…");
                    try
                    {
                        configured = await worker.ExchangeAsync(header, Memory<byte>.Empty, TimeSpan.FromSeconds(75), serverStop);
                    }
                    catch (Exception) when (!serverStop.IsCancellationRequested)
                    {
                        await WriteStatusAsync(stream, "Windows couldn’t start the Qwen worker. Check the executable and available memory.", serverStop);
                        return;
                    }
                    if (!configured)
                    {
                        await WriteStatusAsync(stream, "Windows couldn’t allocate the shared context. Select a smaller context or fewer Windows layers.", serverStop);
                        return;
                    }
                    context = second;
                    await WriteStatusAsync(stream, null, serverStop);
                    status($"Serving {first} Qwen layers over the 5 GHz hotspot.");
                    break;

                case 2 when configured && (first == nextPosition || first == 0)
                    && second is >= 1 and <= BatchLimit && first <= context - second:
                    var request = new byte[header.Length + sizeof(int) * second];
                    header.CopyTo(request, 0);
                    using (var deadline = CancellationTokenSource.CreateLinkedTokenSource(serverStop))
                    {
                        deadline.CancelAfter(TimeSpan.FromSeconds(8));
                        await stream.ReadExactlyAsync(request.AsMemory(header.Length), deadline.Token);
                    }
                    int bytes = second * ActivationSize;
                    bool success;
                    try
                    {
                        success = await worker.ExchangeAsync(request, activation.AsMemory(3, bytes), TimeSpan.FromSeconds(25), serverStop);
                    }
                    catch (Exception) when (!serverStop.IsCancellationRequested)
                    {
                        success = false;
                    }
                    if (!success)
                    {
                        await WriteStatusAsync(stream, "The Windows layers could not finish this batch.", serverStop);
                        return;
                    }
                    nextPosition = first + second;
                    await stream.WriteAsync(activation.AsMemory(0, 3 + bytes), serverStop);
                    if (Environment.TickCount64 >= statusAfter)
                    {
                        status($"Computing on Windows · {nextPosition:N0} positions processed");
                        statusAfter = Environment.TickCount64 + 500;
                    }
                    break;

                default:
                    await WriteStatusAsync(stream, "This shared-inference request is outside the v3.6 limits.", serverStop);
                    return;
            }
        }
    }

    private static async Task WriteStatusAsync(SslStream stream, string? error, CancellationToken stop)
    {
        var message = error is null ? Array.Empty<byte>() : Encoding.UTF8.GetBytes(error);
        var packet = new byte[3 + message.Length];
        packet[0] = (byte)(error is null ? 0 : 1);
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), (ushort)message.Length);
        message.CopyTo(packet, 3);
        await stream.WriteAsync(packet, stop);
    }

    public void Stop()
    {
        if (Interlocked.Exchange(ref stopping, 1) != 0) return;
        stop.Cancel();
        listener.Stop();
        worker.Dispose();
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        Stop();
        try { await Task.WhenAll(serverTask, watcherTask); }
        finally
        {
            worker.Dispose();
            identity.Dispose();
            stop.Dispose();
        }
    }
}
