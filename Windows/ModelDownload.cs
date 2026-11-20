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
    public bool LooksDownloaded => File.Exists(FilePath) && new FileInfo(FilePath).Length == Length;

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
                File.Move(partial, FilePath, overwrite: true);
                progress.Report((Length, Length));
                return;
            }
            File.Delete(partial);
            offset = 0;
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, PinnedUrl);
        if (offset > 0) request.Headers.Range = new RangeHeaderValue(offset, null);
        using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, stop);
        response.EnsureSuccessStatusCode();
        if (response.StatusCode == HttpStatusCode.PartialContent)
        {
            var range = response.Content.Headers.ContentRange;
            if (range is null || range.From != offset || range.Length != Length)
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
            int amount;
            while ((amount = await source.ReadAsync(buffer, stop).AsTask().WaitAsync(TimeSpan.FromMinutes(2), stop)) > 0)
            {
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
        if (offset != Length) throw new IOException("Download interrupted. Press Download to resume.");
        progress.Report((Length, Length));
        if (!await CheckHashAsync(partial, stop))
        {
            File.Delete(partial);
            throw new IOException("The downloaded model did not match the expected SHA-256.");
        }
        File.Move(partial, FilePath, overwrite: true);
    }

    private static async Task<bool> CheckHashAsync(string path, CancellationToken stop)
    {
        await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            bufferSize: 1024 * 1024, options: FileOptions.Asynchronous | FileOptions.SequentialScan);
        return Convert.ToHexString(await SHA256.HashDataAsync(file, stop)).Equals(Sha256, StringComparison.OrdinalIgnoreCase);
    }
}
