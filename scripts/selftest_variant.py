#!/usr/bin/env python3
"""Exercise image variant creation and all required negative controls."""

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
TOOL = HERE / "make_variant.py"
SECTOR = 512
ROOT_START = 4096
ROOT_SECTORS = 65536
SPARSE_ROOT_START = 45056
SPARSE_ROOT_SECTORS = 2097152
SQUASHFS_TAIL = b"\0" * 8 + b'{"metadata_version":"test"}\nFWx0-test-footer'


def invoke(args: list[str], *, ok: bool) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(result.stdout, end="")
    if (result.returncode == 0) != ok:
        raise RuntimeError(f"unexpected exit {result.returncode}: {' '.join(args)}")
    return result


def pack(raw: bytes, path: Path) -> None:
    with path.open("wb") as stream:
        with gzip.GzipFile(fileobj=stream, mode="wb", mtime=0, compresslevel=9) as zipped:
            zipped.write(raw)


def make_mbr(raw: bytearray, root_start: int, root_sectors: int, boot_start: int, boot_sectors: int) -> None:
    raw[510:512] = b"\x55\xaa"
    raw[446:510] = bytes(64)
    for offset, ptype, start, count in ((446, 0x83, boot_start, boot_sectors),
                                        (462, 0x83, root_start, root_sectors)):
        raw[offset + 4] = ptype
        struct.pack_into("<II", raw, offset + 8, start, count)


def verify(args: list[str], should_pass: bool, label: str) -> None:
    invoke([sys.executable, str(TOOL), *args], ok=should_pass)
    if should_pass:
        print(f"SELFTEST_{label}=PASS")
    else:
        print(f"NEGATIVE_{label}=DETECTED")


def build_root_partition(source: Path, image: Path) -> None:
    with image.open("wb") as stream:
        stream.truncate(ROOT_SECTORS * SECTOR)
    run = subprocess.run([shutil.which("mke2fs") or "mke2fs", "-q", "-t", "ext4", "-F", "-d",
                          str(source), str(image)], stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT, text=True)
    if run.returncode:
        raise RuntimeError(run.stdout)


def synthetic_image(root_partition: bytes, path: Path, padding_byte: bytes = b"\0") -> None:
    total = (ROOT_START + ROOT_SECTORS) * SECTOR
    raw = bytearray(os.urandom(total))
    make_mbr(raw, ROOT_START, ROOT_SECTORS, 2048, 1024)
    start = ROOT_START * SECTOR
    if len(root_partition) > ROOT_SECTORS * SECTOR:
        raise RuntimeError("synthetic rootfs exceeds its partition")
    raw[start:start + ROOT_SECTORS * SECTOR] = padding_byte * (ROOT_SECTORS * SECTOR)
    raw[start:start + len(root_partition)] = root_partition
    pack(raw, path)


def sparse_squashfs_image(root_partition: bytes, path: Path, tail: bytes) -> None:
    start = SPARSE_ROOT_START * SECTOR
    raw = bytearray(start + len(root_partition) + len(tail))
    make_mbr(raw, SPARSE_ROOT_START, SPARSE_ROOT_SECTORS, 2048, 40960)
    raw[start:start + len(root_partition)] = root_partition
    raw[start + len(root_partition):] = tail
    pack(bytes(raw), path)


