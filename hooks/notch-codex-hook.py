#!/usr/bin/env python3
# BonhommeNotch Codex bridge — blocking gate with fail-open.
import sys, os, json, socket

def sock_path():
    p = os.environ.get("BONHOMME_NOTCH_SOCKET") or os.environ.get("AGENT_NOTCH_SOCKET")
    if p:
        return p
    return os.path.expanduser("~/Library/Application Support/BonhommeNotch/notch.sock")

def send(msg, wait, timeout):
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(3.0)
        s.connect(sock_path())
    except Exception:
        return None
    try:
        s.sendall((json.dumps(msg) + "\n").encode("utf-8"))
        if not wait:
            return None
        s.settimeout(timeout)
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                return None
            buf += chunk
        return json.loads(buf.split(b"\n", 1)[0].decode("utf-8"))
    except Exception:
        return None
    finally:
        try:
            s.close()
        except Exception:
            pass

def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "clear"
    try:
        d = json.load(sys.stdin)
    except Exception:
        d = {}
    sid = d.get("session_id") or ""
    if not sid:
        return
    tool = d.get("tool_name") or ""
    ti = d.get("tool_input") or {}
    if not isinstance(ti, dict):
        ti = {}
    cmd = ti.get("command")
    if isinstance(cmd, list):
        parts = [str(x) for x in cmd]
        if len(parts) >= 3 and parts[1] in ("-lc", "-c"):
            cmd = parts[-1]
        else:
            cmd = " ".join(parts)
    patch = ti.get("changes") or ti.get("files") or ti.get("patch")
    if not cmd and patch:
        if isinstance(patch, dict):
            cmd = "patch: " + ", ".join(os.path.basename(str(p)) for p in list(patch.keys())[:4])
        elif isinstance(patch, list):
            cmd = "patch: " + ", ".join(os.path.basename(str(p)) for p in patch[:4])
    detail = cmd or ti.get("file_path") or ti.get("path") or ti.get("description") or ""
    reason = ti.get("justification") or ""
    escalated = ti.get("sandbox_permissions") == "require_escalated"
    base = {
        "v": 1,
        "source": "codex",
        "session_id": sid,
        "cwd": d.get("cwd", ""),
        "tool_name": tool,
        "detail": detail,
        "reason": reason,
        "escalated": escalated,
    }

    if action == "clear":
        send({**base, "action": "clear"}, False, 0)
        return
    if action != "gate":
        return

    resp = send({**base, "action": "gate"}, True, 1795)
    if not resp:
        return
    behavior = resp.get("behavior", "")
    if behavior == "allow":
        dec = {"behavior": "allow"}
    elif behavior == "deny":
        dec = {"behavior": "deny", "message": resp.get("message") or "Denied from BonhommeNotch"}
    else:
        return
    print(json.dumps({"continue": True, "hookSpecificOutput": {
        "hookEventName": "PermissionRequest", "decision": dec}}))

if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
