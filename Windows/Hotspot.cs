using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using Windows.Networking.Connectivity;
using Windows.Networking.NetworkOperators;

namespace NethLocal;

internal sealed record Hotspot(IPAddress Address, IPAddress Mask, int InterfaceIndex, string Name)
{
    public static Hotspot Read()
    {
        var profile = NetworkInformation.GetInternetConnectionProfile()
            ?? throw new InvalidOperationException("Connect Windows to the internet, then enable Mobile Hotspot.");
        var manager = NetworkOperatorTetheringManager.CreateFromConnectionProfile(profile);
        if (manager.TetheringOperationalState != TetheringOperationalState.On)
            throw new InvalidOperationException("Turn on Windows Mobile Hotspot first.");
        var settings = manager.GetCurrentAccessPointConfiguration();
        if (settings.Band != TetheringWiFiBand.FiveGigahertz)
            throw new InvalidOperationException("Set the Mobile Hotspot Network band to 5 GHz. The server requires that setting.");

        var interfaces = NetworkInterface.GetAllNetworkInterfaces()
            .Where(adapter => adapter.OperationalStatus == OperationalStatus.Up &&
                adapter.Description.Contains("Wi-Fi Direct Virtual Adapter", StringComparison.OrdinalIgnoreCase));
        var candidates = new List<Hotspot>();
        foreach (var adapter in interfaces)
        {
            var properties = adapter.GetIPProperties();
            var ipv4 = properties.GetIPv4Properties();
            if (ipv4 is null) continue;
            foreach (var address in properties.UnicastAddresses)
            {
                if (IsPrivate(address.Address))
                    candidates.Add(new Hotspot(address.Address, address.IPv4Mask, ipv4.Index, settings.Ssid));
            }
        }
        if (candidates.Count == 1) return candidates[0];
        var standard = candidates.Where(candidate => candidate.Address.Equals(IPAddress.Parse("192.168.137.1"))).ToArray();
        if (standard.Length == 1) return standard[0];
        throw new InvalidOperationException("Windows did not expose a unique Mobile Hotspot adapter. Restart the hotspot and try again.");
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
}
