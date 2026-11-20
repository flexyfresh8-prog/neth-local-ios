using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using Windows.Networking.Connectivity;
using Windows.Networking.NetworkOperators;

namespace NethLocal;

internal sealed record Hotspot(IPAddress Address, IPAddress Mask, int InterfaceIndex, string Name)
{
    private static readonly IPAddress DefaultAddress = IPAddress.Parse("192.168.137.1");

    public static async Task<Hotspot> WaitAsync(CancellationToken stop)
    {
        for (int attempt = 0; ; attempt++)
        {
            stop.ThrowIfCancellationRequested();
            try { return Read(); }
            catch (HotspotNotReady) when (attempt < 6)
            {
                await Task.Delay(700, stop).ConfigureAwait(false);
            }
        }
    }

    public static Hotspot Read(Hotspot? current = null)
    {
        var (manager, name, uplink) = ActiveHotspot();
        var direct = new List<Hotspot>();
        var peers = new List<Hotspot>();
        IPAddress[] clients = ClientAddresses(manager);
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (adapter.OperationalStatus is not (OperationalStatus.Up or OperationalStatus.Dormant) ||
                adapter.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel ||
                (Guid.TryParse(adapter.Id, out var id) && id == uplink)) continue;

            var properties = adapter.GetIPProperties();
            var ipv4 = properties.GetIPv4Properties();
            if (ipv4 is null || properties.GatewayAddresses.Any(gateway =>
                gateway.Address.AddressFamily == AddressFamily.InterNetwork &&
                !gateway.Address.Equals(IPAddress.Any))) continue;

            foreach (var unicast in properties.UnicastAddresses)
            {
                if (!IsPrivate(unicast.Address)) continue;
                var candidate = new Hotspot(unicast.Address, unicast.IPv4Mask, ipv4.Index, name);
                if (candidate == current) return candidate;
                if (adapter.Description.Contains("Wi-Fi Direct", StringComparison.OrdinalIgnoreCase)) direct.Add(candidate);
                if (clients.Any(candidate.Accepts)) peers.Add(candidate);
            }
        }

        // The route to an associated hotspot client identifies the private
        // interface even if its driver description is localized.
        if (peers.Count == 1) return peers[0];
        if (direct.Count == 1) return direct[0];
        var standard = direct.Where(candidate => candidate.Address.Equals(DefaultAddress)).ToArray();
        if (standard.Length == 1) return standard[0];
        throw new HotspotNotReady("Windows verified 5 GHz but hasn’t exposed a hotspot address yet. Join the laptop’s hotspot on the iPad, then click Start server again.");
    }

    private static (NetworkOperatorTetheringManager manager, string name, Guid? uplink) ActiveHotspot()
    {
        var primary = NetworkInformation.GetInternetConnectionProfile();
        var profiles = new List<ConnectionProfile>();
        if (primary is not null) profiles.Add(primary);
        profiles.AddRange(NetworkInformation.GetConnectionProfiles());
        TetheringWiFiBand? reportedBand = null;
        Exception? profileError = null;
        bool transitioning = false;
        foreach (var profile in profiles.DistinctBy(item => item.NetworkAdapter?.NetworkAdapterId))
        {
            try
            {
                var manager = NetworkOperatorTetheringManager.CreateFromConnectionProfile(profile);
                var state = manager.TetheringOperationalState;
                if (state == TetheringOperationalState.InTransition) transitioning = true;
                if (state != TetheringOperationalState.On) continue;
                var settings = manager.GetCurrentAccessPointConfiguration();
                if (settings.Band == TetheringWiFiBand.FiveGigahertz)
                    return (manager, settings.Ssid, profile.NetworkAdapter?.NetworkAdapterId);
                reportedBand = settings.Band;
            }
            catch (Exception error) when (error is COMException or UnauthorizedAccessException or ArgumentException)
            {
                profileError = error;
            }
        }
        if (reportedBand is { } band)
        {
            var label = band switch
            {
                TetheringWiFiBand.Auto => "Any available",
                TetheringWiFiBand.TwoPointFourGigahertz => "2.4 GHz",
                _ => band.ToString()
            };
            throw new InvalidOperationException($"Windows reports the hotspot band as {label}. Turn Mobile Hotspot off, set Network band to 5 GHz, then turn it back on.");
        }
        if (transitioning) throw new HotspotNotReady("Windows is starting the hotspot. Wait for it to finish, then try again.");
        if (profileError is not null)
            throw new InvalidOperationException($"Windows could not read the Mobile Hotspot state (0x{profileError.HResult:X8}). Check that Mobile Hotspot is on and Share over is set to Wi-Fi.", profileError);
        throw new HotspotNotReady("Turn on Windows Mobile Hotspot with Share over set to Wi-Fi and Network band set to 5 GHz.");
    }

    private static IPAddress[] ClientAddresses(NetworkOperatorTetheringManager manager)
    {
        try
        {
            return manager.GetTetheringClients().SelectMany(client => client.HostNames)
                .Select(host => IPAddress.TryParse(host.RawName, out var address) && IsPrivate(address) ? address : null)
                .OfType<IPAddress>().Distinct().ToArray();
        }
        catch (Exception error) when (error is COMException or UnauthorizedAccessException)
        {
            // Windows may not expose client addresses before the first association.
            return [];
        }
    }

    public bool Accepts(IPAddress address)
    {
        if (!IsPrivate(address) || address.Equals(Address)) return false;
        var client = address.GetAddressBytes();
        var server = Address.GetAddressBytes();
        var mask = Mask.GetAddressBytes();
        for (int i = 0; i < client.Length; i++)
        {
            if ((client[i] & mask[i]) != (server[i] & mask[i])) return false;
        }
        return GetBestInterface(BitConverter.ToUInt32(client), out uint route) == 0 && route == InterfaceIndex;
    }

    private static bool IsPrivate(IPAddress address)
    {
        if (address.AddressFamily != AddressFamily.InterNetwork) return false;
        byte[] ip = address.GetAddressBytes();
        return ip[0] == 10 || (ip[0] == 172 && ip[1] is >= 16 and <= 31) || (ip[0] == 192 && ip[1] == 168);
    }

    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    private static extern uint GetBestInterface(uint destination, out uint bestInterfaceIndex);

    private sealed class HotspotNotReady(string reason) : InvalidOperationException(reason);
}
