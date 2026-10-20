#!/usr/bin/env python3
"""Generates a synthetic Claude Code history for demos, screenshots and experiments.

    scripts/make-demo-data.py /tmp/demo-claude            # writes /tmp/demo-claude/projects/...
    CLAUDE_USAGE_MONITOR_CLAUDE_DIR=/tmp/demo-claude \
    CLAUDE_USAGE_MONITOR_DATA_DIR=/tmp/demo-data \
    "/Applications/AI Usage Monitor.app/Contents/MacOS/ClaudeUsageMonitor"

The records use the same shape as real transcripts but contain no conversation text, so a demo never
involves anyone's real data.
"""
import datetime, json, os, random, sys, uuid

home = sys.argv[1] if len(sys.argv) > 1 else "demo-claude"
days = int(sys.argv[2]) if len(sys.argv) > 2 else 30
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
