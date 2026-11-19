#!/usr/bin/env python3
"""Passive statusline observer; forwards stdin unchanged to the previous HUD."""
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import time


def observe(data, root, now):
    transcript = data.get('transcript_path')
    model = data.get('model', {}).get('id')
    tokens = data.get('context_window', {}).get('current_usage', {}).get('output_tokens')
    if not transcript or not model or not isinstance(tokens, (int, float)) or not math.isfinite(tokens) or tokens < 0:
        return
    # Require a stable response identity: current_usage resets between API calls.
    with open(transcript, 'rb') as stream:
        stream.seek(0, 2)
        stream.seek(max(0, stream.tell() - 262144))
        lines = stream.read().splitlines()
    message_id = None
    for line in reversed(lines):
        try:
            row = json.loads(line)
        except (ValueError, UnicodeError):
            continue
        if row.get('type') == 'assistant':
            message = row.get('message', {})
            if message.get('model') != model:
                return
            message_id = message.get('id')
            break
        if row.get('type') == 'user':
            return
    if not message_id:
        return
    root.mkdir(parents=True, exist_ok=True)
    key = hashlib.sha256(os.path.realpath(transcript).encode()).hexdigest()
    path = root / (key + '.json')
    try:
        state = json.loads(path.read_text())
    except (OSError, ValueError):
        state = {}
    previous = state.get('previous', {})
    samples = [s for s in state.get('samples', []) if now - 14400 <= s['timestamp'] <= now]
    elapsed = now - previous.get('timestamp', now)
    delta = tokens - previous.get('tokens', tokens)
    same = previous.get('message') == message_id and previous.get('model') == model
    if same and 0 <= elapsed < 0.5 and delta >= 0:
        return
    if same and 0.5 <= elapsed <= 2 and delta > 0:
        samples.append(dict(model=model, tokens=delta, seconds=elapsed, timestamp=now,
                            id=key + ':' + str(now)))
    state = dict(previous=dict(message=message_id, model=model, tokens=tokens, timestamp=now), samples=samples)
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(state))
    os.chmod(temp, 0o600)
    temp.replace(path)


def main():
    raw = sys.stdin.buffer.read()
    root = Path.home() / '.config/howmanyusage/claude-speed'
    try:
        observe(json.loads(raw), root, time.time())
    except Exception:
        pass  # Collection must never disrupt the existing HUD.
    config = json.loads((root.parent / 'claude-statusline-original.json').read_text())
    result = subprocess.run(config['command'], shell=True, input=raw)
    return result.returncode


if __name__ == '__main__':
    sys.exit(main())