def main() -> int:
    for name in ("debugfs", "e2fsck", "mke2fs", "gzip", "mksquashfs", "unsquashfs"):
        if not shutil.which(name):
            raise RuntimeError(f"required selftest tool missing: {name}")
    with tempfile.TemporaryDirectory(prefix="variant-selftest-") as temporary:
        work = Path(temporary)
        source = work / "root"
        (source / "etc").mkdir(parents=True)
        (source / "lib/apk/db").mkdir(parents=True)
        (source / "etc/openwrt_release").write_text("DISTRIB_ID='OpenWrt'\n")
        (source / "etc/wifi-watchdog.mode").write_text("recover\n")
        (source / "etc/keep").write_text("stable\n")
        (source / "lib/apk/db/installed").write_text("P:synthetic\nV:1\n")
        ext = work / "rootfs.ext4"
        build_root_partition(source, ext)
        base = work / "base.img.gz"
        synthetic_image(ext.read_bytes(), base)
        output = work / "observe.img.gz"
        make_report = work / "make.md"
        arguments = ["make", "--base", str(base), "--output", str(output), "--target",
                     "/etc/wifi-watchdog.mode", "--old-content", "recover", "--new-content", "observe",
                     "--report", str(make_report)]
        verify(arguments, True, "MAKE")
        if "Verdict: PASS" not in make_report.read_text():
            raise RuntimeError("make report did not contain PASS")
        verify(["verify", "--base", str(base), "--compare", str(output), "--target",
                "/etc/wifi-watchdog.mode", "--old-content", "recover", "--new-content", "observe",
                "--report", str(work / "verify.md")], True, "VERIFY")

        original = gzip.decompress(base.read_bytes())
        boot_partition = bytearray(original)
        boot_partition[2048 * SECTOR + 17] ^= 1
        boot_bad = work / "boot-partition-bad.img.gz"
        pack(bytes(boot_partition), boot_bad)
        verify(["verify", "--base", str(base), "--compare", str(boot_bad), "--target",
                "/etc/wifi-watchdog.mode", "--old-content", "recover", "--new-content", "observe",
                "--report", str(work / "boot-partition.md")], False, "BOOT_PARTITION_BYTE")

        loader = bytearray(original)
        loader[101] ^= 1
        loader_bad = work / "bootloader-bad.img.gz"
        pack(bytes(loader), loader_bad)
        verify(["verify", "--base", str(base), "--compare", str(loader_bad), "--target",
                "/etc/wifi-watchdog.mode", "--old-content", "recover", "--new-content", "observe",
                "--report", str(work / "bootloader.md")], False, "BOOTLOADER_BYTE")

        extra = work / "extra"
        extra.write_text("changed\n")
        altered = work / "changed-other-file.img.gz"
        altered_raw = bytearray(original)
        partition_path = work / "mutated.ext4"
        start = ROOT_START * SECTOR
        partition_path.write_bytes(altered_raw[start:start + ROOT_SECTORS * SECTOR])
        for command in ("unlink /etc/keep", f"write {extra} /etc/keep"):
            subprocess.run([shutil.which("debugfs") or "debugfs", "-w", "-R", command,
                            str(partition_path)], check=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True)
        altered_raw[start:start + ROOT_SECTORS * SECTOR] = partition_path.read_bytes()
        pack(bytes(altered_raw), altered)
        verify(["verify", "--base", str(base), "--compare", str(altered), "--target",
                "/etc/wifi-watchdog.mode", "--old-content", "recover", "--new-content", "observe",
                "--report", str(work / "other-rootfs-file.md")], False, "SECOND_ROOTFS_FILE")

        verify(["verify", "--base", str(base), "--compare", str(base), "--target",
                "/etc/wifi-watchdog.mode", "--old-content", "recover", "--new-content", "observe",
                "--report", str(work / "identical.md")], False, "IDENTICAL_IMAGE")

        squash = work / "rootfs.squashfs"
        subprocess.run([shutil.which("mksquashfs"), str(source), str(squash), "-noappend",
                        "-comp", "xz", "-b", "131072", "-no-progress"], check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        squash_bytes = squash.read_bytes()
        squash_info = subprocess.run([shutil.which("unsquashfs"), "-s", str(squash)],
                                     check=True, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True).stdout
        if "Compression xz" not in squash_info or "Block size 131072" not in squash_info:
            raise RuntimeError(f"unexpected synthetic SquashFS options:\n{squash_info}")

        sparse_base = work / "sparse-squash-base.img.gz"
        sparse_squashfs_image(squash_bytes, sparse_base, SQUASHFS_TAIL)
        sparse_output = work / "sparse-squash-observe.img.gz"
        sparse_make_report = work / "sparse-squash-make.md"
        sparse_make = ["make", "--base", str(sparse_base), "--output", str(sparse_output),
                       "--target", "/etc/wifi-watchdog.mode", "--old-content", "recover",
                       "--new-content", "observe", "--report", str(sparse_make_report)]
        verify(sparse_make, True, "SPARSE_SQUASHFS_MAKE")
        if "Verdict: PASS" not in sparse_make_report.read_text():
            raise RuntimeError("sparse SquashFS make report did not contain PASS")
        sparse_verify = ["verify", "--base", str(sparse_base), "--compare", str(sparse_output),
                         "--target", "/etc/wifi-watchdog.mode", "--old-content", "recover",
                         "--new-content", "observe", "--report", str(work / "sparse-squash-verify.md")]
        verify(sparse_verify, True, "SPARSE_SQUASHFS_VERIFY")

        changed_tail_raw = gzip.decompress(sparse_output.read_bytes())
        sparse_start = SPARSE_ROOT_START * SECTOR
        rebuilt_used = struct.unpack_from("<Q", changed_tail_raw, sparse_start + 40)[0]
        if changed_tail_raw[sparse_start + rebuilt_used:] != SQUASHFS_TAIL:
            raise RuntimeError("sparse SquashFS footer was not preserved immediately after filesystem")
        print("SPARSE_SQUASHFS_TAIL_PRESERVED=PASS")

        tail_bad_raw = bytearray(changed_tail_raw)
        tail_bad_raw[-1] ^= 1
        tail_bad = work / "sparse-tail-byte-bad.img.gz"
        pack(bytes(tail_bad_raw), tail_bad)
        verify([*sparse_verify[0:1], "--base", str(sparse_base), "--compare", str(tail_bad),
                *sparse_verify[5:]], False, "SPARSE_TAIL_BYTE")

        prefix_bad_raw = bytearray(changed_tail_raw)
        prefix_bad_raw[sparse_start - 1] ^= 1
        prefix_bad = work / "sparse-prefix-byte-bad.img.gz"
        pack(bytes(prefix_bad_raw), prefix_bad)
        verify(["verify", "--base", str(sparse_base), "--compare", str(prefix_bad),
                "--target", "/etc/wifi-watchdog.mode", "--old-content", "recover",
                "--new-content", "observe", "--report", str(work / "sparse-prefix.md")],
               False, "SPARSE_PREFIX_BYTE")

        squash_base = work / "squash-base.img.gz"
        synthetic_image(squash_bytes, squash_base)
        squash_output = work / "squash-observe.img.gz"
        squash_report = work / "squash-make.md"
        verify(["make", "--base", str(squash_base), "--output", str(squash_output), "--target",
                "/etc/wifi-watchdog.mode", "--old-content", "recover", "--new-content", "observe",
                "--report", str(squash_report)], True, "SQUASHFS_MAKE")
        verify(["verify", "--base", str(squash_base), "--compare", str(squash_output), "--target",
                "/etc/wifi-watchdog.mode", "--old-content", "recover", "--new-content", "observe",
                "--report", str(work / "squash-verify.md")], True, "SQUASHFS_VERIFY")
        if "Verdict: PASS" not in squash_report.read_text():
            raise RuntimeError("SquashFS make report did not contain PASS")
        print("SQUASHFS_SELFTEST=PASS")
        print("SELFTEST=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
