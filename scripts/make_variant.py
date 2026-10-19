#!/usr/bin/env python3
"""Create and compare a watchdog-mode image variant.

The image outside the rootfs partition is copied byte-for-byte.  SquashFS is
repacked because its compressed metadata cannot be edited in place; reports
therefore compare extracted rootfs files separately from raw image regions.
"""

from __future__ import annotations

import argparse
import collections
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def command(name: str) -> str:
    for candidate in (name, f"{name}4"):
        path = shutil.which(candidate)
        if path:
            return path
    raise RuntimeError(f"required command not found: {name}")


def run(args: list[str]) -> None:
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(args)}\n{result.stderr}")


def mbr_partitions(raw: bytes) -> list[dict[str, int]]:
    if raw[510:512] != b"\x55\xaa":
        raise RuntimeError("input is not an MBR image")
    parts = []
    for index in range(4):
        entry = raw[446 + index * 16 : 462 + index * 16]
        parts.append({
            "index": index + 1,
            "type": entry[4],
            "start": struct.unpack_from("<I", entry, 8)[0],
            "size": struct.unpack_from("<I", entry, 12)[0],
        })
    return parts


def load_raw(image: Path) -> bytes:
    with gzip.open(image, "rb") as stream:
        return stream.read()


def rootfs_partition(raw: bytes) -> dict[str, int]:
    for part in mbr_partitions(raw):
        begin = part["start"] * 512
        end = begin + part["size"] * 512
        payload = raw[begin:end]
        if payload.startswith(b"hsqs") or payload[1024 + 56 : 1024 + 58] == b"\x53\xef":
            part["begin"] = begin
            part["end"] = end
            part["format"] = "squashfs" if payload.startswith(b"hsqs") else "ext4"
            return part
    raise RuntimeError("rootfs partition not found")


def extract_rootfs(raw: bytes, work: Path) -> tuple[dict[str, int], Path]:
    part = rootfs_partition(raw)
    work.mkdir(parents=True, exist_ok=True)
    partition_file = work / "rootfs.partition"
    partition_file.write_bytes(raw[part["begin"] : part["end"]])
    rootfs = work / "rootfs"
    rootfs.mkdir()
    if part["format"] == "squashfs":
        run([command("unsquashfs"), "-no-progress", "-d", str(rootfs), str(partition_file)])
    else:
        debugfs = shutil.which("debugfs")
        if not debugfs:
            raise RuntimeError("required command not found: debugfs")
        run([debugfs, "-R", f"rdump / {rootfs}", str(partition_file)])
    return part, rootfs


def file_digest(path: Path) -> str:
    if path.is_symlink():
        return sha256_bytes(b"symlink\0" + os.readlink(path).encode())
    return sha256_file(path)


