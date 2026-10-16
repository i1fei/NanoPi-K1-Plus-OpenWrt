#!/usr/bin/env python3
"""Extract commands from release shell scripts and resolve them in a rootfs."""

from __future__ import annotations

import os
import re
import shlex
import stat
import sys
from pathlib import Path


BUILTINS = {
    ".", ":", "[", "break", "cd", "command", "continue", "echo", "eval",
    "exec", "exit", "export", "false", "kill", "local", "printf", "pwd", "read",
    "readonly", "return", "set", "shift", "test", "times", "trap", "true",
    "type", "ulimit", "umask", "unset", "wait",
}
SOURCED_FUNCTIONS = {
    "board_name", "config_get", "config_get_bool", "config_load",
    "procd_add_reload_trigger", "procd_close_instance", "procd_open_instance",
    "procd_set_param",
}
CONTROL = {
    "case", "do", "done", "elif", "else", "esac", "fi", "for", "if", "in",
    "then", "until", "while",
}
PATH_DIRS = ("bin", "sbin", "usr/bin", "usr/sbin")


def release_scripts(root: Path) -> list[Path]:
    patterns = (
        "etc/uci-defaults/99-k1-plus-wifi-release-v1",
        "etc/init.d/k1plus-*",
        "etc/profile.d/*k1-plus*.sh",
        "usr/libexec/k1plus-*",
        "usr/sbin/k1plus-*",
    )
    paths = {path for pattern in patterns for path in root.glob(pattern) if path.is_file()}
    return sorted(paths)


def strip_heredocs(text: str) -> str:
    output: list[str] = []
    delimiter: str | None = None
    for line in text.replace("\r\n", "\n").splitlines(keepends=True):
        if delimiter is not None:
            if line.strip() == delimiter:
                delimiter = None
            continue
        output.append(line)
        match = re.search(r"<<-?[ \t]*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", line)
        if match:
            delimiter = match.group(1)
    return "".join(output)


def strip_arithmetic(text: str) -> str:
    output: list[str] = []
    index = 0
    while index < len(text):
        if text.startswith("$((", index):
            depth = 2
            cursor = index + 3
            while cursor < len(text) and depth:
                if text[cursor] == "(":
                    depth += 1
                elif text[cursor] == ")":
                    depth -= 1
                cursor += 1
            output.append("0")
            index = cursor
        else:
            output.append(text[index])
            index += 1
    return "".join(output)


def shell_tokens(text: str) -> list[str]:
    text = strip_arithmetic(strip_heredocs(text)).replace("\\\n", " ")
    lexer = shlex.shlex(text, posix=True, punctuation_chars="();|&<>\n")
    lexer.whitespace = " \t\r"
    lexer.commenters = "#"
    return list(lexer)


def extract_commands(path: Path) -> tuple[set[str], set[str]]:
    return extract_commands_from_text(path.read_text(encoding="utf-8"))


def extract_absolute_path_assignments(text: str) -> dict[str, str]:
    """Resolve simple shell variables used as command paths."""
    assignments: dict[str, str] = {}
    for line in strip_heredocs(text).splitlines():
        match = re.match(r"^[ \t]*([A-Za-z_][A-Za-z0-9_]*)=(.+?)[ \t]*$", line)
        if not match:
            continue
        try:
            values = shlex.split(match.group(2), comments=False, posix=True)
        except ValueError:
            continue
        if len(values) == 1 and values[0].startswith("/"):
            assignments[f"${match.group(1)}"] = values[0]
    return assignments


def extract_commands_from_text(text: str) -> tuple[set[str], set[str]]:
    local_functions = set(re.findall(r"(?m)^([A-Za-z_][A-Za-z0-9_]*)\(\)[ \t]*\{", text))
    tokens = shell_tokens(text)
    commands: set[str] = set()
    expect_command = True
    in_for_header = False
    case_stack: list[str] = []
    skip_redirection = False

    for index, token in enumerate(tokens):
        if skip_redirection:
            skip_redirection = False
            continue
        if token and set(token) <= {"<", ">"}:
            skip_redirection = True
            continue
        if token == "esac" and case_stack:
            case_stack.pop()
            expect_command = False
            continue
        if case_stack and ";;" in token:
            case_stack[-1] = "pattern"
            expect_command = False
            continue
        if case_stack and case_stack[-1] == "await_in":
            if token == "in":
                case_stack[-1] = "pattern"
            continue
        if case_stack and case_stack[-1] == "pattern":
            if ")" in token:
                case_stack[-1] = "body"
                expect_command = True
            continue
        if token and set(token) <= {"\n", ";", "&", "|", "("}:
            expect_command = True
            continue
        if token == ")":
            expect_command = False
            continue
        if in_for_header:
            if token == "do":
                in_for_header = False
                expect_command = True
            continue
        if token == "for" and expect_command:
            in_for_header = True
            continue
        if token == "case" and expect_command:
            case_stack.append("await_in")
            expect_command = False
            continue
        if token in {"if", "elif", "while", "until", "then", "else", "do"}:
            expect_command = True
            continue
        if token in CONTROL or token in {"{", "}"}:
            expect_command = False
            continue
        if not expect_command:
            continue
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", token):
            continue
        if token == "!":
            continue
        if token in local_functions and index + 1 < len(tokens) and tokens[index + 1] == "(":
            continue
        if token not in {"$", "$@", ""}:
            commands.add(token)
        expect_command = False

    # Commands passed through the watchdog's bounded-execution helper are still dependencies.
    commands.update(re.findall(r"(?m)^[ \t]*run_bounded[ \t]+([^ \t;&|]+)", text))
    for substitution in re.findall(r"\$\((?!\()([^()]*)\)", strip_heredocs(text)):
        nested = shlex.split(substitution, comments=True, posix=True)
        if nested and nested[0] not in BUILTINS and nested[0] not in local_functions:
            commands.add(nested[0])
    if "/etc/init.d/$service" in text:
        commands.add("/etc/init.d/$service")
        commands.discard("/etc/init.d/")
    commands.discard("*")
    for match in re.finditer(r"(?m)^[ \t]*([^()\n]+?)\)[ \t]*", text):
        label = match.group(1).strip()
        if "=" in label or label.startswith(("if ", "while ", "until ")):
            continue
        for part in label.split("|"):
            commands.discard(part.strip(" \t'*?[]!0-9"))
    return commands, local_functions


