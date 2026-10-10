#!/usr/bin/env python3
"""Print the Linux version inside the signed kernel (KERN-A) of RMA shims, without downloading whole images.

Usage: probe_shim_kernels.py board [board ...]
Streams only the first chunks of each shim from cdn.cros.download, decompresses the zip on the fly,
reads the GPT, and pulls the version string out of the kernel's bzImage setup header.
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


def kernel_version(partition):
    """The signed kernel blob holds the compressed kernel near its start. Try every compressed stream we can find
    and read the 'Linux version' string out of whichever one decompresses to a kernel."""
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
            found = re.search(rb"Linux version [ -~]+", data or b"")
            if found:
                return "%s  [%s at %#x]" % (found.group(0).decode(), name, match.start())
        if tried:
            notes.append("%s: %d candidates, none was a kernel" % (name, tried))
    return "no version found [%s]" % "; ".join(notes)


def main():
    boards_index = fetch(BASE + "boards.txt").decode().split()
    for board in sys.argv[1:]:
        try:
            print("%-10s %s" % (board, kernel_version(stream_shim(board, boards_index))), flush=True)
        except Exception as error:
            print("%-10s ERROR: %s" % (board, error), flush=True)


main()
