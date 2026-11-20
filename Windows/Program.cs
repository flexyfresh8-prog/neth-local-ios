using System.Diagnostics;
using System.Runtime.Intrinsics.X86;
using QRCoder;

namespace NethLocal;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        if (!Avx2.IsSupported || !Fma.IsSupported)
        {
            MessageBox.Show("Neth Local Windows needs an x64 processor with AVX2 and FMA.", "Neth Local Windows");
            return;
        }
        using var instance = new Mutex(true, @"Local\NethLocal.Windows", out bool created);
        if (!created)
        {
            MessageBox.Show("The Neth Local Windows companion is already running.", "Neth Local Windows");
            return;
        }
        try { Application.Run(new ServerWindow()); }
        finally { instance.ReleaseMutex(); }
    }
}

internal sealed class ServerWindow : Form
{
    private static readonly Color Surface = Color.FromArgb(32, 30, 39);
    private static readonly Color Canvas = Color.FromArgb(22, 21, 28);
    private static readonly Color TextColor = Color.FromArgb(242, 239, 246);
    private static readonly Color Muted = Color.FromArgb(177, 171, 184);
    private static readonly Color Violet = Color.FromArgb(201, 178, 250);
    private static readonly string DataDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NethLocal", "Windows");
    private readonly ModelDownload model = new(Path.Combine(DataDirectory, "Models"));
    private readonly CancellationTokenSource lifetime = new();
    private readonly Button download = ActionButton("Download model");
    private readonly Button hotspot = ActionButton("Open Mobile Hotspot settings");
    private readonly Button toggle = ActionButton("Start server", primary: true);
    private readonly Button copy = ActionButton("Copy pairing code");
    private readonly Label modelStatus = Caption("Qwen3.5 4B Uncensored · Q4_K_M · 2.71 GB");
    private readonly Label serviceStatus = Caption("Server stopped");
    private readonly Label pairing = Caption("The pairing code appears when the server starts.");
    private readonly ProgressBar progress = new() { Dock = DockStyle.Fill, Height = 10, Maximum = 1000 };
    private readonly PictureBox qr = new() { Dock = DockStyle.Fill, SizeMode = PictureBoxSizeMode.Zoom, Margin = new Padding(0, 8, 0, 8) };
    private CancellationTokenSource? downloadStop;
    private ComputeServer? server;
    private string? code;
    private bool verified;
    private bool busy;
    private bool closing;