def resolve_symlink(root: Path, path: Path) -> Path | None:
	"""Resolve an image path, including symlinked parent directories."""
	try:
		pending = list(path.relative_to(root).parts)
	except ValueError:
		return None
	current = root
	for _ in range(64):
		if not pending:
			return current if current.exists() else None
		component = pending.pop(0)
		candidate = current / component
		if not candidate.is_symlink():
			current = candidate
			continue
		target = os.readlink(candidate)
		if target.startswith("/"):
			current = root
			pending = list(Path(target.lstrip("/")).parts) + pending
		else:
			current = candidate.parent
			pending = list(Path(target).parts) + pending
	return None


def resolve_command(root: Path, command: str) -> tuple[str, str]:
    if command in BUILTINS:
        return "yes", "ash builtin"
    if command in SOURCED_FUNCTIONS:
        return "yes", "sourced OpenWrt shell function"
    if command == "/etc/init.d/$service":
        matches = sorted(root.glob("etc/init.d/k1plus-*"))
        if len(matches) == 3 and all(os.access(path, os.X_OK) for path in matches):
            return "yes", "executable /etc/init.d/k1plus-{hw-watchdog,network,wifi-watchdog}"
        return "no", "dynamic init scripts missing or not executable"
    if "$" in command or "`" in command:
        return "no", f"unresolved dynamic command: {command}"

    candidates = [root / command.lstrip("/")] if "/" in command else [root / item / command for item in PATH_DIRS]
    for candidate in candidates:
        if not candidate.exists() and not candidate.is_symlink():
            continue
        resolved = resolve_symlink(root, candidate)
        if resolved is None or not stat.S_ISREG(resolved.stat().st_mode) or not os.access(candidate, os.X_OK):
            continue
        location = "/" + str(candidate.relative_to(root)).replace(os.sep, "/")
        resolved_location = "/" + str(resolved.relative_to(root)).replace(os.sep, "/")
        kind = "BusyBox applet" if resolved.name == "busybox" else "independent binary or script"
        if resolved_location != location:
            kind += f" -> {resolved_location}"
        return "yes", f"{location} ({kind})"
    return "no", "not found in rootfs PATH"


def self_test() -> None:
    fixture = """#!/bin/sh
case "$1" in
  ok) logger ready ;;
  *) exit 1 ;;
esac
cat <<EOF
option fake command
EOF
value=$(date +%s)
run_bounded wifi reload
diag_collect=/usr/libexec/wifi-diag-collect.sh
"$diag_collect" observe
"""
    commands, _ = extract_commands_from_text(fixture)
    assignments = extract_absolute_path_assignments(fixture)
    resolved_commands = {assignments.get(command, command) for command in commands}
    required = {"logger", "cat", "date", "wifi", "exit"}
    forbidden = {"ok", "option", "fake", "command", "*"}
    if (
        not required <= commands
        or commands & forbidden
        or assignments.get("$diag_collect") != "/usr/libexec/wifi-diag-collect.sh"
        or "$diag_collect" in resolved_commands
        or "/usr/libexec/wifi-diag-collect.sh" not in resolved_commands
    ):
        raise RuntimeError(f"command extractor self-test failed: {sorted(commands)}")


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} ROOTFS REPORT", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    report = Path(sys.argv[2])
    self_test()
    scripts = release_scripts(root)
    if not scripts:
        print("no release scripts found", file=sys.stderr)
        return 1

    command_sources: dict[str, set[str]] = {}
    local_functions: set[str] = set()
    for script in scripts:
        text = script.read_text(encoding="utf-8")
        commands, functions = extract_commands_from_text(text)
        assignments = extract_absolute_path_assignments(text)
        local_functions.update(functions)
        relative = "/" + str(script.relative_to(root)).replace(os.sep, "/")
        first_line = script.read_text(encoding="utf-8").splitlines()[0]
        if first_line.startswith("#!"):
            for interpreter in shlex.split(first_line[2:]):
                if interpreter.startswith("/"):
                    command_sources.setdefault(interpreter, set()).add(relative)
        for command in commands:
            command = assignments.get(command, command)
            command_sources.setdefault(command, set()).add(relative)

    failures = 0
    lines = ["# Release Script Command Dependencies", "", "| Command | Present | Location | Scripts |", "|---|---|---|---|"]
    for command in sorted(command_sources):
        if command in local_functions:
            present, location = "yes", "function defined in release script"
        else:
            present, location = resolve_command(root, command)
        failures += present != "yes"
        sources = "<br>".join(sorted(command_sources[command]))
        lines.append(f"| `{command}` | {present} | {location} | {sources} |")
    lines.extend(("", f"Result: {'PASS' if failures == 0 else 'FAIL'}", ""))
    report.write_text("\n".join(lines), encoding="utf-8")
    print(f"COMMAND_DEPENDENCY_COUNT={len(command_sources)}")
    print(f"COMMAND_DEPENDENCY_RESULT={'PASS' if failures == 0 else 'FAIL'}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
