import plistlib
import stat
import struct
import sys
from zipfile import ZipFile


def verify_ios_binary(ipa, path, executable=False):
    info = ipa.getinfo(path)
    assert info.file_size > 0
    assert not executable or (info.external_attr >> 16) & stat.S_IXUSR
    with ipa.open(info) as binary:
        magic, cpu, _, file_type, commands, _, _, _ = struct.unpack("<8I", binary.read(32))
        assert magic == 0xFEEDFACF and cpu == 0x0100000C, path
        assert file_type == (2 if executable else 6), path
        platform = None
        for _ in range(commands):
            command, size = struct.unpack("<2I", binary.read(8))
            assert size >= 8
            data = binary.read(size - 8)
            assert command != 0x1D, f"{path} contains a code signature"
            if command == 0x32:
                platform = struct.unpack_from("<I", data)[0]
            if command == 0x25:
                platform = 2
        assert platform == 2, f"{path} is not built for an iOS device"


with ZipFile(sys.argv[1]) as ipa:
    assert ipa.testzip() is None
    names = ipa.namelist()
    app = "Payload/NethLocal.app/"
    assert not any("/_CodeSignature/" in name or name.endswith(".mobileprovision") for name in names)
    info = plistlib.loads(ipa.read(app + "Info.plist"))
    assert info["UIDeviceFamily"] == [2]
    assert info["MinimumOSVersion"] == "18.0"
    entitlements = plistlib.loads(ipa.read(app + "NethLocal.entitlements"))
    assert entitlements["com.apple.developer.kernel.increased-memory-limit"] is True
    assert entitlements["com.apple.developer.kernel.extended-virtual-addressing"] is True
    verify_ios_binary(ipa, app + info["CFBundleExecutable"], executable=True)
    verify_ios_binary(ipa, app + "Frameworks/llama.framework/llama")
    print("Verified an unsigned iPad arm64 app with both signing entitlement requests.")
