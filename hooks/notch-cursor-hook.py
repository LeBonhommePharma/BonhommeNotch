#!/usr/bin/env python3
# BonhommeNotch Cursor bridge — observe-only (never blocks the editor).
import sys, os, json, time, socket

def sock_path():
    p = os.environ.get("BONHOMME_NOTCH_SOCKET") or os.environ.get("AGENT_NOTCH_SOCKET")
    if p:
        return p
    return os.path.expanduser("~/Library/Application Support/BonhommeNotch/notch.sock")

def push(msgs):
    if not msgs:
        return
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect(sock_path())
        s.sendall(b"".join((json.dumps(m) + "\n").encode("utf-8") for m in msgs))
        s.close()
    except Exception:
        pass

try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
ev = d.get("hook_event_name")
cid = d.get("conversation_id") or d.get("session_id") or ""
if not cid:
    sys.exit(0)
roots = d.get("workspace_roots") or []
cwd = roots[0] if roots else ""
now = time.time()
model = d.get("model") or d.get("model_id") or ""
base = {"v": 1, "source": "cursor", "session_id": cid, "cwd": cwd, "ts": now, "model": model}
out = []

def pending(kind, command, tool_name):
    out.append({**base, "action": "pending", "kind": kind,
                "command": str(command)[:200], "tool_name": tool_name,
                "transcript_path": d.get("transcript_path") or ""})

def activity(status, title):
    out.append({**base, "action": "activity", "status": status, "title": str(title)[:120]})

if ev in ("beforeShellExecution", "beforeMCPExecution"):
    cmd = d.get("command") or d.get("tool_name") or d.get("server_name") or ""
    pending("shell" if ev == "beforeShellExecution" else "mcp", cmd, "")
elif ev == "preToolUse":
    tn = str(d.get("tool_name") or "")
    low = tn.lower()
    skip = any(s in low for s in ("shell", "mcp", "bash"))
    read = any(r in low for r in ("read", "grep", "glob", "search", "list",
                                  "fetch", "outline", "codebase", "semantic"))
    if not skip and not read:
        ti = d.get("tool_input") or {}
        path = (ti.get("path") or ti.get("file_path") or ti.get("target_file")
                or ti.get("relative_workspace_path") or ti.get("uri") or "")
        pending("tool", path, tn)
elif ev in ("postToolUse", "postToolUseFailure", "afterShellExecution",
            "afterMCPExecution", "afterFileEdit", "beforeSubmitPrompt", "stop"):
    out.append({**base, "action": "pending-clear"})

if ev == "beforeShellExecution":
    activity("shell", "Running: " + str(d.get("command") or "")[:80])
elif ev == "beforeMCPExecution":
    activity("tool", "Calling " + str(d.get("tool_name") or d.get("server_name") or "tool"))
elif ev == "afterFileEdit":
    fp = d.get("file_path") or d.get("path") or ""
    activity("editing", "Editing " + (os.path.basename(str(fp)) or "file"))
elif ev in ("afterShellExecution", "afterMCPExecution", "beforeSubmitPrompt"):
    activity("running", "Working…")
elif ev == "stop":
    out.append({**base, "action": "activity-clear"})

push(out)
# no stdout → observe only; Cursor's normal approval flow is untouched
