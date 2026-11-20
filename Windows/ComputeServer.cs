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
    private const int MaxConnections = 8;
    private static readonly byte[] Magic = "NETH36/1"u8.ToArray();

    private readonly Hotspot hotspot;
    private readonly PairingIdentity identity;
    private readonly LayerWorker worker;
    private readonly TcpListener listener;
    private readonly CancellationTokenSource stop = new();
    private readonly SemaphoreSlim workerSlot = new(1, 1);
    private readonly Task serverTask;
    private readonly Task watcherTask;
    private readonly Action<string> status;
    private readonly Action<string> stopped;
    private int stopping;
    private int disposed;

    public ComputeServer(Hotspot hotspot, PairingIdentity identity, LayerWorker worker,
                         Action<string> status, Action<string> stopped)
    {
        this.hotspot = hotspot;
        this.identity = identity;
        this.worker = worker;
        this.status = status;
        this.stopped = stopped;
        listener = new TcpListener(hotspot.Address, Port) { ExclusiveAddressUse = true };
        listener.Start(backlog: MaxConnections);
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
                if (Hotspot.Read(hotspot) != hotspot)
                    throw new InvalidOperationException("The 5 GHz hotspot address changed. Rejoin it and click Start server to get a fresh QR code.");
            }
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (Stop()) stopped(error.Message);
        }
    }

    private async Task AcceptAsync()
    {
        var clients = new List<Task>(MaxConnections);
        try
        {
            while (!stop.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(stop.Token);
                clients.RemoveAll(task => task.IsCompleted);
                if (clients.Count >= MaxConnections)
                    client.Dispose();
                else
                    clients.Add(HandleClientAsync(client));
            }
        }
        catch (Exception) when (stop.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (Stop()) stopped(error.Message);
        }
        finally { await Task.WhenAll(clients); }
    }

    private async Task HandleClientAsync(TcpClient client)
    {
        using (client)
        {
            try
            {
                if (client.Client.RemoteEndPoint is not IPEndPoint remote ||
                    !hotspot.Accepts(remote.Address)) return;
                client.NoDelay = true;
                await ServeAsync(client, stop.Token);
            }
            catch (OperationCanceledException) { }
            catch (IOException) { }
            catch (AuthenticationException) { }
            catch (SocketException) { }
            catch (Exception error)
            {
                if (Stop()) stopped($"The Windows server stopped. {error.Message}");
            }
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

        if (workerSlot.CurrentCount != 0) status("iPad connected. Ready for a reply.");
        bool ownsWorker = false;
        string? workerProblem = null;
        try
        {
            int context = 0;
            int nextPosition = 0;
            long statusAfter = 0;
            var header = new byte[9];
            byte[]? activation = null;
            while (!serverStop.IsCancellationRequested)
            {
                await ReadAsync(stream, header, 90, serverStop);
                int first = BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(1));
                int second = BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(5));
                switch (header[0])
                {
                    case 1 when !ownsWorker && (first is 4 or 8 or 12 or 16) && second is >= 512 and <= ContextLimit:
                        ownsWorker = await workerSlot.WaitAsync(TimeSpan.FromSeconds(2), serverStop);
                        if (!ownsWorker)
                        {
                            await WriteStatusAsync(stream, "Windows is already working on another reply. Try again when it finishes.", serverStop);
                            return;
                        }
                        status($"Preparing {first} Qwen layers on the Windows CPU…");
                        try
                        {
                            if (!await worker.ExchangeAsync(header, Memory<byte>.Empty, TimeSpan.FromSeconds(75), serverStop))
                                workerProblem = "Windows couldn’t allocate the shared context. Choose a smaller context or fewer Windows layers.";
                        }
                        catch (Exception error) when (!serverStop.IsCancellationRequested)
                        {
                            workerProblem = error.Message is { Length: < 120 } message
                                ? $"Windows Qwen worker: {message}"
                                : "The Windows Qwen worker stopped while loading. Check the model file and available memory.";
                        }
                        if (workerProblem is not null)
                        {
                            await WriteStatusAsync(stream, workerProblem, serverStop);
                            return;
                        }
                        context = second;
                        activation = new byte[3 + BatchLimit * ActivationSize];
                        await WriteStatusAsync(stream, null, serverStop);
                        status($"Serving {first} Qwen layers over the 5 GHz hotspot.");
                        break;

                    case 2 when activation is not null && (first == nextPosition || first == 0)
                        && second is >= 1 and <= BatchLimit && first <= context - second:
                        var request = new byte[header.Length + sizeof(int) * second];
                        header.CopyTo(request, 0);
                        await ReadAsync(stream, request.AsMemory(header.Length), 8, serverStop);
                        int bytes = second * ActivationSize;
                        bool success;
                        try
                        {
                            success = await worker.ExchangeAsync(request, activation.AsMemory(3, bytes), TimeSpan.FromSeconds(25), serverStop);
                        }
                        catch (Exception) when (!serverStop.IsCancellationRequested) { success = false; }
                        if (!success)
                        {
                            workerProblem = "The Qwen worker couldn’t finish this batch. Try the reply again.";
                            await WriteStatusAsync(stream, workerProblem, serverStop);
                            return;
                        }
                        nextPosition = first + second;
                        await WriteAsync(stream, activation.AsMemory(0, 3 + bytes), serverStop);
                        if (Environment.TickCount64 >= statusAfter)
                        {
                            status($"Computing on Windows · {nextPosition:N0} positions processed");
                            statusAfter = Environment.TickCount64 + 500;
                        }
                        break;

                    default:
                        await WriteStatusAsync(stream, "This shared-inference request is outside the supported limits.", serverStop);
                        return;
                }
            }
        }
        finally
        {
            if (ownsWorker)
            {
                if (!serverStop.IsCancellationRequested) status(workerProblem ?? "Ready for the paired iPad.");
                workerSlot.Release();
            }
        }
    }

    private static async Task ReadAsync(Stream stream, Memory<byte> data, int seconds, CancellationToken stop)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop);
        deadline.CancelAfter(TimeSpan.FromSeconds(seconds));
        await stream.ReadExactlyAsync(data, deadline.Token);
    }

    private static async Task WriteAsync(Stream stream, ReadOnlyMemory<byte> data, CancellationToken stop)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop);
        deadline.CancelAfter(TimeSpan.FromSeconds(12));
        await stream.WriteAsync(data, deadline.Token);
    }

    private static async Task WriteStatusAsync(SslStream stream, string? error, CancellationToken stop)
    {
        var message = error is null ? Array.Empty<byte>() : Encoding.UTF8.GetBytes(error);
        var packet = new byte[3 + message.Length];
        packet[0] = (byte)(error is null ? 0 : 1);
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), (ushort)message.Length);
        message.CopyTo(packet, 3);
        await WriteAsync(stream, packet, stop);
    }

    private bool Stop()
    {
        if (Interlocked.Exchange(ref stopping, 1) != 0) return false;
        stop.Cancel();
        listener.Stop();
        return true;
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
            workerSlot.Dispose();
            stop.Dispose();
        }
    }
}
