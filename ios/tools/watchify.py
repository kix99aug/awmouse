"""Build a watchOS slice of the Go tunnel from the iOS one gomobile produced.

Go has no watchOS port. It does have darwin/arm64, and a modern Apple Watch is
arm64 — the same instruction set, the same kernel, the same libSystem. What
stops the linker is not the code but a label: every object carries an
LC_BUILD_VERSION saying "iOS", and ld refuses to mix platforms. The label is a
fixed-size integer in a fixed-size load command, so correcting it moves
nothing. vtool will not do it, because vtool rewrites the load commands
wholesale and an object file has no slack after them; a byte edit does.

One call then has to be taken away. watchOS traps inside libsystem's sigaction
rather than returning an error, and the Go runtime calls it in initsig, before
any of our code runs. The import is renamed here to awsigactn, which
watch/sigshim.c defines as a no-op, and the runtime comes up without handlers.

This is unsupported by anyone. It is also the only way the watch reaches the
host without the phone in the middle, which is the whole point of the watch
app. Re-run it after every `make tunnel`; the Makefile does.
"""
import plistlib, shutil, struct, subprocess, sys
from pathlib import Path

FAT_MAGIC = 0xCAFEBABE
MH_MAGIC_64 = 0xFEEDFACF
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
PLATFORM_WATCHOS = 4

# Renamed, not removed: the Go archive's import table is fixed-width, so the
# replacement has to be exactly as long as the original.
OLD_SYM, NEW_SYM = b"_sigaction\x00", b"_awsigactn\x00"
assert len(OLD_SYM) == len(NEW_SYM)


def version(major, minor=0, patch=0):
    return (major << 16) | (minor << 8) | patch


def archives(data):
    """Yield the bounds of each ar archive in the file. gomobile wraps even a
    single-architecture static library in a fat header, so the archive rarely
    starts at byte zero."""
    if struct.unpack_from(">I", data, 0)[0] != FAT_MAGIC:
        yield 0, len(data)
        return
    for i in range(struct.unpack_from(">I", data, 4)[0]):
        off, size = struct.unpack_from(">II", data, 8 + i * 20 + 8)
        yield off, off + size


def members(data, base, limit):
    """Yield each ar member's payload bounds. BSD ar puts long names in the
    payload itself and counts them in the size, hence the #1/ handling."""
    off = base + 8  # "!<arch>\n"
    while off + 60 <= limit:
        name = bytes(data[off:off + 16]).rstrip()
        size = int(bytes(data[off + 48:off + 58]).strip() or 0)
        start, end = off + 60, off + 60 + size
        if name.startswith(b"#1/"):
            start += int(name[3:])
        yield start, end
        off = end + (end & 1)  # members are two-byte aligned


def retarget(data, start, minos, sdk):
    if struct.unpack_from("<I", data, start)[0] != MH_MAGIC_64:
        return 0
    ncmds = struct.unpack_from("<I", data, start + 16)[0]
    off, changed = start + 32, 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == LC_BUILD_VERSION:
            struct.pack_into("<III", data, off + 8, PLATFORM_WATCHOS, minos, sdk)
            changed += 1
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            # The older form has no platform field and is smaller than the
            # command it would become, so it cannot be fixed in place. Refuse
            # rather than corrupt the object.
            raise SystemExit(f"object at {start} uses LC_VERSION_MIN_IPHONEOS")
        off += cmdsize
    return changed


def rename_sigaction(data):
    """Patch the string table entries for _sigaction. A match is only a symbol
    name where a NUL precedes it, which is what keeps this off ___sigaction and
    off any longer name that happens to end the same way."""
    n, i = 0, 0
    while (i := data.find(OLD_SYM, i)) >= 0:
        if i > 0 and data[i - 1] == 0:
            data[i:i + len(NEW_SYM)] = NEW_SYM
            n += 1
        i += 1
    return n


def main(xcframework, watch_min, watch_sdk):
    xc = Path(xcframework)
    ios = xc / "ios-arm64" / "Awmtunnel.framework"
    if not ios.is_dir():
        raise SystemExit(f"no ios-arm64 slice in {xc}")
    if (xc / "watchos-arm64").is_dir():
        print("watchos-arm64 slice already present")
        return

    staged = xc.parent / "watchify-staging"
    shutil.rmtree(staged, ignore_errors=True)
    staged.mkdir(parents=True)
    watch = staged / "Awmtunnel.framework"
    # Headers and the module map describe the same Go API either way; only the
    # compiled code carries a platform.
    shutil.copytree(ios, watch, symlinks=True)

    binary = watch / "Awmtunnel"
    data = bytearray(binary.read_bytes())
    objects = sum(
        1
        for base, limit in archives(data)
        for s, _ in members(data, base, limit)
        if retarget(data, s, watch_min, watch_sdk))
    if objects == 0:
        raise SystemExit("no Mach-O objects retargeted — archive layout not understood")
    renamed = rename_sigaction(data)
    binary.write_bytes(data)
    if renamed != 1:
        raise SystemExit(f"expected one _sigaction import, renamed {renamed}")
    print(f"retargeted {objects} objects, renamed {renamed} import")

    info = watch / "Info.plist"
    if info.exists():
        plist = plistlib.loads(info.read_bytes())
        plist["MinimumOSVersion"] = "10.0"
        plist["CFBundleSupportedPlatforms"] = ["WatchOS"]
        info.write_bytes(plistlib.dumps(plist))

    # create-xcframework reads the platform back out of the binary, so the
    # patch above is also what makes this call accept the slice.
    # Every slice gomobile produced is carried over, not just the device one:
    # dropping the simulator slice would break building for it.
    existing = sorted(p / "Awmtunnel.framework" for p in xc.iterdir() if p.is_dir())
    rebuilt = staged / "Awmtunnel.xcframework"
    args = []
    for f in existing + [watch]:
        args += ["-framework", str(f)]
    subprocess.run(
        ["xcodebuild", "-create-xcframework", *args, "-output", str(rebuilt)],
        check=True, stdout=subprocess.DEVNULL)

    shutil.rmtree(xc)
    shutil.move(str(rebuilt), str(xc))
    shutil.rmtree(staged, ignore_errors=True)
    print(f"{xc} now has: " + ", ".join(sorted(p.name for p in xc.iterdir() if p.is_dir())))


if __name__ == "__main__":
    main(sys.argv[1], version(10), version(27))
