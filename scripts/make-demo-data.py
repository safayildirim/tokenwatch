#!/usr/bin/env python3
"""Generates a synthetic Claude Code and Codex history for demos, screenshots and experiments.

    scripts/make-demo-data.py /tmp/demo-claude 30 /tmp/demo-codex   # writes <claude>/projects/... and <codex>/sessions/...
    CLAUDE_USAGE_MONITOR_CLAUDE_DIR=/tmp/demo-claude \
    CLAUDE_USAGE_MONITOR_CODEX_DIR=/tmp/demo-codex \
    CLAUDE_USAGE_MONITOR_DATA_DIR=/tmp/demo-data \
    "/Applications/AI Usage Monitor.app/Contents/MacOS/ClaudeUsageMonitor"

The third argument is optional. Without it only the Claude history is written.

The records use the same shape as real transcripts but contain no conversation text, so a demo never
involves anyone's real data.
"""
import datetime, json, os, random, sys, uuid

home = sys.argv[1] if len(sys.argv) > 1 else "demo-claude"
days = int(sys.argv[2]) if len(sys.argv) > 2 else 30
codex_home = sys.argv[3] if len(sys.argv) > 3 else None
random.seed(7)
PROJECTS = ["webapp", "api-service", "mobile-app", "infra-tools"]
MODELS = [("claude-opus-5-5", 0.45), ("claude-sonnet-5-5", 0.40), ("claude-haiku-5-5", 0.10), ("claude-opus-5", 0.05)]
APPS = ["cli", "claude-vscode", "claude-desktop"]
now = datetime.datetime.now(datetime.timezone.utc)

def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"