    public ServerWindow()
    {
        Text = "Neth Local Windows · 3.6";
        ClientSize = new Size(510, 639);
        MinimumSize = new Size(470, 678);
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Canvas;
        ForeColor = TextColor;
        Font = new Font("Segoe UI", 10F, FontStyle.Regular);
        var layout = new TableLayoutPanel
        {
            ColumnCount = 1, RowCount = 11, Dock = DockStyle.Fill, Padding = new Padding(20)
        };
        foreach (int size in new[] { 40, 40, 43, 17, 52, 38, 46, 46 })
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, size));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        var title = new Label
        {
            Text = "Neth Local Windows", ForeColor = TextColor, Dock = DockStyle.Fill,
            Font = new Font("Segoe UI", 19F, FontStyle.Bold), TextAlign = ContentAlignment.MiddleLeft
        };
        layout.Controls.Add(title, 0, 0);
        layout.Controls.Add(modelStatus, 0, 1);
        layout.Controls.Add(download, 0, 2);
        layout.Controls.Add(progress, 0, 3);
        layout.Controls.Add(hotspot, 0, 4);
        layout.Controls.Add(Caption("Share over Wi-Fi. Set Network band to 5 GHz and turn on Mobile Hotspot."), 0, 5);
        layout.Controls.Add(toggle, 0, 6);
        layout.Controls.Add(serviceStatus, 0, 7);
        layout.Controls.Add(qr, 0, 8);
        layout.Controls.Add(pairing, 0, 9);
        layout.Controls.Add(copy, 0, 10);
        Controls.Add(layout);

        Shown += async (_, _) => await CheckModelAsync();
        download.Click += async (_, _) => await DownloadAsync();
        toggle.Click += async (_, _) =>
        {
            if (server is null) await StartAsync();
            else await StopAsync("Server stopped");
        };
        hotspot.Click += (_, _) => Process.Start(new ProcessStartInfo("ms-settings:network-mobilehotspot")
        {
            UseShellExecute = true
        });
        copy.Click += (_, _) =>
        {
            if (code is { } value)
            {
                try { Clipboard.SetText(value); }
                catch (System.Runtime.InteropServices.ExternalException) { pairing.Text = "Clipboard is busy. Scan the QR code."; }
            }
        };
        UpdateControls();
    }

    private static Label Caption(string value) => new()
    {
        Text = value, Dock = DockStyle.Fill, ForeColor = Muted, TextAlign = ContentAlignment.MiddleLeft
    };

    private static Button ActionButton(string value, bool primary = false)
    {
        var button = new Button
        {
            Text = value, Dock = DockStyle.Fill, FlatStyle = FlatStyle.Flat, UseVisualStyleBackColor = false,
            BackColor = primary ? Violet : Surface, ForeColor = primary ? Canvas : TextColor,
            Margin = new Padding(0, 4, 0, 4)
        };
        button.FlatAppearance.BorderColor = Color.FromArgb(76, 65, 93);
        return button;
    }

    private async Task CheckModelAsync()
    {
        if (!model.LooksDownloaded) return;
        busy = true;
        modelStatus.Text = "Checking the downloaded model…";
        UpdateControls();
        try
        {
            verified = await model.VerifyAsync(lifetime.Token);
            modelStatus.Text = verified ? "Qwen3.5 4B model ready" : "Model verification failed. Download it again.";
            progress.Value = verified ? progress.Maximum : 0;
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { modelStatus.Text = error.Message; }
        finally
        {
            busy = false;
            UpdateControls();
        }
    }

    private async Task DownloadAsync()
    {
        if (downloadStop is { } active)
        {
            active.Cancel();
            return;
        }
        using var operation = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        downloadStop = operation;
        modelStatus.Text = "Connecting to the model download…";
        UpdateControls();
        var report = new Progress<(long bytes, long total)>(count =>
        {
            if (closing || downloadStop != operation) return;
            progress.Value = (int)(progress.Maximum * count.bytes / count.total);
            modelStatus.Text = count.bytes == count.total
                ? "Verifying the model’s SHA-256…"
                : $"Downloading Qwen · {count.bytes / 1e9:F2} of {count.total / 1e9:F2} GB";
        });
        try
        {
            await model.DownloadAsync(report, operation.Token);
            verified = true;
            progress.Value = progress.Maximum;
            modelStatus.Text = "Qwen3.5 4B model ready";
        }
        catch (OperationCanceledException) { modelStatus.Text = "Download paused. Press Download model to resume."; }
        catch (Exception error) { modelStatus.Text = error.Message; }
        finally
        {
            downloadStop = null;
            UpdateControls();
        }
    }

    private async Task StartAsync()
    {
        if (!verified || busy || closing) return;
        busy = true;
        serviceStatus.Text = "Checking the 5 GHz hotspot…";
        UpdateControls();
        PairingIdentity? identity = null;
        try
        {
            var network = await Task.Run(Hotspot.Read, lifetime.Token);
            if (closing) return;
            identity = new PairingIdentity(DataDirectory);
            var newCode = identity.Code(network);
            using var qrData = QRCodeGenerator.GenerateQrCode(newCode, QRCodeGenerator.ECCLevel.M);
            var png = new PngByteQRCode(qrData).GetGraphic(6);
            using var stream = new MemoryStream(png);
            using var image = Image.FromStream(stream);

            var owner = new object();
            server = new ComputeServer(network, identity, model.FilePath,
                message => Post(() => { if (ReferenceEquals(session, owner)) serviceStatus.Text = message; }),
                message => Post(async () => { if (ReferenceEquals(session, owner)) await StopAsync(message); }));
            session = owner;
            identity = null;
            code = newCode;
            qr.Image = new Bitmap(image);
            pairing.Text = $"Join “{network.Name}” on the iPad and scan this code in Models & context.";
            serviceStatus.Text = "Ready for the paired iPad. Allow the app through Windows Firewall if prompted.";
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { serviceStatus.Text = error.Message; }
        finally
        {
            identity?.Dispose();
            busy = false;
            UpdateControls();
        }
    }

    private object? session;

    private async Task StopAsync(string message)
    {
        if (server is not { } active) return;
        server = null;
        session = null;
        busy = true;
        code = null;
        var image = qr.Image;
        qr.Image = null;
        image?.Dispose();
        pairing.Text = "The pairing code appears when the server starts.";
        serviceStatus.Text = message;
        UpdateControls();
        try { await active.DisposeAsync(); }
        finally
        {
            busy = false;
            UpdateControls();
        }
    }

    private void Post(Action action)
    {
        if (IsDisposed || !IsHandleCreated) return;
        try { BeginInvoke(action); }
        catch (InvalidOperationException) { }
    }

    private void UpdateControls()
    {
        if (closing) return;
        download.Text = downloadStop is null ? (verified ? "Model downloaded" : "Download model") : "Pause download";
        download.Enabled = !busy && !verified && server is null;
        toggle.Text = server is null ? "Start server" : "Stop server";
        toggle.Enabled = !busy && verified;
        copy.Enabled = code is not null;
    }

    protected override async void OnFormClosing(FormClosingEventArgs e)
    {
        if (!closing)
        {
            closing = true;
            lifetime.Cancel();
            if (server is not null)
            {
                e.Cancel = true;
                await StopAsync("Server stopped");
                if (IsHandleCreated) BeginInvoke(Close);
            }
        }
        base.OnFormClosing(e);
    }
}
