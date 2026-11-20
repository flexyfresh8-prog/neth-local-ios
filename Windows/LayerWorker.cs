using System.Diagnostics;
using System.Reflection;

namespace NethLocal;

internal sealed class LayerWorker(string model) : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "NethLocalWorker-" + Guid.NewGuid().ToString("N"));
    private Process? process;
    private string Executable => Path.Combine(directory, "neth-qwen-worker.exe");
    private readonly object sync = new();
    private bool disposed;

    public async Task<bool> ExchangeAsync(byte[] request, Memory<byte> activation, TimeSpan timeout, CancellationToken stop)
    {
        Process child = GetProcess();
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop);
        deadline.CancelAfter(timeout);
        var input = child.StandardInput.BaseStream;
        var output = child.StandardOutput.BaseStream;
        try
        {
            await input.WriteAsync(request, deadline.Token);
            await input.FlushAsync(deadline.Token);
            var result = new byte[1];
            await output.ReadExactlyAsync(result, deadline.Token);
            if (result[0] != 0) return false;
            if (!activation.IsEmpty) await output.ReadExactlyAsync(activation, deadline.Token);
            return true;
        }
        catch
        {
            lock (sync) StopChild();
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
                using var file = File.Create(Executable);
                resource.CopyTo(file);
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
            var child = Process.Start(start) ?? throw new IOException("Windows could not start the Qwen model worker.");
            child.ErrorDataReceived += (_, _) => { };
            child.BeginErrorReadLine();
            process = child;
            return child;
        }
    }

    private void StopChild()
    {
        if (process is not { } child) return;
        process = null;
        try
        {
            if (!child.HasExited) child.Kill();
            child.WaitForExit(1_500);
        }
        catch (InvalidOperationException) { }
        catch (System.ComponentModel.Win32Exception) { }
        finally { child.Dispose(); }
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
