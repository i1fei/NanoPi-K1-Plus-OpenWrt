#!/usr/bin/env python3
"""Create a metadata manifest and secret-presence report for an OpenWrt image."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from make_variant import locate_rootfs, read_image


WATCHDOG_SHA = "B2CB7631A0C471DE690A561D984518024F0073FAF4A539922DCE038A6D9BBEFC".lower()
SETTLE_SHA = "D70CF3C31B524F7812F0B7FF2401393C8A1D5ABAD74AA1AD520790DD1EB291C9".lower()
SECRET_NAMES = re.compile(r"(authorized_keys|BEGIN .* PRIVATE KEY|\.pem$|\.key$)", re.I)
CREDENTIAL_OPTION = re.compile(r"^[ \t]*(?:option|list)[ \t]+(key|psk|wpa_psk|sae_password|passphrase|password|secret|token)[ \t]+(.+)$", re.I)


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def safe_read(path: Path) -> bytes:
    try:
        return path.read_bytes()
    except OSError:
        return b""


def manifest(root: Path, output: Path) -> None:
    rows = ["path\ttype\tsize\tmode\tuid\tgid\tsha256"]
    paths = [root]
    paths.extend(sorted((p for p in root.rglob("*") if not p.is_symlink()), key=lambda p: p.as_posix()))
    paths.extend(sorted((p for p in root.rglob("*") if p.is_symlink()), key=lambda p: p.as_posix()))
    seen: set[Path] = set()
    for path in paths:
        if path in seen:
            continue
        seen.add(path)
        st = path.lstat()
        rel = "/" + ("" if path == root else path.relative_to(root).as_posix())
        mode = f"{st.st_mode & 0o7777:04o}"
        if path.is_symlink():
            kind, size, value = "symlink", len(os.readlink(path)), "-"
        elif path.is_dir():
            kind, size, value = "dir", 0, "-"
        elif path.is_file():
            kind, size, value = "file", st.st_size, digest(path)
        else:
            kind, size, value = "special", st.st_size, "-"
        rows.append(f"{rel}\t{kind}\t{size}\t{mode}\t{st.st_uid}\t{st.st_gid}\t{value}")
    output.write_text("\n".join(rows) + "\n", encoding="utf-8")


def result(name: str, ok: bool, detail: str) -> None:
    print(f"{name}={'PASS' if ok else 'FAIL'} {detail}")


def audit(root: Path, repo: Path, report: Path) -> int:
    failures = 0
    lines: list[str] = []

    def check(name: str, ok: bool, detail: str) -> None:
        nonlocal failures
        result(name, ok, detail)
        lines.append(f"{name}={'PASS' if ok else 'FAIL'} {detail}")
        failures += not ok

    check("ROOTFS", (root / "etc/openwrt_release").is_file(), "path=/etc/openwrt_release")

    forbidden_paths = []
    for path in root.rglob("*"):
        rel = "/" + path.relative_to(root).as_posix()
        if SECRET_NAMES.search(rel):
            forbidden_paths.append(rel)
        if path.is_file() and b"BEGIN " in safe_read(path)[:256] and b" PRIVATE KEY" in safe_read(path)[:256]:
            forbidden_paths.append(rel)
    check("PRIVATE_MATERIAL", not forbidden_paths, f"count={len(forbidden_paths)}")

    host_keys = sorted(root.glob("etc/dropbear/dropbear_*_host_key"))
    check("HOST_KEYS", not host_keys, f"count={len(host_keys)}")

    wireless = root / "etc/config/wireless"
    credential_hits = []
    if wireless.is_file():
        for n, line in enumerate(wireless.read_text(errors="replace").splitlines(), 1):
            if CREDENTIAL_OPTION.match(line):
                credential_hits.append((n, len(line)))
    check("WIRELESS_LITERAL_CREDENTIALS", not credential_hits, f"path=/etc/config/wireless count={len(credential_hits)}")

    config_hits = []
    config_root = root / "etc/config"
    if config_root.is_dir():
        for path in sorted(config_root.iterdir()):
            if not path.is_file():
                continue
            for n, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                if CREDENTIAL_OPTION.match(line) and line.strip().split(None, 1)[-1] not in ("'', \"\""):
                    config_hits.append(("/" + path.relative_to(root).as_posix(), n, len(line)))
    print(f"CONFIG_KEY_OPTIONS count={len(config_hits)} paths/lengths=" + ",".join(f"{p}:{n}:{l}" for p, n, l in config_hits))

    shadow = root / "etc/shadow"
    shadow_state = "missing"
    if shadow.is_file():
        root_line = next((x for x in shadow.read_text(errors="replace").splitlines() if x.startswith("root:")), "")
        field = root_line.split(":")[1] if ":" in root_line else ""
        shadow_state = "empty" if not field else "locked" if field.startswith(("!", "*")) else "has_hash"
    check("ROOT_SHADOW", shadow_state != "missing", f"state={shadow_state}")

    generation_patterns = re.compile(r"urandom|passwd root|WIFI-PASSWORD|password", re.I)
    generation_points = []
    for path in sorted((repo / "overlays").rglob("*")):
        if path.is_file():
            for n, line in enumerate(path.read_text(errors="ignore").splitlines(), 1):
                if generation_patterns.search(line):
                    generation_points.append(f"{path.relative_to(repo).as_posix()}:{n}")
    print("CREDENTIAL_GENERATION_POINTS=" + ",".join(generation_points))

    leftovers = []
    for path in (root / "root", root / "tmp"):
        if path.exists():
            for item in path.rglob("*"):
                rel = "/" + item.relative_to(root).as_posix()
                if re.search(r"test|codex|192\.168|nanopi", rel, re.I) or (item.is_file() and re.search(r"test|codex|192\.168|nanopi", safe_read(item)[:65536].decode(errors="ignore"), re.I)):
                    leftovers.append(rel)
    for marker in (root / "WATCHDOG-DISABLED.txt", root / "root/WATCHDOG-DISABLED.txt"):
        if marker.exists():
            leftovers.append("/" + marker.relative_to(root).as_posix())
    check("TEST_LEFTOVERS", not leftovers, f"count={len(set(leftovers))}")

    watchdog = root / "usr/sbin/k1plus-wifi-watchdog"
    settle = root / "etc/init.d/k1plus-wifi-settle"
    check("WATCHDOG_SHA", watchdog.is_file() and digest(watchdog) == WATCHDOG_SHA, f"sha256={digest(watchdog) if watchdog.is_file() else 'missing'}")
    check("SETTLE_SHA", settle.is_file() and digest(settle) == SETTLE_SHA, f"sha256={digest(settle) if settle.is_file() else 'missing'}")

    matrix = (repo / ".github/workflows/validate-k1-plus-profiles.yml").read_text(errors="replace")
    check("COMPAT_MATRIX", "wifi_compat_v2" in matrix and "wifi_compat_v3" in matrix, "paths=validate-k1-plus-profiles.yml")
    for profile in ("wifi_compat_v2", "wifi_compat_v3"):
        source_hits = []
        for path in sorted((repo / "overlays" / profile).rglob("*")):
            if path.is_file():
                for n, line in enumerate(path.read_text(errors="ignore").splitlines(), 1):
                    if re.search(r"option[ \t]+key[ \t]+", line):
                        source_hits.append(f"{path.relative_to(repo).as_posix()}:{n}")
        artifact_hits = []
        for path in root.rglob("*"):
            if path.is_file() and profile in safe_read(path)[:1024 * 1024].decode(errors="ignore"):
                artifact_hits.append("/" + path.relative_to(root).as_posix())
        print(f"{profile}_LITERAL_KEY_PATHS=" + ",".join(source_hits))
        print(f"{profile}_ARTIFACT_REFERENCES=" + ",".join(artifact_hits))

    report.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="audit-image-") as temp:
        meta, root = locate_rootfs(read_image(args.image), Path(temp))
        manifest(root, args.manifest)
        return audit(root, args.repo, args.report)


if __name__ == "__main__":
    sys.exit(main())
