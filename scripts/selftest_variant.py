#!/usr/bin/env python3
"""Exercise image variant creation and all required negative controls."""

from __future__ import annotations

import gzip
import os
from pathlib import Path
import random
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


def verify_rejected_by(args: list[str], label: str, check: str) -> None:
    verify(args, False, label)
    report_path = Path(args[args.index("--report") + 1])
    if f"{check}: FAIL" not in report_path.read_text():
        raise RuntimeError(f"{label} was not rejected by expected check {check}")


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


def build_squashfs(tree: Path, image: Path) -> bytes:
    result = subprocess.run([shutil.which("mksquashfs") or "mksquashfs", str(tree), str(image),
                             "-noappend", "-comp", "xz", "-b", "131072", "-no-progress"],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if result.returncode:
        raise RuntimeError(result.stdout)
    return image.read_bytes()


def squashfs_variant_case(work: Path, template: Path, name: str, old: str, new: str,
                          tail: bytes) -> tuple[Path, Path, bytes]:
    tree = work / f"{name}-root"
    shutil.copytree(template, tree)
    (tree / "etc/wifi-watchdog.mode").write_bytes(old.encode() + b"\n")
    squash = work / f"{name}.squashfs"
    squash_bytes = build_squashfs(tree, squash)
    base = work / f"{name}-base.img.gz"
    sparse_squashfs_image(squash_bytes, base, tail)
    output = work / f"{name}-variant.img.gz"
    make_report = work / f"{name}-make.md"
    args = ["make", "--base", str(base), "--output", str(output), "--target",
            "/etc/wifi-watchdog.mode", "--old-content", old, "--new-content", new,
            "--report", str(make_report)]
    verify(args, True, f"SQUASHFS_{name.upper()}_MAKE")
    if "Verdict: PASS" not in make_report.read_text():
        raise RuntimeError(f"{name} SquashFS make report did not contain PASS")
    print(f"squashfs: {name} make PASS")
    verify_args = ["verify", "--base", str(base), "--compare", str(output), "--target",
                   "/etc/wifi-watchdog.mode", "--old-content", old, "--new-content", new,
                   "--report", str(work / f"{name}-verify.md")]
    verify(verify_args, True, f"SQUASHFS_{name.upper()}_VERIFY")
    print(f"squashfs: {name} verify PASS")
    return base, output, gzip.decompress(output.read_bytes())


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

        sparse_base, sparse_output, changed_tail_raw = squashfs_variant_case(
            work, source, "sparse-footer", "recover", "observe", SQUASHFS_TAIL)
        small_old = "".join(random.Random(731).choices("abcdefghijklmnopqrstuvwxyz0123456789", k=12000))
        smaller_base, _, smaller_raw = squashfs_variant_case(
            work, source, "smaller", small_old, "short", SQUASHFS_TAIL)
        larger_new = "".join(random.Random(1907).choices("abcdefghijklmnopqrstuvwxyz0123456789", k=12000))
        larger_base, _, larger_raw = squashfs_variant_case(
            work, source, "larger-cross-boundary", "recover", larger_new, SQUASHFS_TAIL)
        empty_base, _, empty_raw = squashfs_variant_case(
            work, source, "empty-tail", "recover", "observe", b"")

        sparse_start = SPARSE_ROOT_START * SECTOR
        sparse_input_raw = gzip.decompress(sparse_base.read_bytes())
        base_used = struct.unpack_from("<Q", sparse_input_raw, sparse_start + 40)[0]
        rebuilt_used = struct.unpack_from("<Q", changed_tail_raw, sparse_start + 40)[0]
        base_aligned = (base_used + 4095) // 4096 * 4096
        rebuilt_aligned = (rebuilt_used + 4095) // 4096 * 4096
        if changed_tail_raw[sparse_start + rebuilt_aligned:] != SQUASHFS_TAIL:
            raise RuntimeError("sparse SquashFS footer bytes were not preserved")
        if len(changed_tail_raw) - len(sparse_input_raw) != rebuilt_aligned - base_aligned:
            raise RuntimeError("sparse SquashFS image length delta does not match aligned U delta")
        print("squashfs: sparse footer preserved PASS")

        def used_at(path: Path) -> int:
            raw = gzip.decompress(path.read_bytes())
            return struct.unpack_from("<Q", raw, sparse_start + 40)[0]

        smaller_base_u = used_at(smaller_base)
        smaller_output_u = struct.unpack_from("<Q", smaller_raw, sparse_start + 40)[0]
        if smaller_output_u >= smaller_base_u:
            raise RuntimeError("smaller case did not produce a smaller SquashFS")
        print("squashfs: smaller U PASS")

        larger_base_u = used_at(larger_base)
        larger_output_u = struct.unpack_from("<Q", larger_raw, sparse_start + 40)[0]
        if larger_output_u <= larger_base_u:
            raise RuntimeError("larger case did not produce a larger SquashFS")
        if ((larger_output_u + 4095) // 4096) <= ((larger_base_u + 4095) // 4096):
            raise RuntimeError("larger case did not cross a 4096-byte alignment boundary")
        print("squashfs: larger across 4096-byte boundary PASS")
        empty_used = struct.unpack_from("<Q", empty_raw, sparse_start + 40)[0]
        empty_aligned = (empty_used + 4095) // 4096 * 4096
        if empty_raw[sparse_start + empty_aligned:]:
            raise RuntimeError("empty-tail case unexpectedly contains a T suffix")
        print("squashfs: empty T PASS")

        sparse_verify_args = ["--target", "/etc/wifi-watchdog.mode", "--old-content", "recover",
                              "--new-content", "observe"]
        tail_bad_raw = bytearray(changed_tail_raw)
        tail_bad_raw[-1] ^= 1
        tail_bad = work / "sparse-tail-byte-bad.img.gz"
        pack(bytes(tail_bad_raw), tail_bad)
        verify_rejected_by(["verify", "--base", str(sparse_base), "--compare", str(tail_bad),
                            *sparse_verify_args, "--report", str(work / "tail-byte.md")],
                           "SPARSE_TAIL_BYTE", "T_equal")
        print("squashfs: tail byte negative PASS")

        tail_short = work / "sparse-tail-truncated.img.gz"
        pack(changed_tail_raw[:-1], tail_short)
        verify_rejected_by(["verify", "--base", str(sparse_base), "--compare", str(tail_short),
                            *sparse_verify_args, "--report", str(work / "tail-truncated.md")],
                           "SPARSE_TAIL_TRUNCATED", "T_equal")
        print("squashfs: T truncated by one byte negative PASS")

        prefix_bad_raw = bytearray(changed_tail_raw)
        prefix_bad_raw[100] ^= 1
        prefix_bad = work / "sparse-prefix-byte-bad.img.gz"
        pack(bytes(prefix_bad_raw), prefix_bad)
        verify_rejected_by(["verify", "--base", str(sparse_base), "--compare", str(prefix_bad),
                            *sparse_verify_args, "--report", str(work / "prefix-byte.md")],
                           "SPARSE_PREFIX_BYTE", "prefix_0_to_S_equal")
        print("squashfs: [0,S) byte negative PASS")

        print("SQUASHFS_SELFTEST=PASS")
        print("SELFTEST=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
