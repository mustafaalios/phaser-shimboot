#!/usr/bin/env python3
"""Print the Linux version inside the signed kernel (KERN-A) of RMA shims, without downloading whole images.

Usage: probe_shim_kernels.py board [board ...]
Streams only the first chunks of each shim from cdn.cros.download, decompresses the zip on the fly,
reads the GPT, and pulls the version string out of the kernel's bzImage setup header.
"""
import json
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


def kernel_version(partition):
    pos = partition.find(b"HdrS")
    if pos < 0x202:
        return "no x86 bzImage found (arm board?)"
    start = pos - 0x202
    offset = struct.unpack_from("<H", partition, start + 0x20E)[0]
    end = partition.index(b"\0", start + offset + 0x200)
    return partition[start + offset + 0x200:end].decode(errors="replace")


def main():
    boards_index = fetch(BASE + "boards.txt").decode().split()
    for board in sys.argv[1:]:
        try:
            print("%-10s %s" % (board, kernel_version(stream_shim(board, boards_index))), flush=True)
        except Exception as error:
            print("%-10s ERROR: %s" % (board, error), flush=True)


main()
