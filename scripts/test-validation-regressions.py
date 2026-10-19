#!/usr/bin/env python3
"""Exercise the two validation regressions reported for b9e5348."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile


def execute(args: list[str], expected_label: str) -> str:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout, end="")
    if result.returncode == 0 or expected_label not in result.stdout:
        raise RuntimeError(f"expected failure {expected_label}, got exit {result.returncode}")
    return result.stdout


def copy_rootfs(source: Path, destination: Path) -> None:
    destination.mkdir()
    for base, dirs, files in os.walk(source, followlinks=False):
        current = Path(base)
        target_dir = destination / current.relative_to(source)
        for name in list(dirs):
            item = current / name
            target = target_dir / name
            if item.is_symlink():
                target.symlink_to(os.readlink(item))
                dirs.remove(name)
            else:
                target.mkdir()
        for name in files:
            item = current / name
            target = target_dir / name
            if item.is_symlink():
                target.symlink_to(os.readlink(item))
            elif stat.S_ISREG(item.lstat().st_mode):
                shutil.copy2(item, target)


def main() -> int:
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--rootfs", type=Path)
    source.add_argument("--image", type=Path)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--old-validator", type=Path)
    parser.add_argument("--old-revision")
    args = parser.parse_args()
    repo = args.repo.resolve()
    checker = repo / "scripts/check-release-script-commands.py"
    validator = repo / "scripts/validate-wifi-release-v1.sh"
    with tempfile.TemporaryDirectory(prefix="validation-regressions-", dir=repo) as temporary:
        work = Path(temporary)
        if args.image:
            sys.path.insert(0, str(repo / "scripts"))
            from make_variant import locate_rootfs, read_image

            _, source = locate_rootfs(read_image(args.image.resolve()), work / "source")
        else:
            source = args.rootfs.resolve()

        missing_root = work / "missing-command-rootfs"
        copy_rootfs(source, missing_root)
        target = missing_root / "usr/sbin/k1plus-wifi-watchdog"
        if target.is_symlink() or not target.is_file():
            raise RuntimeError("watchdog regression target must be a regular file")
        target.write_bytes(target.read_bytes() + b"\nx=/nonexistent/tool\n$x\n")
        report = work / "missing-command.md"
        execute([sys.executable, str(checker), str(missing_root), str(report)],
                "COMMAND_DEPENDENCY_RESULT=FAIL")
        report_text = report.read_text(encoding="utf-8")
        if "`/nonexistent/tool`" not in report_text or "not found in rootfs PATH" not in report_text:
            raise RuntimeError("absolute command path was not resolved and rejected explicitly")
        print("REGRESSION_MISSING_ABSOLUTE_COMMAND=DETECTED")

        crlf_root = work / "crlf-rootfs"
        copy_rootfs(source, crlf_root)
        for relative in ("usr/libexec/wifi-diag-collect.sh", "usr/sbin/k1plus-wifi-watchdog"):
            path = crlf_root / relative
            if path.is_symlink() or not path.is_file():
                raise RuntimeError(f"CRLF regression target must be a regular file: {relative}")
            path.write_bytes(path.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n"))
        execute(["bash", str(validator), str(crlf_root)], "WIFI_DIAG_SCRIPTS_LF=FAIL")
        print("REGRESSION_CRLF=DETECTED")

        if args.old_revision:
            old = work / "old-validator.sh"
            previous = subprocess.run(
                ["git", "-c", f"safe.directory={repo}", "-C", str(repo), "show",
                 f"{args.old_revision}:scripts/validate-wifi-release-v1.sh"],
                check=True, stdout=subprocess.PIPE,
            )
            old.write_bytes(previous.stdout)
            old.chmod(0o755)
            old_validator = old
        elif args.old_validator:
            old_validator = args.old_validator.resolve()
        else:
            old_validator = None
        if old_validator:
            result = subprocess.run(["bash", str(old_validator), str(crlf_root)], text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            print(result.stdout, end="")
            if "WIFI_DIAG_SCRIPTS_LF=PASS" in result.stdout:
                print("PRE_B9E5348_CRLF_FALSE_NEGATIVE=REPRODUCED")
            elif "WIFI_DIAG_SCRIPTS_LF=FAIL" in result.stdout:
                print("PRE_B9E5348_CRLF_FALSE_NEGATIVE=NOT_REPRODUCED")
            else:
                raise RuntimeError("pre-b9e5348 validator did not report its CRLF check")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
