#!/usr/bin/env python3
"""Print the Linux version inside the signed kernel (KERN-A) of RMA shims, without downloading whole images.

Usage: probe_shim_kernels.py [--config] board [board ...]
Streams only the first chunks of each shim from cdn.cros.download, decompresses the zip on the fly,
reads the GPT, and pulls the version string out of the kernel's bzImage setup header.
With --config, also decompresses the kernel's embedded .config (CONFIG_IKCONFIG) and prints the
flags that decide whether a self-built out-of-tree kexec module could load and run on that shim
(module signing enforcement, LoadPin, MODVERSIONS, kallsyms, kexec).
"""
import bz2
import json
import lzma
import re
import struct
import sys
import urllib.request
import zlib

BASE = "https://cdn.cros.download/"


def fetch(url):
    #the cdn rejects python's default user agent, curl and wget are fine
    request = urllib.request.Request(url, headers={"User-Agent": "curl/8.5.0"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def stream_shim(board, boards_index):
    lines = [line for line in boards_index if "/%s/" % board in line]
    if not lines:
        raise RuntimeError("not in boards.txt")
    manifest_path = lines[0] + ".manifest"
    directory = manifest_path.rsplit("/", 1)[0]
    manifest = json.loads(fetch(BASE + manifest_path))

    raw = bytearray()
    decomp = None
    buf = b""
    needed = 4 * 1024 * 1024
    for chunk in manifest["chunks"]:
        buf += fetch("%s%s/%s" % (BASE, directory, chunk))
        if decomp is None:
            if buf[:4] != b"PK\x03\x04":
                raise RuntimeError("shim is not a zip")
            method = struct.unpack_from("<H", buf, 8)[0]
            name_len, extra_len = struct.unpack_from("<HH", buf, 26)
            buf = buf[30 + name_len + extra_len:]
            decomp = zlib.decompressobj(-15) if method == 8 else None
        raw += decomp.decompress(buf) if decomp else buf
        buf = b""
        if len(raw) >= 1024 * 1024 and needed == 4 * 1024 * 1024:
            # read the GPT to learn how far the kernel partition extends
            entries_lba = struct.unpack_from("<Q", raw, 512 + 72)[0]
            entry_size = struct.unpack_from("<I", raw, 512 + 84)[0]
            first, last = struct.unpack_from("<QQ", raw, entries_lba * 512 + entry_size + 32)
            needed = (last + 1) * 512
            start = first * 512
        if len(raw) >= needed and needed != 4 * 1024 * 1024:
            return bytes(raw[start:needed])
    raise RuntimeError("ran out of chunks before the kernel partition ended")


def lz4_legacy(data, limit):
    import lz4.block
    out = bytearray()
    i = 4
    while i + 4 <= len(data) and len(out) < limit:
        size = struct.unpack_from("<I", data, i)[0]
        i += 4
        if size == 0 or size > len(data) - i:
            break
        try:
            out += lz4.block.decompress(data[i:i + size], uncompressed_size=8 << 20)
        except Exception:
            break
        i += size
    return bytes(out)


def zstd_stream(data, limit):
    import zstandard
    return zstandard.ZstdDecompressor().decompressobj().decompress(data[:limit])


# magic -> (name, function(data, limit) -> bytes)
FORMATS = [
    (rb"\x1f\x8b\x08", "gzip", lambda d, n: zlib.decompressobj(31).decompress(d, n)),
    (rb"\xfd7zXZ\x00", "xz", lambda d, n: lzma.LZMADecompressor(lzma.FORMAT_XZ).decompress(d, n)),
    (rb"\x5d\x00\x00[\x00-\xff]{2}[\x00-\xff]{8}", "lzma", lambda d, n: lzma.LZMADecompressor(lzma.FORMAT_ALONE).decompress(d, n)),
    (rb"BZh[1-9]1AY&SY", "bzip2", lambda d, n: bz2.BZ2Decompressor().decompress(d, n)),
    (rb"\x02\x21\x4c\x18", "lz4", lz4_legacy),
    (rb"\x28\xb5\x2f\xfd", "zstd", zstd_stream),
]


def decompress_kernel(partition):
    """The signed kernel blob holds the compressed kernel near its start. Try every compressed stream we can find
    and return the bytes of whichever one decompresses to a kernel (it contains the 'Linux version' string)."""
    limit = 160 * 1024 * 1024
    notes = []
    for magic, name, function in FORMATS:
        tried = 0
        for match in re.finditer(magic, partition, re.S):
            tried += 1
            if tried > 200:
                break
            try:
                data = function(partition[match.start():match.start() + 96 * 1024 * 1024], limit)
            except ImportError as error:
                notes.append("%s: missing python module (%s)" % (name, error))
                break
            except Exception:
                continue
            if re.search(rb"Linux version [ -~]+", data or b""):
                return data, "%s at %#x" % (name, match.start())
        if tried:
            notes.append("%s: %d candidates, none was a kernel" % (name, tried))
    return None, "no kernel found [%s]" % "; ".join(notes)


def kernel_version(data, note):
    found = re.search(rb"Linux version [ -~]+", data or b"")
    return "%s  [%s]" % (found.group(0).decode(), note) if found else "no version found [%s]" % note


#config options worth reporting: the ones that decide whether a self-built kexec module can load and run.
CONFIG_KEYS = [
    "MODULE_SIG", "MODULE_SIG_FORCE", "MODULE_SIG_ALL", "MODVERSIONS",
    "SECURITY_LOADPIN", "MODULE_SIG_KEY",
    "KALLSYMS", "KALLSYMS_ALL", "KEXEC", "KEXEC_CORE", "KEXEC_FILE",
    "RELOCATABLE", "RANDOMIZE_BASE", "STRICT_KERNEL_RWX", "STRICT_MODULE_RWX",
    "LOCALVERSION", "DEBUG_INFO",
]


def extract_config(data):
    """ChromeOS kernels embed their .config (CONFIG_IKCONFIG). It sits gzip-compressed in the decompressed
    kernel image between the markers 'IKCFG_ST' and 'IKCFG_ED'. Return the config text, or None if absent."""
    if not data:
        return None
    start = data.find(b"IKCFG_ST")
    if start < 0:
        return None
    start += len(b"IKCFG_ST")
    try:
        return zlib.decompressobj(31).decompress(data[start:start + 8 * 1024 * 1024]).decode("utf-8", "replace")
    except Exception:
        return None


def report_config(config):
    if config is None:
        return "    config: not embedded (CONFIG_IKCONFIG off), cannot read flags offline"
    values = {}
    for line in config.splitlines():
        line = line.strip()
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            values[key[len("CONFIG_"):]] = value
        elif line.startswith("# CONFIG_") and line.endswith(" is not set"):
            values[line[len("# CONFIG_"):-len(" is not set")]] = "n"
    lines = []
    for key in CONFIG_KEYS:
        lines.append("    CONFIG_%-20s %s" % (key, values.get(key, "(absent)")))
    return "\n".join(lines)


def main():
    want_config = "--config" in sys.argv[1:]
    boards = [a for a in sys.argv[1:] if a != "--config"]
    boards_index = fetch(BASE + "boards.txt").decode().split()
    for board in boards:
        try:
            data, note = decompress_kernel(stream_shim(board, boards_index))
            print("%-10s %s" % (board, kernel_version(data, note)), flush=True)
            if want_config:
                print(report_config(extract_config(data)), flush=True)
        except Exception as error:
            print("%-10s ERROR: %s" % (board, error), flush=True)


main()
