#!/usr/bin/env python3
"""Self-test the image variant tool, including a synthetic SquashFS image."""

from __future__ import annotations

import gzip
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
PYTHON = sys.executable


def run(args: list[str]) -> None:
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(result.stdout, end="")
    if result.returncode:
        raise RuntimeError(f"failed: {' '.join(args)}")


def make_mbr(payload_size: int) -> bytes:
    sectors = (payload_size + 511) // 512
    raw = bytearray(45056 + sectors * 512)
    raw[510:512] = b"\x55\xaa"
    entry = bytearray(16)
    entry[4] = 0x83
    struct.pack_into("<I", entry, 8, 88)
    struct.pack_into("<I", entry, 12, sectors)
    raw[446:462] = entry
    return bytes(raw)


def main() -> int:
    scratch = HERE / ".variant-selftest"
    scratch.mkdir(parents=True, exist_ok=True)
    temp_name = tempfile.mkdtemp(prefix="run-", dir=scratch)
    try:
        temp = Path(temp_name)
        root = temp / "source"
        (root / "etc").mkdir(parents=True)
        (root / "etc/wifi-watchdog.mode").write_text("recover\n", encoding="utf-8")
        (root / "etc/keep").write_text("unchanged\n", encoding="utf-8")
        mksquashfs = shutil.which("mksquashfs") or shutil.which("mksquashfs4")
        if not mksquashfs:
            raise RuntimeError("mksquashfs is required for the runner self-test")
        partition = temp / "rootfs.squashfs"
        run([mksquashfs, str(root), str(partition), "-noappend", "-all-root", "-no-xattrs", "-comp", "xz"])
        raw = bytearray(make_mbr(partition.stat().st_size))
        start = 88 * 512
        raw[start : start + partition.stat().st_size] = partition.read_bytes()
        image = temp / "base.img.gz"
        with image.open("wb") as stream:
            with gzip.GzipFile(fileobj=stream, mode="wb", mtime=0) as compressed:
                compressed.write(raw)
        output = temp / "observe.img.gz"
        report = temp / "make.md"
        run([PYTHON, str(HERE / "make_variant.py"), "make", "--base", str(image), "--output", str(output), "--mode", "observe", "--report", str(report)])
        run([PYTHON, str(HERE / "make_variant.py"), "verify", "--base", str(image), "--compare", str(output), "--report", str(temp / "verify.md")])
        run([PYTHON, str(HERE / "make_variant.py"), "diff", "--base", str(image), "--compare", str(output), "--report", str(temp / "diff.md")])
        print("SELFTEST=PASS")
    finally:
        shutil.rmtree(temp_name, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