def rootfs_files(root: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for base, dirs, files in os.walk(root, followlinks=False):
        base_path = Path(base)
        for name in sorted(files + dirs):
            path = base_path / name
            if path.is_dir() and not path.is_symlink():
                continue
            result[path.relative_to(root).as_posix()] = file_digest(path)
    return result


def write_mode(root: Path, mode: str) -> None:
    if mode not in {"recover", "observe"}:
        raise RuntimeError(f"invalid mode: {mode}")
    target = root / "etc" / "wifi-watchdog.mode"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(mode + "\n", encoding="utf-8", newline="\n")


def squashfs_compression(partition: bytes) -> tuple[str, int]:
    compression = struct.unpack_from("<H", partition, 20)[0]
    block_size = struct.unpack_from("<I", partition, 12)[0]
    names = {1: "gzip", 2: "lzma", 3: "lzo", 4: "xz", 5: "lz4", 6: "zstd"}
    return names.get(compression, "gzip"), block_size


def repack_squashfs(root: Path, source_partition: bytes, output: Path) -> None:
    compressor, block_size = squashfs_compression(source_partition)
    args = [command("mksquashfs"), str(root), str(output), "-noappend", "-comp", compressor,
            "-b", str(block_size), "-all-root", "-no-xattrs"]
    run(args)


def make_image(base: Path, output: Path, mode: str, report: Path) -> None:
    try:
        raw = load_raw(base)
        with tempfile.TemporaryDirectory(prefix="wifi-variant-") as temp_name:
            work = Path(temp_name)
            part, rootfs = extract_rootfs(raw, work)
            write_mode(rootfs, mode)
            new_raw = bytearray(raw)
            partition_file = work / "new.partition"
            if part["format"] == "squashfs":
                repack_squashfs(rootfs, (work / "rootfs.partition").read_bytes(), partition_file)
            else:
                shutil.copy2(work / "rootfs.partition", partition_file)
                debugfs = shutil.which("debugfs")
                if not debugfs:
                    raise RuntimeError("required command not found: debugfs")
                run([debugfs, "-w", "-R", f"write {rootfs / 'etc/wifi-watchdog.mode'} /etc/wifi-watchdog.mode", str(partition_file)])
            payload = partition_file.read_bytes()
            capacity = part["end"] - part["begin"]
            if len(payload) > capacity:
                raise RuntimeError(f"new rootfs exceeds partition: {len(payload)} > {capacity}")
            new_raw[part["begin"] : part["end"]] = payload.ljust(capacity, b"\0")
            output.parent.mkdir(parents=True, exist_ok=True)
            with output.open("wb") as stream:
                with gzip.GzipFile(fileobj=stream, mode="wb", compresslevel=9, mtime=0) as compressed:
                    compressed.write(new_raw)
        report.write_text("# make-report\n\nVerdict: PASS\n" +
                          f"base_sha256: {sha256_file(base)}\noutput_sha256: {sha256_file(output)}\n" +
                          f"mode: {mode}\nrootfs_format: {part['format']}\n", encoding="utf-8")
    except Exception as exc:
        report.write_text(f"# make-report\n\nVerdict: FAIL\nerror: {exc}\n", encoding="utf-8")
        raise


def installed_prefix_counts(data: bytes) -> collections.Counter[str]:
    counts: collections.Counter[str] = collections.Counter()
    for line in data.decode("utf-8", "replace").splitlines():
        if line:
            counts[line.split(":", 1)[0][:1] or "<none>"] += 1
    return counts


def tar_details(path: Path) -> tuple[dict[str, str], dict[str, str]]:
    contents: dict[str, str] = {}
    headers: dict[str, str] = {}
    with tarfile.open(path, mode="r:gz") as archive:
        for member in archive.getmembers():
            source = archive.extractfile(member)
            contents[member.name] = sha256_bytes(source.read() if source else b"")
            headers[member.name] = json.dumps([member.mode, member.uid, member.gid, member.mtime,
                                               member.type, member.size], separators=(",", ":"))
    return contents, headers


def diff_pair(base: Path, compare: Path, report: Path) -> bool:
    try:
        raw_a = load_raw(base)
        raw_b = load_raw(compare)
        part_a = rootfs_partition(raw_a)
        part_b = rootfs_partition(raw_b)
        lines = ["# ci-pair-diff", "", f"base_sha256: {sha256_file(base)}",
                 f"compare_sha256: {sha256_file(compare)}", "", "## raw regions"]
        lines.append(f"partition_table_equal: {raw_a[:512] == raw_b[:512]}")
        lines.append(f"partition_layout_equal: {mbr_partitions(raw_a) == mbr_partitions(raw_b)}")
        lines.append(f"before_rootfs_equal: {raw_a[:part_a['begin']] == raw_b[:part_b['begin']]}")
        lines.append(f"rootfs_region_equal: {raw_a[part_a['begin']:part_a['end']] == raw_b[part_b['begin']:part_b['end']]}")
        lines.append(f"after_rootfs_equal: {raw_a[part_a['end']:] == raw_b[part_b['end']:]}")
        with tempfile.TemporaryDirectory(prefix="wifi-diff-") as temp_name:
            work = Path(temp_name)
            _, root_a = extract_rootfs(raw_a, work / "a")
            _, root_b = extract_rootfs(raw_b, work / "b")
            files_a = rootfs_files(root_a)
            files_b = rootfs_files(root_b)
            differences = []
            for name in sorted(set(files_a) | set(files_b)):
                if files_a.get(name) != files_b.get(name):
                    differences.append((name, files_a.get(name, "<missing>"), files_b.get(name, "<missing>")))
            lines += ["", "## rootfs file differences"]
            if differences:
                lines += [f"- `{name}`: base={old}, compare={new}" for name, old, new in differences]
            else:
                lines.append("none")
            for name in ("lib/apk/db/installed", "lib/apk/db/scripts.tar.gz"):
                pa, pb = root_a / name, root_b / name
                if not pa.exists() or not pb.exists():
                    continue
                if name.endswith("installed"):
                    ca, cb = installed_prefix_counts(pa.read_bytes()), installed_prefix_counts(pb.read_bytes())
                    lines += ["", "## installed by field prefix"]
                    for prefix in sorted(set(ca) | set(cb)):
                        lines.append(f"{prefix}: base={ca[prefix]} compare={cb[prefix]}")
                else:
                    ca, ha = tar_details(pa)
                    cb, hb = tar_details(pb)
                    lines += ["", "## scripts.tar.gz"]
                    lines.append(f"content_differs: {ca != cb}")
                    lines.append(f"header_only_differs: {ca == cb and ha != hb}")
                    for member in sorted(set(ca) | set(cb)):
                        if ca.get(member) != cb.get(member):
                            lines.append(f"content {member}: base={ca.get(member)} compare={cb.get(member)}")
            lines += ["", "## verdict inputs", f"rootfs_file_difference_count: {len(differences)}"]
            verdict = len(differences) == 1 and differences[0][0] == "etc/wifi-watchdog.mode"
            lines.append(f"only_mode_file: {verdict}")
        report.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return verdict
    except Exception as exc:
        report.write_text(f"# ci-pair-diff\n\nVerdict: FAIL\nerror: {exc}\n", encoding="utf-8")
        raise


def verify_pair(base: Path, compare: Path, report: Path) -> None:
    try:
        with tempfile.TemporaryDirectory(prefix="wifi-verify-") as temp_name:
            work = Path(temp_name)
            raw_a, root_a = extract_rootfs(load_raw(base), work / "a")
            raw_b, root_b = extract_rootfs(load_raw(compare), work / "b")
            files_a, files_b = rootfs_files(root_a), rootfs_files(root_b)
            differences = [name for name in sorted(set(files_a) | set(files_b)) if files_a.get(name) != files_b.get(name)]
            mode = (root_b / "etc/wifi-watchdog.mode").read_text(encoding="utf-8")
            outside_equal = (load_raw(base)[:raw_a["begin"]] == load_raw(compare)[:raw_b["begin"]] and
                             load_raw(base)[raw_a["end"]:] == load_raw(compare)[raw_b["end"]:])
            passed = differences == ["etc/wifi-watchdog.mode"] and mode == "observe\n" and outside_equal
        report.write_text("# verify-report\n\n" + f"Verdict: {'PASS' if passed else 'FAIL'}\n" +
                          f"rootfs_differences: {differences}\nmode: {mode!r}\n" +
                          f"outside_rootfs_equal: {outside_equal}\n", encoding="utf-8")
        if not passed:
            raise RuntimeError("verify conditions failed")
    except Exception as exc:
        if not report.exists():
            report.write_text(f"# verify-report\n\nVerdict: FAIL\nerror: {exc}\n", encoding="utf-8")
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="action", required=True)
    make = sub.add_parser("make")
    make.add_argument("--base", type=Path, required=True)
    make.add_argument("--output", type=Path, required=True)
    make.add_argument("--mode", required=True)
    make.add_argument("--report", type=Path, required=True)
    for name in ("verify", "diff"):
        item = sub.add_parser(name)
        item.add_argument("--base", type=Path, required=True)
        item.add_argument("--compare", type=Path, required=True)
        item.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if args.action == "make":
        make_image(args.base, args.output, args.mode, args.report)
    elif args.action == "verify":
        verify_pair(args.base, args.compare, args.report)
    else:
        diff_pair(args.base, args.compare, args.report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