def line(mid, sid, cwd, t, model, out, cr, cc, inp, app, agent=None):
    msg = {"model": model, "id": mid, "type": "message", "role": "assistant", "content": [{"type": "text", "text": "demo"}],
           "stop_reason": "end_turn", "usage": {"input_tokens": inp, "cache_creation_input_tokens": cc, "cache_read_input_tokens": cr,
           "output_tokens": out, "cache_creation": {"ephemeral_5m_input_tokens": cc // 4, "ephemeral_1h_input_tokens": cc - cc // 4}, "speed": "standard"}}
    d = {"message": msg, "requestId": "req_" + mid, "type": "assistant", "timestamp": iso(t), "sessionId": sid, "cwd": cwd,
         "version": "2.1.300", "entrypoint": app}
    if agent:
        d["agentId"] = agent
        d["isSidechain"] = True
    return json.dumps(d) + "\n"

total = 0
for back in range(days, -1, -1):
    day = (now - datetime.timedelta(days=back)).replace(hour=8, minute=0, second=0, microsecond=0)
    busy = 0.3 if day.weekday() >= 5 else 1.0
    for _ in range(int(random.choice([0, 1, 2, 3, 4]) * busy + 0.5)):
        proj = random.choices(PROJECTS, weights=[4, 3, 2, 1])[0]
        cwd = f"/Users/demo/{proj}"
        key = "".join(c if c.isalnum() else "-" for c in cwd)
        sid = str(uuid.uuid4()); app = random.choices(APPS, weights=[6, 3, 1])[0]
        d = os.path.join(home, "projects", key); os.makedirs(d, exist_ok=True)
        t = day + datetime.timedelta(minutes=random.randint(0, 600))
        if t > now: continue
        main = open(os.path.join(d, sid + ".jsonl"), "w")
        ctx = random.randint(5_000, 40_000)
        primary = random.choices([m for m, _ in MODELS], weights=[w for _, w in MODELS])[0]
        for i in range(random.randint(15, 220)):
            t += datetime.timedelta(seconds=random.randint(5, 140))
            if t > now: break
            model = primary if random.random() < 0.85 else random.choice([m for m, _ in MODELS])
            ctx += random.randint(200, 2500)
            cc = random.randint(0, 4000); cr = max(0, ctx - cc); out = random.randint(30, 1800)
            agent = None; f = main
            if i % 9 == 8:
                agent = "a" + uuid.uuid4().hex[:12]
                sd = os.path.join(d, sid, "subagents"); os.makedirs(sd, exist_ok=True)
                f = open(os.path.join(sd, f"agent-{agent}.jsonl"), "a")
            mid = "msg_" + uuid.uuid4().hex[:24]
            for o in (min(8, out), out // 2, out):   # streaming snapshots of one response
                f.write(line(mid, sid, cwd, t, model, o, cr, cc, random.randint(1, 6), app, agent))
            if agent: f.close()
            total += 1
        main.close()
print(f"wrote {total} synthetic requests under {home}/projects")


def write_codex(root):
    """Writes synthetic Codex sessions: several applications, models and a quota that climbs and resets."""
    rnd = random.Random(11)
    account = "demo-account-1"
    apps = [("codex_exec", "exec"), ("Codex Desktop", "vscode"), ("codex_work_desktop", "vscode"), ("codex_vscode", "vscode"), ("JetBrains.WebStorm", "vscode")]
    models = [("gpt-5.6-terra", 0.35), ("gpt-5.6-sol", 0.25), ("gpt-6.1-sol", 0.25), ("gpt-5.6-luna", 0.15)]
    # Windows reset on fixed boundaries, so every reading belongs to the cycle that was open when it was written.
    week_anchor = int((now + datetime.timedelta(days=3, hours=5)).timestamp())

    def five_reset_at(moment):
        return (int(moment.timestamp()) // 18000 + 1) * 18000

    def week_reset_at(moment):
        weeks = (week_anchor - int(moment.timestamp())) // 604800
        return week_anchor - weeks * 604800

    def week_used(moment):
        into = 7 - (week_reset_at(moment) - int(moment.timestamp())) / 86400
        return float(min(99, 4 + int(into * 5)))
    count = 0
    for back in range(days, -1, -1):
        day = (now - datetime.timedelta(days=back)).replace(hour=9, minute=0, second=0, microsecond=0)
        for _ in range(rnd.choice([0, 1, 1, 2, 3])):
            sid = "01a" + uuid.UUID(int=rnd.getrandbits(128)).hex[3:8] + "-0000-7000-8000-" + uuid.UUID(int=rnd.getrandbits(128)).hex[:12]
            originator, source = rnd.choice(apps)
            model = rnd.choices([m for m, _ in models], weights=[w for _, w in models])[0]
            t = day + datetime.timedelta(minutes=rnd.randint(0, 500))
            if t > now: continue
            d = os.path.join(codex_home, "sessions", t.strftime("%Y/%m/%d")); os.makedirs(d, exist_ok=True)
            proj = rnd.choice(PROJECTS)
            lines = [{"timestamp": iso(t), "ordinal": 0, "type": "session_meta", "payload": {
                "id": sid, "session_id": sid, "timestamp": iso(t), "cwd": f"/Users/demo/{proj}", "originator": originator,
                "cli_version": "0.162.0", "source": source, "creator_account_id": account, "model_provider": "openai"}},
                {"timestamp": iso(t), "ordinal": 1, "type": "turn_context", "payload": {"model": model}}]
            total = dict(input_tokens=0, cached_input_tokens=0, cache_write_input_tokens=0, output_tokens=0, reasoning_output_tokens=0, total_tokens=0)
            ordinal = 2
            used = rnd.randint(1, 30)
            for _ in range(rnd.randint(4, 60)):
                t += datetime.timedelta(seconds=rnd.randint(8, 150))
                if t > now: break
                inp = rnd.randint(8_000, 60_000); cached = int(inp * rnd.uniform(0.6, 0.97)); out = rnd.randint(40, 1_800); reasoning = int(out * rnd.uniform(0, 0.6))
                last = dict(input_tokens=inp, cached_input_tokens=cached, cache_write_input_tokens=0, output_tokens=out, reasoning_output_tokens=reasoning, total_tokens=inp + out)
                for k in total: total[k] += last[k]
                if rnd.random() < 0.15: used = min(99, used + 1)
                rate = {"limit_id": "codex", "plan_type": "plus",
                        "primary": {"used_percent": float(min(99, used)), "window_minutes": 300, "resets_at": five_reset_at(t)},
                        "secondary": {"used_percent": week_used(t), "window_minutes": 10080, "resets_at": week_reset_at(t)}}
                lines.append({"timestamp": iso(t), "ordinal": ordinal, "type": "event_msg", "payload": {
                    "type": "token_count", "info": {"total_token_usage": dict(total), "last_token_usage": last}, "rate_limits": rate}})
                ordinal += 1
                count += 1
            with open(os.path.join(d, f"rollout-{t.strftime('%Y-%m-%dT%H-%M-%S')}-{sid}.jsonl"), "w") as f:
                for l in lines: f.write(json.dumps(l) + "\n")
    # A session that is still going, so that the quota of the demo account is current.
    sid = "01a99999-0000-7000-8000-" + "d" * 12
    t = now - datetime.timedelta(minutes=24)
    d = os.path.join(codex_home, "sessions", t.strftime("%Y/%m/%d")); os.makedirs(d, exist_ok=True)
    lines = [{"timestamp": iso(t), "ordinal": 0, "type": "session_meta", "payload": {
        "id": sid, "session_id": sid, "timestamp": iso(t), "cwd": "/Users/demo/webapp", "originator": "Codex Desktop",
        "cli_version": "0.162.0", "source": "vscode", "creator_account_id": account, "model_provider": "openai"}},
        {"timestamp": iso(t), "ordinal": 1, "type": "turn_context", "payload": {"model": "gpt-6.1-sol"}}]
    total = dict(input_tokens=0, cached_input_tokens=0, cache_write_input_tokens=0, output_tokens=0, reasoning_output_tokens=0, total_tokens=0)
    for i in range(10):
        t += datetime.timedelta(minutes=2, seconds=rnd.randint(0, 40))
        last = dict(input_tokens=30_000, cached_input_tokens=27_000, cache_write_input_tokens=0, output_tokens=600, reasoning_output_tokens=200, total_tokens=30_600)
        for k in total: total[k] += last[k]
        rate = {"limit_id": "codex", "plan_type": "plus",
                "primary": {"used_percent": float(30 + i // 2), "window_minutes": 300, "resets_at": five_reset_at(t)},
                "secondary": {"used_percent": week_used(t), "window_minutes": 10080, "resets_at": week_reset_at(t)}}
        lines.append({"timestamp": iso(t), "ordinal": 2 + i, "type": "event_msg", "payload": {
            "type": "token_count", "info": {"total_token_usage": dict(total), "last_token_usage": last}, "rate_limits": rate}})
        count += 1
    with open(os.path.join(d, f"rollout-{t.strftime('%Y-%m-%dT%H-%M-%S')}-{sid}.jsonl"), "w") as f:
        for l in lines: f.write(json.dumps(l) + "\n")
    print(f"wrote {count} synthetic Codex responses under {root}/sessions")


if codex_home:
    write_codex(codex_home)
