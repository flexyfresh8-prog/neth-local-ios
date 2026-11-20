using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;

namespace NethLocal;

internal sealed class ModelDownload(string directory)
{
    private const long Length = 2_707_513_696;
    private const string FileName = "Qwen3.5-4B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf";
    private const string PinnedUrl = "https://huggingface.co/HauhauCS/Qwen3.5-4B-Uncensored-HauhauCS-Aggressive/resolve/c09cdbcdb1fefad6d335809d445621b5f5ba0c6e/" + FileName + "?download=true";
    private const string Sha256 = "79e28ecacf84e75b6056cf4059636d435aa9eb67795780f7b7dbc7d32a962741";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(2) };

    public string FilePath => Path.Combine(directory, FileName);
    public bool LooksDownloaded
    {
        get
        {
            var file = new FileInfo(FilePath);
            return file.Exists && file.Length == Length;
        }
    }

    public async Task<bool> VerifyAsync(CancellationToken stop)
    {
        if (!LooksDownloaded) return false;
        return await CheckHashAsync(FilePath, stop);
    }

    public async Task DownloadAsync(IProgress<(long bytes, long total)> progress, CancellationToken stop)
    {
        Directory.CreateDirectory(directory);
        if (await VerifyAsync(stop))
        {
            progress.Report((Length, Length));
            return;
        }
        string partial = FilePath + ".partial";
        long offset = File.Exists(partial) ? new FileInfo(partial).Length : 0;
        if (offset >= Length)
        {
            if (offset == Length && await CheckHashAsync(partial, stop))
            {
                stop.ThrowIfCancellationRequested();
                File.Move(partial, FilePath, overwrite: true);
                progress.Report((Length, Length));
                return;
            }
            File.Delete(partial);
            offset = 0;
        }

        using var resumed = await RequestAsync(offset, stop);
        bool restart = offset > 0 && (resumed.StatusCode == HttpStatusCode.RequestedRangeNotSatisfiable ||
            (resumed.StatusCode == HttpStatusCode.PartialContent && !MatchesRange(resumed, offset)));
        if (restart)
        {
            resumed.Dispose();
            offset = 0;
        }
        using var restarted = restart ? await RequestAsync(0, stop) : null;
        var response = restarted ?? resumed;
        response.EnsureSuccessStatusCode();
        if (response.StatusCode == HttpStatusCode.PartialContent)
        {
            if (!MatchesRange(response, offset))
                throw new IOException("The model server returned a different download range.");
        }
        else
        {
            offset = 0;
        }
        await using var source = await response.Content.ReadAsStreamAsync(stop);
        await using (var target = new FileStream(partial, offset > 0 ? FileMode.Append : FileMode.Create,
            FileAccess.Write, FileShare.None, bufferSize: 1024 * 1024, useAsync: true))
        {
            var buffer = new byte[256 * 1024];
            var nextUpdate = Environment.TickCount64;
            using var idle = CancellationTokenSource.CreateLinkedTokenSource(stop);
            try
            {
                while (true)
                {
                    idle.CancelAfter(TimeSpan.FromMinutes(2));
                    int amount = await source.ReadAsync(buffer, idle.Token);
                    idle.CancelAfter(Timeout.InfiniteTimeSpan);
                    if (amount == 0) break;
                    offset += amount;
                    if (offset > Length) throw new IOException("The download is larger than the pinned model.");
                    await target.WriteAsync(buffer.AsMemory(0, amount), stop);
                    if (Environment.TickCount64 >= nextUpdate)
                    {
                        progress.Report((offset, Length));
                        nextUpdate = Environment.TickCount64 + 150;
                    }
                }
            }
            catch (OperationCanceledException) when (!stop.IsCancellationRequested)
            {
                throw new IOException("The model download stopped receiving data. Press Download model to resume.");
            }
        }
        if (offset != Length) throw new IOException("Download interrupted. Press Download to resume.");
        progress.Report((Length, Length));
        if (!await CheckHashAsync(partial, stop))
        {
            File.Delete(partial);
            throw new IOException("The downloaded model did not match the expected SHA-256.");
        }
        stop.ThrowIfCancellationRequested();
        File.Move(partial, FilePath, overwrite: true);
    }

    private static bool MatchesRange(HttpResponseMessage response, long offset) =>
        response.Content.Headers.ContentRange is { } range &&
        range.From == offset && range.Length == Length && range.To == Length - 1;

    private static async Task<HttpResponseMessage> RequestAsync(long offset, CancellationToken stop)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, PinnedUrl);
        if (offset > 0) request.Headers.Range = new RangeHeaderValue(offset, null);
        try { return await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, stop); }
        catch (OperationCanceledException) when (!stop.IsCancellationRequested)
        {
            throw new IOException("The model host did not respond. Press Download model to retry.");
        }
    }

    private static async Task<bool> CheckHashAsync(string path, CancellationToken stop)
    {
        await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            bufferSize: 1024 * 1024, options: FileOptions.Asynchronous | FileOptions.SequentialScan);
        return Convert.ToHexString(await SHA256.HashDataAsync(file, stop)).Equals(Sha256, StringComparison.OrdinalIgnoreCase);
    }
}
