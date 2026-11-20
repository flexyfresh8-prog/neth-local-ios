using System.Diagnostics;
using System.Net.Sockets;
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
    private Task? operation;
    private object? session;
    private string? code;
    private bool verified;
    private bool busy;
    private bool closing;
    private bool readyToClose;

    public ServerWindow()
    {
        var version = typeof(ServerWindow).Assembly.GetName().Version!.ToString(3);
        Text = $"Neth Local Windows · {version}";
        ClientSize = new Size(510, 692);
        MinimumSize = new Size(400, 400);
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        BackColor = Canvas;
        ForeColor = TextColor;
        Font = new Font("Segoe UI", 10F, FontStyle.Regular);
        var layout = new TableLayoutPanel
        {
            ColumnCount = 1, RowCount = 11, Dock = DockStyle.Top, Height = 692, Padding = new Padding(20)
        };
        foreach (int size in new[] { 40, 45, 44, 17, 49, 47, 46, 74, 192, 54, 44 })
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, size));
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
        var scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true };
        scroll.Controls.Add(layout);
        Controls.Add(scroll);

        Shown += (_, _) => Run(CheckModelAsync);
        download.Click += (_, _) =>
        {
            if (downloadStop is { } active)
            {
                active.Cancel();
                UpdateControls();
            }
            else Run(DownloadAsync);
        };
        toggle.Click += (_, _) =>
        {
            if (server is null) Run(StartAsync);
            else Run(() => StopAsync("Server stopped"));
        };
        hotspot.Click += (_, _) =>
        {
            try
            {
                Process.Start(new ProcessStartInfo("ms-settings:network-mobilehotspot") { UseShellExecute = true })?.Dispose();
            }
            catch (Exception error) { serviceStatus.Text = $"Open Mobile Hotspot in Windows Settings. {error.Message}"; }
        };
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
        busy = true;
        UpdateControls();
        try
        {
            if (!model.LooksDownloaded) return;
            modelStatus.Text = "Checking the downloaded model…";
            verified = await Task.Run(() => model.VerifyAsync(lifetime.Token), lifetime.Token);
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
            await Task.Run(() => model.DownloadAsync(report, operation.Token), operation.Token);
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
        LayerWorker? worker = null;
        Bitmap? pairingImage = null;
        try
        {
            if (!model.LooksDownloaded)
            {
                verified = false;
                progress.Value = 0;
                modelStatus.Text = "The model file is missing or incomplete. Download it again.";
                serviceStatus.Text = "Server stopped";
                return;
            }
            var network = await Task.Run(() => Hotspot.WaitAsync(lifetime.Token), lifetime.Token);
            lifetime.Token.ThrowIfCancellationRequested();
            serviceStatus.Text = "Starting the Qwen worker…";
            worker = new LayerWorker(model.FilePath);
            await Task.Run(() => worker.ProbeAsync(lifetime.Token), lifetime.Token);
            network = await Task.Run(() => Hotspot.Read(network), lifetime.Token);
            lifetime.Token.ThrowIfCancellationRequested();
            identity = new PairingIdentity(DataDirectory);
            var newCode = identity.Code(network);
            using var qrData = QRCodeGenerator.GenerateQrCode(newCode, QRCodeGenerator.ECCLevel.M);
            var png = new PngByteQRCode(qrData).GetGraphic(6);
            using var stream = new MemoryStream(png);
            using var image = Image.FromStream(stream);
            pairingImage = new Bitmap(image);

            var owner = new object();
            server = new ComputeServer(network, identity, worker,
                message => Post(() => { if (ReferenceEquals(session, owner)) serviceStatus.Text = message; }),
                message => Post(() => { if (ReferenceEquals(session, owner)) Run(() => StopAsync(message)); }));
            session = owner;
            identity = null;
            worker = null;
            code = newCode;
            qr.Image = pairingImage;
            pairingImage = null;
            pairing.Text = $"Join “{network.Name}” on the iPad and scan this code in Models & context.";
            serviceStatus.Text = $"Ready on 5 GHz at {network.Address}. Allow the app through Windows Firewall if prompted.";
        }
        catch (OperationCanceledException) { }
        catch (SocketException error) when (error.SocketErrorCode == SocketError.AddressAlreadyInUse)
        {
            serviceStatus.Text = $"Port {ComputeServer.Port} is already in use. Close the other server and try again.";
        }
        catch (Exception error) { serviceStatus.Text = error.Message; }
        finally
        {
            identity?.Dispose();
            if (worker is not null) await Task.Run(worker.Dispose);
            pairingImage?.Dispose();
            busy = false;
            UpdateControls();
        }
    }

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
        catch (Exception error) { serviceStatus.Text = error.Message; }
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

    private void Run(Func<Task> action)
    {
        if (!closing && operation is not { IsCompleted: false }) operation = action();
    }

    private void UpdateControls()
    {
        if (closing) return;
        download.Text = downloadStop is null ? (verified ? "Model downloaded" : "Download model") : "Pause download";
        download.Enabled = !busy && !verified && server is null && downloadStop?.IsCancellationRequested != true;
        toggle.Text = server is null ? "Start server" : "Stop server";
        toggle.Enabled = !busy && verified;
        copy.Enabled = code is not null;
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        base.OnFormClosing(e);
        if (e.Cancel || readyToClose) return;
        e.Cancel = true;
        if (closing) return;
        closing = true;
        Enabled = false;
        lifetime.Cancel();
        _ = FinishClosingAsync();
    }

    private async Task FinishClosingAsync()
    {
        await Task.Yield();
        if (operation is { } pending) await pending;
        await StopAsync("Server stopped");
        lifetime.Dispose();
        readyToClose = true;
        Close();
    }
}
