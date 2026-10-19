#!/usr/bin/env python3
"""Build and verify a one-file watchdog-mode image variant."""

from __future__ import annotations

import argparse
import collections
import difflib
import gzip
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import subprocess
import tempfile
import tarfile


SECTOR = 512


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_sha(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise RuntimeError(f"required tool missing: {name}")
    return path


def run(args: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if check and result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(args)}\n{result.stdout}")
    return result


def diagnostic(label: str, args: list[str], *, check: bool = False) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    transcript = f"$ {' '.join(args)}\n{result.stdout}exit_code={result.returncode}\n"
    print(f"=== {label} ===\n{transcript}", end="", flush=True)
    directory = os.environ.get("VARIANT_DIAGNOSTICS_DIR")
    if directory:
        path = Path(directory)
        path.mkdir(parents=True, exist_ok=True)
        with (path / "ext4-diagnostics.log").open("a", encoding="utf-8") as stream:
            stream.write(f"=== {label} ===\n{transcript}")
    if check and result.returncode:
        raise RuntimeError(f"diagnostic command failed ({result.returncode}): {' '.join(args)}\n{result.stdout}")
    return result


def check_ext4(label: str, part: Path, copy_path: Path | None = None) -> subprocess.CompletedProcess[str]:
    checked = part
    if copy_path:
        shutil.copyfile(part, copy_path)
        checked = copy_path
    return diagnostic(label, [tool("e2fsck"), "-fn", str(checked)])


def rootfs_trace(message: str) -> None:
    print(message, flush=True)
    directory = os.environ.get("VARIANT_DIAGNOSTICS_DIR")
    if directory:
        path = Path(directory)
        path.mkdir(parents=True, exist_ok=True)
        with (path / "rootfs-probe.log").open("a", encoding="utf-8") as stream:
            stream.write(message + "\n")


def debugfs_step(part: Path, command: str, step: int) -> int:
    result = diagnostic(f"debugfs command {step}: {command}",
                        [tool("debugfs"), "-w", "-R", command, str(part)])
    check_ext4(f"e2fsck after debugfs command {step}", part,
               part.with_name(f"diagnostic-copy-{step}.ext"))
    if result.returncode or re.search(
            r"(?im)^\s*(?:debugfs:\s*)?(?:Error:|No such file|File not found|File exists|Invalid argument|Couldn't|Could not)",
            result.stdout):
        raise RuntimeError(f"debugfs request failed ({result.returncode}): {command}\n{result.stdout}")
    return step + 1


def read_image(path: Path) -> bytes:
    if path.suffix == ".gz":
        with gzip.open(path, "rb") as stream:
            return stream.read()
    return path.read_bytes()


def partitions(raw: bytes) -> tuple[str, list[dict[str, int]], list[tuple[int, int]]]:
    if len(raw) < SECTOR * 2:
        raise RuntimeError("image is shorter than two sectors")
    if raw[510:512] != b"\x55\xaa":
        raise RuntimeError("input is not a signed MBR/GPT whole-disk image")
    if raw[SECTOR:SECTOR + 8] == b"EFI PART":
        header = raw[SECTOR:SECTOR * 2]
        entry_lba = struct.unpack_from("<Q", header, 72)[0]
        count = struct.unpack_from("<I", header, 80)[0]
        entry_size = struct.unpack_from("<I", header, 84)[0]
        if entry_size < 128 or count > 4096:
            raise RuntimeError("invalid GPT entry table")
        start = entry_lba * SECTOR
        table = raw[start:start + count * entry_size]
        if len(table) != count * entry_size:
            raise RuntimeError("truncated GPT entry table")
        found = []
        for index in range(count):
            entry = table[index * entry_size:(index + 1) * entry_size]
            if entry[:16] == bytes(16):
                continue
            first, last = struct.unpack_from("<QQ", entry, 32)
            found.append({"index": index + 1, "start": first, "end": last + 1})
        return "GPT", found, [(0, SECTOR * 2), (start, start + len(table))]

    found = []
    for index in range(4):
        entry = raw[446 + index * 16:462 + index * 16]
        kind = entry[4]
        first, count = struct.unpack_from("<II", entry, 8)
        if kind and count:
            if kind in (0x05, 0x0F, 0x85):
                raise RuntimeError("extended MBR partitions are not supported")
            found.append({"index": index + 1, "start": first, "end": first + count})
    if not found:
        raise RuntimeError("no MBR partitions found")
    return "MBR", found, [(0, SECTOR)]


def debugfs(part: Path, command: str, *, check: bool = True, write: bool = False) -> str:
    args = [tool("debugfs")]
    if write:
        args.append("-w")
    args.extend(("-R", command, str(part)))
    result = run(args, check=check)
    if check and re.search(r"(?im)^\s*(?:debugfs:\s*)?(?:Error:|No such file|File not found|File exists|Invalid argument|Couldn't|Could not)", result.stdout):
        raise RuntimeError(f"debugfs request failed: {command}\n{result.stdout}")
    return result.stdout


def locate_rootfs(raw: bytes, work: Path) -> tuple[dict[str, int | str], Path]:
    table_kind, parts, _ = partitions(raw)
    work.mkdir(parents=True, exist_ok=True)
    for item in parts:
        start, end = item["start"] * SECTOR, item["end"] * SECTOR
        if end > len(raw) or end <= start:
            continue
        block = raw[start:end]
        fs = "squashfs" if block[:4] in (b"hsqs", b"sqsh") else (
            "ext" if block[1080:1082] == b"\x53\xef" else None)
        rootfs_trace(f"ROOTFS_CANDIDATE partition={item['index']} start_sector={item['start']} "
                     f"end_sector={item['end']} bytes={len(block)} magic={block[:8].hex()} "
                     f"ext_magic={block[1080:1082].hex()} detected_format={fs or 'none'}")
        if not fs:
            continue
        candidate = work / f"partition-{item['index']}.img"
        candidate.write_bytes(block)
        root = work / f"rootfs-{item['index']}"
        if fs == "squashfs":
            unsquashfs = tool("unsquashfs")
            prefix = ["sudo"] if os.geteuid() != 0 and shutil.which("sudo") else []
            result = run(prefix + [unsquashfs, "-no-progress", "-d", str(root), str(candidate)], check=False)
            if result.returncode:
                rootfs_trace(f"ROOTFS_PROBE partition={item['index']} format=squashfs "
                             f"rc={result.returncode}\n{result.stdout}")
                continue
            if (root / "etc/openwrt_release").is_file():
                return {**item, "start_byte": start, "end_byte": end, "fs": fs,
                        "table": table_kind, "used": struct.unpack_from("<Q", block, 40)[0]}, root
            rootfs_trace(f"ROOTFS_PROBE partition={item['index']} format=squashfs "
                         "rc=0 missing=/etc/openwrt_release")
        else:
            result = debugfs(candidate, "cat /etc/openwrt_release", check=False)
            if "DISTRIB_ID" in result or "OPENWRT_RELEASE" in result:
                root.mkdir()
                run([tool("debugfs"), "-R", f"rdump / {root}", str(candidate)])
                return {**item, "start_byte": start, "end_byte": end, "fs": fs,
                        "table": table_kind}, root
            rootfs_trace(f"ROOTFS_PROBE partition={item['index']} format=ext "
                         f"probe_output={result.stdout!r}")
    raise RuntimeError("no MBR/GPT partition contains an OpenWrt rootfs")


def relpath(path: Path, root: Path) -> str:
    return "/" + path.relative_to(root).as_posix()


def tree_manifest(root: Path) -> dict[str, dict[str, object]]:
    result: dict[str, dict[str, object]] = {}
    root_stat = root.lstat()
    result["/"] = {"kind": "dir", "content": "", "mode": root_stat.st_mode & 0o7777,
                    "uid": root_stat.st_uid, "gid": root_stat.st_gid,
                    "mtime_ns": root_stat.st_mtime_ns}
    for base, dirs, files in os.walk(root, followlinks=False):
        here = Path(base)
        for name in sorted(dirs + files):
            path = here / name
            st = path.lstat()
            if path.is_symlink():
                kind = "symlink"
                content = os.readlink(path)
            elif path.is_dir():
                kind, content = "dir", ""
            elif path.is_file():
                kind, content = "file", file_sha(path)
            else:
                kind, content = "special", f"{st.st_mode}:{st.st_rdev}"
            result[relpath(path, root)] = {
                "kind": kind, "content": content, "mode": st.st_mode & 0o7777,
                "uid": st.st_uid, "gid": st.st_gid, "mtime_ns": st.st_mtime_ns,
            }
    return result


def verify_openwrt_tree(root: Path, target: str) -> None:
    if not (root / "etc/openwrt_release").is_file():
        raise RuntimeError("identified filesystem lacks /etc/openwrt_release")
    if not (root / target.lstrip("/")).is_file():
        raise RuntimeError(f"target file does not already exist: {target}")


def outside_hashes(a: bytes, b: bytes, lo: int, hi: int) -> tuple[bool, list[tuple[int, int, str, str]]]:
    if len(a) != len(b):
        return False, [(0, min(len(a), len(b)), sha(a), sha(b))]
    differences = []
    for start, end in ((0, lo), (hi, len(a))):
        if a[start:end] != b[start:end]:
            differences.append((start, end, sha(a[start:end]), sha(b[start:end])))
    return not differences, differences


def partition_table_signature(raw: bytes) -> tuple[str, tuple[tuple[int, int, str], ...]]:
    kind, _, ranges = partitions(raw)
    if kind == "MBR":
        return kind, ((446, 512, sha(raw[446:512])),)
    return kind, tuple((start, end, sha(raw[start:end])) for start, end in ranges)


def squashfs_options(part: bytes) -> tuple[str, int, int]:
    compressor_id = struct.unpack_from("<H", part, 20)[0]
    block = struct.unpack_from("<I", part, 12)[0]
    compressor = {1: "gzip", 2: "lzma", 3: "lzo", 4: "xz", 5: "lz4", 6: "zstd"}.get(compressor_id)
    if not compressor or block < 4096 or block > 1048576:
        raise RuntimeError(f"unsupported SquashFS compressor/block: {compressor_id}/{block}")
    used = struct.unpack_from("<Q", part, 40)[0]
    if used < 96 or used > len(part):
        raise RuntimeError(f"invalid SquashFS bytes_used: {used}")
    return compressor, block, used


def write_image(base_path: Path, output: Path, target: str, old: bytes, new: bytes, report: Path) -> None:
    raw = read_image(base_path)
    try:
        with tempfile.TemporaryDirectory(prefix="variant-") as temp:
            work = Path(temp)
            part, root = locate_rootfs(raw, work)
            verify_openwrt_tree(root, target)
            target_file = root / target.lstrip("/")
            if target_file.read_bytes() != old:
                raise RuntimeError(f"target contents do not match expected old value: {target}")
            before_tree = tree_manifest(root)
            old_meta = before_tree[target]
            target_file.write_bytes(new)
            os.chmod(target_file, int(old_meta["mode"]))
            os.utime(target_file, ns=(target_file.stat().st_atime_ns, int(old_meta["mtime_ns"])))
            if part["fs"] == "squashfs":
                raw_part = raw[int(part["start_byte"]):int(part["end_byte"])]
                compressor, block_size, used = squashfs_options(raw_part)
                old_padding = raw_part[used:]
                if old_padding and len(set(old_padding)) != 1:
                    raise RuntimeError("SquashFS partition padding is not a single repeated byte")
                out_part = work / "new.squashfs"
                prefix = ["sudo"] if os.geteuid() != 0 and shutil.which("sudo") else []
                run(prefix + [tool("mksquashfs"), str(root), str(out_part), "-noappend",
                                  "-comp", compressor, "-b", str(block_size), "-no-progress"])
                payload = out_part.read_bytes()
                if len(payload) > int(part["end_byte"]) - int(part["start_byte"]):
                    raise RuntimeError("rebuilt SquashFS exceeds original partition")
                pad_byte = old_padding[:1] or b"\0"
                payload += pad_byte * (int(part["end_byte"]) - int(part["start_byte"]) - len(payload))
            else:
                candidate = work / "rootfs.ext"
                candidate.write_bytes(raw[int(part["start_byte"]):int(part["end_byte"])])
                check = check_ext4("base rootfs before edit", candidate,
                                   work / "diagnostic-copy-base.ext")
                if check.returncode != 0:
                    raise RuntimeError(f"e2fsck before edit failed:\n{check.stdout}")
                step = 1
                step = debugfs_step(candidate, f"rm {target}", step)
                replacement = work / "replacement"
                replacement.write_bytes(new)
                step = debugfs_step(candidate, f"write {replacement} {target}", step)
                step = debugfs_step(candidate,
                                    f"set_inode_field {target} mode {0o100000 | int(old_meta['mode']):07o}", step)
                step = debugfs_step(candidate, f"set_inode_field {target} uid {old_meta['uid']}", step)
                step = debugfs_step(candidate, f"set_inode_field {target} gid {old_meta['gid']}", step)
                for path, metadata in before_tree.items():
                    if metadata["kind"] == "dir" and path == "/" + target.strip("/").split("/")[0]:
                        epoch = int(metadata["mtime_ns"]) // 1_000_000_000
                        step = debugfs_step(candidate, f"set_inode_field {path} mtime @{epoch}", step)
                check = check_ext4("final rootfs after edit", candidate,
                                   work / "diagnostic-copy-final.ext")
                if check.returncode != 0:
                    raise RuntimeError(f"e2fsck after edit failed:\n{check.stdout}")
                payload = candidate.read_bytes()

            out_raw = bytearray(raw)
            out_raw[int(part["start_byte"]):int(part["end_byte"])] = payload
            output.parent.mkdir(parents=True, exist_ok=True)
            with output.open("wb") as stream:
                if base_path.suffix == ".gz":
                    with gzip.GzipFile(fileobj=stream, mode="wb", mtime=0, compresslevel=9) as gz:
                        gz.write(out_raw)
                else:
                    stream.write(out_raw)
        verify_pair(base_path, output, target, old, new, report=None)
        report.write_text("# make-report\n\nVerdict: PASS\n" +
                          f"base_sha256: {file_sha(base_path)}\noutput_sha256: {file_sha(output)}\n" +
                          f"rootfs_format: {part['fs']}\ntarget: {target}\n", encoding="utf-8")
    except Exception as exc:
        report.write_text(f"# make-report\n\nVerdict: FAIL\nerror: {exc}\n", encoding="utf-8")
        raise


def verify_pair(base_path: Path, compare_path: Path, target: str, old: bytes, new: bytes,
                report: Path | None) -> None:
    try:
        a, b = read_image(base_path), read_image(compare_path)
        if len(a) != len(b):
            raise RuntimeError(f"expanded image sizes differ: {len(a)} != {len(b)}")
        with tempfile.TemporaryDirectory(prefix="verify-variant-") as temp:
            work = Path(temp)
            pa, ra = locate_rootfs(a, work / "a")
            pb, rb = locate_rootfs(b, work / "b")
            if pa["table"] != pb["table"] or pa["start_byte"] != pb["start_byte"] or pa["end_byte"] != pb["end_byte"]:
                raise RuntimeError("partition table/rootfs partition bounds differ")
            outside, regions = outside_hashes(a, b, int(pa["start_byte"]), int(pa["end_byte"]))
            ma, mb = tree_manifest(ra), tree_manifest(rb)
            changed = []
            for name in sorted(set(ma) | set(mb)):
                if ma.get(name) != mb.get(name):
                    changed.append(name)
            target_rel = "/" + target.lstrip("/")
            if set(ma) != set(mb):
                raise RuntimeError("rootfs path set changed")
            if changed != [target_rel]:
                raise RuntimeError(f"rootfs changed paths are not exactly the target: {changed}")
            if (ra / target.lstrip("/")).read_bytes() != old or (rb / target.lstrip("/")).read_bytes() != new:
                raise RuntimeError("target content does not match expected old/new values")
            target_a, target_b = dict(ma[target_rel]), dict(mb[target_rel])
            target_a.pop("content")
            target_b.pop("content")
            target_a.pop("mtime_ns")
            target_b.pop("mtime_ns")
            if target_a != target_b:
                raise RuntimeError(f"target metadata changed: {target_a} != {target_b}")
            if not outside:
                raise RuntimeError(f"bytes outside rootfs differ: {regions}")
        if report:
            report.write_text("# verify-report\n\nVerdict: PASS\n" +
                              f"expanded_size: {len(a)}\nrootfs_changed_paths: {changed}\n" +
                              f"outside_rootfs_equal: {outside}\nrootfs_target_metadata_equal: True\n",
                              encoding="utf-8")
    except Exception as exc:
        if report:
            report.write_text(f"# verify-report\n\nVerdict: FAIL\nerror: {exc}\n", encoding="utf-8")
        raise


def prefix_change_counts(before: Path, after: Path) -> dict[str, tuple[int, int]]:
    left = before.read_bytes().decode("utf-8", "replace").splitlines()
    right = after.read_bytes().decode("utf-8", "replace").splitlines()
    removed: collections.Counter[str] = collections.Counter()
    added: collections.Counter[str] = collections.Counter()
    for tag, start_a, end_a, start_b, end_b in difflib.SequenceMatcher(a=left, b=right).get_opcodes():
        if tag in ("delete", "replace"):
            for line in left[start_a:end_a]:
                if line:
                    removed[line.split(":", 1)[0][:1]] += 1
        if tag in ("insert", "replace"):
            for line in right[start_b:end_b]:
                if line:
                    added[line.split(":", 1)[0][:1]] += 1
    return {prefix: (removed[prefix], added[prefix])
            for prefix in sorted(set(removed) | set(added))}


def tar_manifest(path: Path) -> dict[str, tuple[str, str]]:
    result = {}
    with tarfile.open(path, "r:gz") as archive:
        for member in archive.getmembers():
            stream = archive.extractfile(member)
            content = sha(stream.read() if stream else b"")
            header = json.dumps([member.mode, member.uid, member.gid, member.mtime,
                                 member.type.decode("ascii", "replace") if isinstance(member.type, bytes) else member.type,
                                 member.size, member.linkname], separators=(",", ":"))
            result[member.name] = content, header
    return result


def diff_pair(base: Path, compare: Path, report: Path) -> None:
    a, b = read_image(base), read_image(compare)
    with tempfile.TemporaryDirectory(prefix="diff-variant-") as temp:
        work = Path(temp)
        pa, ra = locate_rootfs(a, work / "a")
        pb, rb = locate_rootfs(b, work / "b")
        ma, mb = tree_manifest(ra), tree_manifest(rb)
        changed = [name for name in sorted(set(ma) | set(mb)) if ma.get(name) != mb.get(name)]
        lines = ["# ci-pair-diff", "", f"base_sha256: {file_sha(base)}",
                 f"compare_sha256: {file_sha(compare)}", f"expanded_size_equal: {len(a) == len(b)}",
                 f"partition_table_equal: {partition_table_signature(a) == partition_table_signature(b)}",
                 f"rootfs_outside_regions_equal: {outside_hashes(a, b, int(pa['start_byte']), int(pa['end_byte']))[0]}",
                 "", "## differing rootfs entries"]
        for name in changed:
            lines.append(f"- {name}: base={json.dumps(ma.get(name), sort_keys=True)} compare={json.dumps(mb.get(name), sort_keys=True)}")
        if not changed:
            lines.append("none")
        lines += ["", "## installed by field prefix"]
        x, y = ra / "lib/apk/db/installed", rb / "lib/apk/db/installed"
        if x.exists() and y.exists():
            changes = prefix_change_counts(x, y)
            lines.append(f"changed_prefixes: {len(changes)}")
            for key, (removed, added) in changes.items():
                lines.append(f"{key}: removed_lines={removed} added_lines={added} changed_lines={removed + added}")
        else:
            lines.append("installed file missing in one or both rootfs trees")
        lines += ["", "## scripts.tar.gz members"]
        x, y = ra / "lib/apk/db/scripts.tar.gz", rb / "lib/apk/db/scripts.tar.gz"
        if x.exists() and y.exists():
            tx, ty = tar_manifest(x), tar_manifest(y)
            lines.append(f"content_differs: {any(tx.get(k, (None, None))[0] != ty.get(k, (None, None))[0] for k in set(tx) | set(ty))}")
            lines.append(f"header_only_differs: {all(tx.get(k, (None, None))[0] == ty.get(k, (None, None))[0] for k in set(tx) | set(ty)) and any(tx.get(k, (None, None))[1] != ty.get(k, (None, None))[1] for k in set(tx) | set(ty))}")
            for name in sorted(set(tx) | set(ty)):
                if tx.get(name) != ty.get(name):
                    lines.append(f"{name}: base={tx.get(name)} compare={ty.get(name)}")
        else:
            lines.append("scripts.tar.gz missing in one or both rootfs trees")
        report.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    make = sub.add_parser("make")
    make.add_argument("--base", type=Path, required=True)
    make.add_argument("--output", type=Path, required=True)
    make.add_argument("--target", required=True)
    make.add_argument("--old-content", required=True)
    make.add_argument("--new-content", required=True)
    make.add_argument("--report", type=Path, required=True)
    for name in ("verify", "diff"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--base", type=Path, required=True)
        cmd.add_argument("--compare", type=Path, required=True)
        cmd.add_argument("--report", type=Path, required=True)
        if name == "verify":
            cmd.add_argument("--target", required=True)
            cmd.add_argument("--old-content", required=True)
            cmd.add_argument("--new-content", required=True)
    args = parser.parse_args()
    if args.command == "make":
        if not args.target.startswith("/") or ".." in PurePosixPath(args.target).parts:
            raise SystemExit("target path must be absolute and contain no parent traversal")
        write_image(args.base, args.output, args.target, args.old_content.encode() + b"\n",
                    args.new_content.encode() + b"\n", args.report)
    elif args.command == "verify":
        verify_pair(args.base, args.compare, args.target, args.old_content.encode() + b"\n",
                    args.new_content.encode() + b"\n", args.report)
    else:
        diff_pair(args.base, args.compare, args.report)


if __name__ == "__main__":
    main()
