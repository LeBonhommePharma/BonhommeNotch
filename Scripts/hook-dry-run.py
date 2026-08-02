#!/usr/bin/env python3
"""Dry-run a hook against a live socket (or print the NDJSON it would send)."""
import json, os, sys, subprocess, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(ROOT, "hooks", "notch-hook.py")

fixture = {
    "session_id": "dry-run-session",
    "cwd": "/tmp/bonhomme-demo",
    "tool_name": "Bash",
    "tool_input": {"command": "echo dry-run", "description": "self-test"},
}

action = sys.argv[1] if len(sys.argv) > 1 else "start"
proc = subprocess.run(
    [sys.executable, HOOK, action],
    input=json.dumps(fixture),
    text=True,
    capture_output=True,
    timeout=5,
)
print("exit", proc.returncode)
if proc.stdout:
    print("stdout", proc.stdout)
if proc.stderr:
    print("stderr", proc.stderr)
print("dry-run complete (fail-open if socket absent)")
