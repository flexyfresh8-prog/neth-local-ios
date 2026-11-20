using System.Diagnostics;
using System.Reflection;
using System.ComponentModel;

namespace NethLocal;

internal sealed class LayerWorker(string model) : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "NethLocalWorker-" + Guid.NewGuid().ToString("N"));
    private Process? process;
    private string Executable => Path.Combine(directory, "neth-qwen-worker.exe");
    private readonly object sync = new();
    private bool disposed;

    public async Task ProbeAsync(CancellationToken stop)
    {
        if (!await ExchangeAsync([0], Memory<byte>.Empty, TimeSpan.FromSeconds(15), stop).ConfigureAwait(false))
            throw new IOException("The bundled Qwen worker returned an invalid startup response.");
    }

    public async Task<bool> ExchangeAsync(byte[] request, Memory<byte> activation, TimeSpan timeout, CancellationToken stop)
    {
        stop.ThrowIfCancellationRequested();
        Process child = GetProcess();
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop);
        deadline.CancelAfter(timeout);
        // Anonymous pipe reads on Windows can remain blocked after token cancellation.
        // Closing the worker end also releases a pending system read.
        using var interrupt = deadline.Token.Register(() => Kill(child));
        var input = child.StandardInput.BaseStream;
        var output = child.StandardOutput.BaseStream;
        try
        {
            await input.WriteAsync(request, deadline.Token).ConfigureAwait(false);
            await input.FlushAsync(deadline.Token).ConfigureAwait(false);
            var result = new byte[1];
            await output.ReadExactlyAsync(result, deadline.Token).ConfigureAwait(false);
            if (result[0] != 0) return false;
            if (!activation.IsEmpty) await output.ReadExactlyAsync(activation, deadline.Token).ConfigureAwait(false);
            return true;
        }
        catch
        {
            lock (sync) StopChild();
            stop.ThrowIfCancellationRequested();
            if (deadline.IsCancellationRequested) throw new TimeoutException("The Qwen worker took too long to respond.");
            throw;
        }
    }

    private Process GetProcess()
    {
        lock (sync)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (process is { HasExited: false }) return process;
            StopChild();
            if (!File.Exists(Executable))
            {
                Directory.CreateDirectory(directory);
                using var resource = Assembly.GetExecutingAssembly().GetManifestResourceStream("NethLocal.Worker.exe")
                    ?? throw new IOException("This Windows build is missing its model worker.");
                string temporary = Executable + ".partial";
                using (var file = File.Create(temporary)) resource.CopyTo(file);
                File.Move(temporary, Executable);
            }

            var start = new ProcessStartInfo(Executable)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = directory,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            start.ArgumentList.Add(model);
            try
            {
                var child = Process.Start(start) ?? throw new IOException("Windows could not start the Qwen model worker.");
                process = child;
                child.ErrorDataReceived += (_, _) => { };
                child.BeginErrorReadLine();
                return child;
            }
            catch (Win32Exception error)
            {
                StopChild();
                throw new IOException($"Windows could not launch the bundled Qwen worker. {error.Message} (Windows error {error.NativeErrorCode})", error);
            }
            catch
            {
                StopChild();
                throw;
            }
        }
    }

    private void StopChild()
    {
        if (process is not { } child) return;
        process = null;
        try
        {
            Kill(child);
            child.WaitForExit(1_500);
        }
        catch (InvalidOperationException) { }
        catch (Win32Exception) { }
        finally { child.Dispose(); }
    }

    private static void Kill(Process child)
    {
        try { if (!child.HasExited) child.Kill(); }
        catch (InvalidOperationException) { }
        catch (Win32Exception) { }
    }

    public void Dispose()
    {
        lock (sync)
        {
            if (disposed) return;
            disposed = true;
            StopChild();
            try { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }
}
