import plistlib
import stat
import struct
import sys
from zipfile import ZipFile


def verify_ios_binary(ipa, path, executable=False, expected_entitlements=None):
    info = ipa.getinfo(path)
    assert info.file_size > 0
    assert not executable or (info.external_attr >> 16) & stat.S_IXUSR
    with ipa.open(info) as binary:
        magic, cpu, _, file_type, commands, _, _, _ = struct.unpack("<8I", binary.read(32))
        assert magic == 0xFEEDFACF and cpu == 0x0100000C, path
        assert file_type == (2 if executable else 6), path
        platform = None
        signature = None
        for _ in range(commands):
            command, size = struct.unpack("<2I", binary.read(8))
            assert size >= 8
            data = binary.read(size - 8)
            if command == 0x1D:
                signature = struct.unpack("<2I", data)
            if command == 0x32:
                platform = struct.unpack_from("<I", data)[0]
            if command == 0x25:
                platform = 2
        assert platform == 2, f"{path} is not built for an iOS device"
        if expected_entitlements is None:
            assert signature is None, f"{path} contains a code signature"
        else:
            assert signature is not None
            offset, length = signature
            binary.seek(offset)
            blob = binary.read(length)
            magic, size, count = struct.unpack_from(">3I", blob)
            assert magic == 0xFADE0CC0 and size <= length
            slots = dict(struct.unpack_from(">2I", blob, 12 + 8 * i) for i in range(count))
            if 0x10000 in slots:
                # Apple codesign may emit an empty CMS wrapper for an ad-hoc signature.
                assert struct.unpack_from(">2I", blob, slots[0x10000]) == (0xFADE0B01, 8)
            start = slots[5]
            magic, size = struct.unpack_from(">2I", blob, start)
            assert magic == 0xFADE7171
            assert plistlib.loads(blob[start + 8:start + size]) == expected_entitlements


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
    impactor = "--impactor" in sys.argv[2:]
    verify_ios_binary(ipa, app + info["CFBundleExecutable"], executable=True,
                      expected_entitlements=entitlements if impactor else None)
    verify_ios_binary(ipa, app + "Frameworks/llama.framework/llama")
    print(f"Verified {'an Impactor-prepared' if impactor else 'an unsigned'} ARM64 iPad app and both memory requests.")
