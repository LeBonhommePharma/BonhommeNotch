#!/usr/bin/env python3
# BonhommeNotch Claude Code bridge — managed install target.
# Protocol: NDJSON v1 over Unix socket (AgentNotch-compatible envelope).
import sys, os, json, socket

def sock_path():
    p = os.environ.get("BONHOMME_NOTCH_SOCKET") or os.environ.get("AGENT_NOTCH_SOCKET")
    if p:
        return p
    return os.path.expanduser("~/Library/Application Support/BonhommeNotch/notch.sock")

def send(msg, wait, timeout):
    # Fail-open: any failure returns None so the agent is never hung forever.
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
    detail = ti.get("command") or ti.get("file_path") or ti.get("path") or ti.get("description") or ""
    reason = ""
    if ti.get("command") and ti.get("description"):
        reason = ti.get("description") or ""
    base = {
        "v": 1,
        "source": "claude",
        "session_id": sid,
        "cwd": d.get("cwd", ""),
        "tool_name": tool,
        "detail": detail,
        "reason": reason,
    }

    if action in ("clear", "start", "busy", "busydone", "done"):
        send({**base, "action": action}, False, 0)
        return
    if action == "ask":
        kind = "plan" if tool == "ExitPlanMode" else "question"
        msg = {**base, "action": "marker", "kind": kind}
        if kind == "question":
            qs = ti.get("questions")
            q0 = qs[0] if isinstance(qs, list) and qs and isinstance(qs[0], dict) else {}
            text = q0.get("question")
            if isinstance(text, str) and text.strip():
                msg["detail"] = text.strip()[:500]
            labels = []
            opts = q0.get("options")
            if isinstance(opts, list):
                for o in opts:
                    if isinstance(o, dict) and isinstance(o.get("label"), str) and o["label"].strip():
                        labels.append(o["label"].strip()[:120])
            if labels:
                msg["options"] = labels[:8]
            if isinstance(qs, list) and len(qs) > 1:
                msg["more_questions"] = len(qs) - 1
        send(msg, False, 0)
        return
    if action == "idle":
        send({**base, "action": "marker", "kind": "idle"}, False, 0)
        return
    if action != "gate":
        return

    if tool in ("AskUserQuestion", "ExitPlanMode"):
        return

    resp = send({**base, "action": "gate", "tool_input": ti}, True, 1795)
    if not resp:
        return  # fail open → terminal prompt
    behavior = resp.get("behavior", "")
    if behavior == "allow":
        dec = {"behavior": "allow", "updatedInput": ti}
    elif behavior == "deny":
        dec = {"behavior": "deny", "message": resp.get("message") or "Denied from BonhommeNotch"}
    else:
        return
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PermissionRequest", "decision": dec}}))

if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
