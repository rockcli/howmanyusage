#!/usr/bin/env python3
"""Full-history token usage report from local agent session logs.

Scans the same sources the HowManyUsage app reads, over a whole window
(default: 2026-01-01 CST, "this year") instead of just "today", and renders a
self-contained HTML report. Methodology & per-source quirks: token-audit-notes.md.

  1. Codex   ~/.codex/sessions/YYYY/MM/DD/*.jsonl      (token_count events)
  2. Claude  ~/.claude/projects/**/*.jsonl             (assistant usage, dedup by requestId)
  3. pi      ~/.pi/agent/sessions/*/*.jsonl            (deepseek, exact USD cost)
  4. dsh     ~/.dsh/sessions/**/session.jsonl.zstd     (zstd JSONL, cost estimated)

Token columns are normalized across sources:
  in_uncached / cache_read / cache_write / out (output incl. reasoning; never
  added on top of anything else). Prices mirror the app's Swift tables
  (CodexValue / ClaudeValue / PiUsage).
"""

import argparse
import glob
import html
import json
import os
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

CST = timezone(timedelta(hours=8))
UTC = timezone.utc
HOME = Path.home()

DEFAULT_START = datetime(2026, 1, 1, 0, 0, 0, tzinfo=CST)  # "this year" default
USD_TO_CNY = 7.2  # same rate the app displays with

# ---------------------------------------------------------------- pricing

# $/token: (input_uncached, cached_input, output) — CodexValue.swift
CODEX_PRICES = {
    "gpt-5.6-sol": (5.0e-6, 0.5e-6, 30.0e-6),
    "gpt-5.6-terra": (2.0e-6, 0.2e-6, 12.0e-6),
    "gpt-5.6-luna": (0.2e-6, 0.02e-6, 1.2e-6),
    "codex-auto-review": (0.2e-6, 0.02e-6, 1.2e-6),
    "gpt-5.5": (5.0e-6, 0.5e-6, 30.0e-6),
    "gpt-5.4": (2.5e-6, 0.25e-6, 15.0e-6),
    "gpt-5.3-codex": (1.75e-6, 0.175e-6, 14.0e-6),
    "gpt-5.2-codex": (1.75e-6, 0.175e-6, 14.0e-6),
    "gpt-5.1-codex": (1.25e-6, 0.125e-6, 10.0e-6),
    "gpt-5-codex": (1.25e-6, 0.125e-6, 10.0e-6),
}
CODEX_FALLBACK = CODEX_PRICES["gpt-5-codex"]

# $/token: (input, cache_read, cache_create_5m, cache_create_1h, output) — ClaudeValue.swift
CLAUDE_PRICES = {
    "claude-opus-5": (5.0e-6, 0.5e-6, 6.25e-6, 10.0e-6, 25.0e-6),
    "claude-opus-4-8": (5.0e-6, 0.5e-6, 6.25e-6, 10.0e-6, 25.0e-6),
    "claude-opus-4-7": (5.0e-6, 0.5e-6, 6.25e-6, 10.0e-6, 25.0e-6),
    "claude-opus-4-5": (5.0e-6, 0.5e-6, 6.25e-6, 10.0e-6, 25.0e-6),
    "claude-opus-4-1": (15.0e-6, 1.5e-6, 18.75e-6, 30.0e-6, 75.0e-6),
    "claude-opus-4": (15.0e-6, 1.5e-6, 18.75e-6, 30.0e-6, 75.0e-6),
    "claude-sonnet-5": (3.0e-6, 0.3e-6, 3.75e-6, 6.0e-6, 15.0e-6),
    "claude-sonnet-4-6": (3.0e-6, 0.3e-6, 3.75e-6, 6.0e-6, 15.0e-6),
    "claude-sonnet-4-5": (3.0e-6, 0.3e-6, 3.75e-6, 6.0e-6, 15.0e-6),
    "claude-sonnet-4": (3.0e-6, 0.3e-6, 3.75e-6, 6.0e-6, 15.0e-6),
    "claude-haiku-4-5": (1.0e-6, 0.1e-6, 1.25e-6, 2.0e-6, 5.0e-6),
    "claude-haiku": (1.0e-6, 0.1e-6, 1.25e-6, 2.0e-6, 5.0e-6),
}
CLAUDE_FALLBACK = CLAUDE_PRICES["claude-sonnet-4-5"]

# $/1M tokens: (input, output, cache_read) — PiUsage.swift (dsh estimate + router models)
DEEPSEEK_PRICES = {
    "deepseek-v4-flash": (0.14, 0.28, 0.0028),
    "deepseek-v4-pro": (0.435, 0.87, 0.003625),
}
DEEPSEEK_FALLBACK = DEEPSEEK_PRICES["deepseek-v4-flash"]

# $/1M tokens: (input, output, cache_read) — Moonshot platform (platform.kimi.ai):
# Kimi K3-256k $3.00 input / $15.00 output / $0.30 cache hit. Cache creation is
# not listed separately; charged at the input rate. "kimi-for-coding" is the
# coding-plan alias of the same model — priced identically (estimate).
KIMI_PRICES = (3.0, 15.0, 0.30)

DATE_SUFFIX_RE = None  # compiled lazily


def _strip_codex_date(model):
    import re
    return re.sub(r"-\d{4}-\d{2}-\d{2}$", "", model)


def codex_price(model):
    if not model:
        return CODEX_FALLBACK
    if model in CODEX_PRICES:
        return CODEX_PRICES[model]
    stripped = _strip_codex_date(model)
    if stripped in CODEX_PRICES:
        return CODEX_PRICES[stripped]
    best, best_len = None, 0
    for key, p in CODEX_PRICES.items():
        if model.startswith(key) and len(key) > best_len:
            best, best_len = p, len(key)
    return best or CODEX_FALLBACK


def _strip_claude_date(model):
    import re
    return re.sub(r"-\d{8}$", "", model)


def claude_price(model):
    if not model:
        return CLAUDE_FALLBACK
    if model in CLAUDE_PRICES:
        return CLAUDE_PRICES[model]
    stripped = _strip_claude_date(model)
    if stripped in CLAUDE_PRICES:
        return CLAUDE_PRICES[stripped]
    best, best_len = None, 0
    for key, p in CLAUDE_PRICES.items():
        if model.startswith(key) and len(key) > best_len:
            best, best_len = p, len(key)
    return best or CLAUDE_FALLBACK


def deepseek_price(model):
    return DEEPSEEK_PRICES.get((model or "").lower(), DEEPSEEK_FALLBACK)


PROVIDER_COLORS = {
    "Codex": "#10a37f",
    "Claude": "#d97757",
    "DeepSeek": "#4d6bfe",
    "Antigravity": "#a855f7",
    "Kimi": "#8B5CF6",
    "其他": "#8e8e93",
}


def classify(model):
    m = (model or "").lower()
    if m.startswith("claude") or m in ("sonnet", "haiku", "opus"):
        return "Claude"
    if "deepseek" in m:
        return "DeepSeek"
    if m.startswith("gpt") or m.startswith("codex"):
        return "Codex"
    return "其他"


# ---------------------------------------------------------------- aggregation

def new_cell():
    return {"in_uncached": 0, "cache_read": 0, "cache_write": 0, "out": 0,
            "turns": 0, "cost_usd": 0.0, "cost_cny": 0.0}


USAGE = defaultdict(new_cell)   # (day, provider, model) -> cell
SEEN_REQUESTS = set()           # claude dedupe


def add(ts, model, provider, in_uncached=0, cache_read=0, cache_write=0, out=0,
        cost_usd=0.0, cost_cny=0.0, turns=1):
    day = ts.astimezone(CST).strftime("%Y-%m-%d")
    c = USAGE[(day, provider, model)]
    c["in_uncached"] += in_uncached
    c["cache_read"] += cache_read
    c["cache_write"] += cache_write
    c["out"] += out
    c["turns"] += turns
    c["cost_usd"] += cost_usd
    c["cost_cny"] += cost_cny


def parse_iso(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def iter_lines(path, must_contain=None, binary=False):
    """Yield lines (str) from a file; prefilter by substring before JSON parse."""
    opener = open(path, "rb") if binary else open(path, "r", encoding="utf-8", errors="replace")
    with opener as fh:
        for line in fh:
            if must_contain and not any(m in line for m in must_contain):
                continue
            yield line


def json_obj(line):
    try:
        return json.loads(line)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None


def within(ts, start, end):
    return ts is not None and start <= ts <= end


# ---------------------------------------------------------------- scanners

RETRY_EXCLUDED = {}  # day -> {"tok": int, "cost_usd": float, "sessions": int}


def scan_codex(start, end):
    """Scan codex rollout logs, dropping duplicate scheduler retries.

    Sessions (rollout files) are grouped per CST day by (cwd, first user
    prompt). When the same prompt was launched 2+ times (the orchestrator
    restarting the same plan — verified wasted runs on e.g. 2026-08-09:
    8 near-identical launches, each re-doing ~125 tasks), only the largest
    session of the group counts; the duplicates go to RETRY_EXCLUDED and are
    reported separately instead of polluting the headline numbers.
    Groups below 5M total tokens are never touched (legitimate re-runs).
    """
    base = HOME / ".codex" / "sessions"
    if not base.exists():
        return 0
    # A CST day maps to two UTC dirs; pad one extra day on each side.
    d0 = (start.astimezone(UTC) - timedelta(days=1)).date()
    d1 = (end.astimezone(UTC) + timedelta(days=1)).date()
    files = 0
    file_records = []  # {"cwd","fp","days": {day: {model: [unc, cache_read, out, cost_usd]}}}
    d = d0
    while d <= d1:
        day_dir = base / f"{d.year:04d}" / f"{d.month:02d}" / f"{d.day:02d}"
        d += timedelta(days=1)
        for path in sorted(glob.glob(str(day_dir / "*.jsonl"))):
            files += 1
            model = None
            pending = []  # token_count events seen before the file declares a model
            cwd = None
            fp = None
            buckets = defaultdict(lambda: defaultdict(lambda: [0, 0, 0, 0.0, 0]))
            for line in iter_lines(path, must_contain=('"token_count"', '"turn_context"', '"user_message"')):
                obj = json_obj(line)
                if not obj:
                    continue
                ts = parse_iso(obj.get("timestamp") or "")
                t = obj.get("type")
                if t == "turn_context":
                    p = obj.get("payload") or {}
                    if p.get("cwd"):
                        cwd = p["cwd"]
                    if p.get("model"):
                        if model is None and pending:
                            # attribute pre-declaration events to the file's model
                            for (pday, pin, pcached, pout) in pending:
                                pi = codex_price(p["model"])
                                b = buckets[pday][p["model"]]
                                b[0] += max(0, pin - pcached)
                                b[1] += pcached
                                b[2] += pout
                                b[3] += max(0, pin - pcached) * pi[0] + pcached * pi[1] + pout * pi[2]
                                b[4] += 1
                            pending = []
                        model = p["model"]
                    continue
                if t != "event_msg" or ts is None:
                    continue
                p = obj.get("payload") or {}
                pt = p.get("type")
                if pt == "user_message" and isinstance(p.get("message"), str):
                    if fp is None:
                        fp = p["message"]
                    continue
                if pt != "token_count" or not within(ts, start, end):
                    continue
                info = p.get("info") or {}
                last = info.get("last_token_usage")
                if not last:
                    continue
                inp = last.get("input_tokens") or 0        # includes cached subset
                cached = last.get("cached_input_tokens") or 0
                out = last.get("output_tokens") or 0       # includes reasoning
                day = ts.astimezone(CST).strftime("%Y-%m-%d")
                if model is None:
                    pending.append((day, inp, cached, out))
                    continue
                pi = codex_price(model)
                b = buckets[day][model]
                b[0] += max(0, inp - cached)
                b[1] += cached
                b[2] += out
                b[3] += max(0, inp - cached) * pi[0] + cached * pi[1] + out * pi[2]
                b[4] += 1
            # file never declared a model (pure exec/SDK runs): gpt-5-codex fallback
            for (day, pin, pcached, pout) in pending:
                pi = CODEX_FALLBACK
                b = buckets[day]["unknown"]
                b[0] += max(0, pin - pcached)
                b[1] += pcached
                b[2] += pout
                b[3] += max(0, pin - pcached) * pi[0] + pcached * pi[1] + pout * pi[2]
                b[4] += 1
            if buckets:
                file_records.append({"cwd": cwd, "fp": fp, "days": dict(buckets)})

    # group per (day, cwd, prompt) and drop scheduler retries (keep largest)
    groups = defaultdict(list)  # (day, cwd, fp) -> [{"tok","cost","day","model","b":[...]}]
    for rec in file_records:
        for day, models in rec["days"].items():
            for model, (unc, cr, out, cost, ev) in models.items():
                tok = unc + cr + out
                key = (day, rec["cwd"], (rec["fp"] or "")[:60] if rec["fp"] else None)
                groups[key].append({"tok": tok, "cost": cost, "model": model, "ev": ev,
                                    "b": [unc, cr, out, cost]})
    for (day, _cwd, fp), entries in groups.items():
        total = sum(e["tok"] for e in entries)
        if fp is None or len(entries) < 2 or total <= 5_000_000:
            for e in entries:
                add(datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=CST), e["model"],
                    "Codex", in_uncached=e["b"][0], cache_read=e["b"][1],
                    out=e["b"][2], cost_usd=e["b"][3], turns=e["ev"])
            continue
        entries.sort(key=lambda e: -e["tok"])
        keep, retries = entries[0], entries[1:]
        ex = RETRY_EXCLUDED.setdefault(day, {"tok": 0, "cost_usd": 0.0, "sessions": 0})
        for e in retries:
            ex["tok"] += e["tok"]
            ex["cost_usd"] += e["cost"]
            ex["sessions"] += 1
        add(datetime.strptime(day, "%Y-%m-%d").replace(tzinfo=CST), keep["model"],
            "Codex", in_uncached=keep["b"][0], cache_read=keep["b"][1],
            out=keep["b"][2], cost_usd=keep["b"][3], turns=keep["ev"])
    return files


def scan_claude(start, end):
    base = HOME / ".claude" / "projects"
    if not base.exists():
        return 0
    start_utc = start.astimezone(UTC)
    files = 0
    for path in glob.glob(str(base / "**" / "*.jsonl"), recursive=True):
        try:
            if os.path.getmtime(path) < start_utc.timestamp():
                continue  # file never written after the window started
        except OSError:
            continue
        files += 1
        for line in iter_lines(path, must_contain=('"usage"',)):
            if '"type":"assistant"' not in line and '"type": "assistant"' not in line:
                continue
            obj = json_obj(line)
            if not obj or obj.get("type") != "assistant":
                continue
            if obj.get("isApiErrorMessage"):
                continue
            ts = parse_iso(obj.get("timestamp") or "")
            if not within(ts, start, end):
                continue
            msg = obj.get("message") or {}
            model = msg.get("model")
            if not model or model == "<synthetic>":
                continue
            u = msg.get("usage") or {}
            inp = u.get("input_tokens") or 0
            cc = u.get("cache_creation") or {}
            cw1h = cc.get("ephemeral_1h_input_tokens") or 0
            cw5m = cc.get("ephemeral_5m_input_tokens") or 0
            cw_total = u.get("cache_creation_input_tokens") or 0
            if not cw1h and not cw5m:
                cw5m = cw_total
            cr = u.get("cache_read_input_tokens") or 0
            out = u.get("output_tokens") or 0
            rid = obj.get("requestId") or msg.get("id")
            if rid:
                if rid in SEEN_REQUESTS:
                    continue  # one API request logged once per content block
                SEEN_REQUESTS.add(rid)
            provider = classify(model)
            if provider == "Claude":
                p = claude_price(model)
                cost = inp * p[0] + cr * p[1] + cw5m * p[2] + cw1h * p[3] + out * p[4]
                add(ts, model, provider, in_uncached=inp, cache_read=cr,
                    cache_write=cw5m + cw1h, out=out, cost_usd=cost)
            elif provider == "DeepSeek":
                p = deepseek_price(model)
                cost = inp / 1e6 * p[0] + out / 1e6 * p[1] + cr / 1e6 * p[2]
                add(ts, model, provider, in_uncached=inp, cache_read=cr,
                    cache_write=cw_total, out=out, cost_usd=cost)
            else:
                add(ts, model, provider, in_uncached=inp, cache_read=cr,
                    cache_write=cw_total, out=out)
    return files


def scan_pi(start, end):
    base = HOME / ".pi" / "agent" / "sessions"
    if not base.exists():
        return 0
    start_utc = start.astimezone(UTC)
    files = 0
    for path in glob.glob(str(base / "*" / "*.jsonl")):
        try:
            if os.path.getmtime(path) < start_utc.timestamp():
                continue
        except OSError:
            continue
        files += 1
        model = None
        for line in iter_lines(path, must_contain=('"usage"', '"model_change"')):
            obj = json_obj(line)
            if not obj:
                continue
            ts = parse_iso(obj.get("timestamp") or "")
            if obj.get("type") == "model_change":
                if obj.get("modelId"):
                    model = obj["modelId"]
                continue
            if obj.get("type") != "message" or not within(ts, start, end):
                continue
            msg = obj.get("message") or {}
            provider = msg.get("provider")
            u = msg.get("usage")
            if not provider or not u:
                continue
            inp = u.get("input") or 0          # excludes cacheRead
            cr = u.get("cacheRead") or 0
            cw = u.get("cacheWrite") or 0
            out = u.get("output") or 0         # includes reasoning
            cost_obj = u.get("cost") or {}
            cost = cost_obj.get("total")
            m = msg.get("modelId") or model or "unknown"
            p = deepseek_price(m)
            cost_est = inp / 1e6 * p[0] + out / 1e6 * p[1] + cr / 1e6 * p[2]
            add(ts, m, "DeepSeek", in_uncached=inp, cache_read=cr, cache_write=cw,
                out=out, cost_usd=cost if cost is not None else cost_est)
    return files


def scan_dsh(start, end):
    base = HOME / ".dsh" / "sessions"
    if not base.exists():
        return 0
    start_utc = start.astimezone(UTC)
    files = 0
    for path in glob.glob(str(base / "**" / "session.jsonl.zstd"), recursive=True):
        try:
            if os.path.getmtime(path) < start_utc.timestamp():
                continue
        except OSError:
            continue
        files += 1
        try:
            text = subprocess.run(["zstd", "-dc", path], capture_output=True,
                                  check=True, timeout=120).stdout.decode("utf-8", "replace")
        except (subprocess.SubprocessError, OSError):
            continue
        model = None
        for line in text.splitlines():
            if '"time"' not in line:
                continue
            obj = json_obj(line)
            if not obj:
                continue
            t = obj.get("type")
            ms = obj.get("time")
            ts = datetime.fromtimestamp(ms / 1000, tz=UTC) if isinstance(ms, (int, float)) else None
            if t == "request/header":
                try:
                    model = obj["data"]["header"]["config"]["model"]
                except (KeyError, TypeError):
                    pass
                continue
            if t != "assistant/chunk" or not within(ts, start, end):
                continue
            chunk = ((obj.get("data") or {}).get("chunk") or {})
            if chunk.get("type") != "usage":
                continue
            u = chunk.get("usage") or {}
            inp = u.get("inputTokens") or 0      # excludes cacheRead
            cr = u.get("cacheReadTokens") or 0
            out = u.get("outputTokens") or 0     # includes reasoningTokens
            p = deepseek_price(model)
            cost = inp / 1e6 * p[0] + out / 1e6 * p[1] + cr / 1e6 * p[2]
            add(ts, model or "deepseek-v4-flash", "DeepSeek", in_uncached=inp,
                cache_read=cr, out=out, cost_usd=cost)
    return files


def scan_kimi(start, end):
    """kimi-code (Kimi CLI): ~/.kimi-code/sessions/<ws>/session_*/agents/*/wire.jsonl.

    Usage lines: {"type":"usage.record","model":"kimi-code/k3-256k",
      "usage":{"inputOther":N,"output":N,"inputCacheRead":N,"inputCacheCreation":N},
      "usageScope":"turn","time":<epoch ms>}.
    Only usageScope=="turn" records count — "session" records are per-session
    cumulative summaries that would double-count the turn records.
    """
    base = HOME / ".kimi-code" / "sessions"
    files = glob.glob(str(base / "*" / "session_*" / "agents" / "*" / "wire.jsonl"))
    start_utc = start.astimezone(UTC)
    scanned = 0
    for path in files:
        try:
            if os.path.getmtime(path) < start_utc.timestamp():
                continue
        except OSError:
            continue
        scanned += 1
        for line in iter_lines(path, must_contain=('"usage.record"',)):
            obj = json_obj(line)
            if not obj or obj.get("type") != "usage.record":
                continue
            if obj.get("usageScope") != "turn":
                continue
            ms = obj.get("time")
            ts = datetime.fromtimestamp(ms / 1000, tz=UTC) if isinstance(ms, (int, float)) else None
            if not within(ts, start, end):
                continue
            model = (obj.get("model") or "unknown").removeprefix("kimi-code/")
            u = obj.get("usage") or {}
            inp = u.get("inputOther") or 0          # uncached input
            cr = u.get("inputCacheRead") or 0
            cw = u.get("inputCacheCreation") or 0
            out = u.get("output") or 0
            p = KIMI_PRICES
            cost = inp / 1e6 * p[0] + out / 1e6 * p[1] + cr / 1e6 * p[2] + cw / 1e6 * p[0]
            add(ts, model, "Kimi", in_uncached=inp, cache_read=cr, cache_write=cw,
                out=out, cost_usd=cost)
    return scanned


def _extract_antigravity_model(obj):
    if isinstance(obj.get("model"), str) and obj["model"].strip():
        return obj["model"].strip()
    if obj.get("type") != "USER_INPUT":
        return None
    content = obj.get("content") or ""
    marker = "changed setting `Model Selection` from "
    idx = content.rfind(marker)
    if idx < 0:
        return None
    after = content[idx + len(marker):]
    to_idx = after.find(" to ")
    if to_idx < 0:
        return None
    val = after[to_idx + 4:]
    for sep in (".", "\n", "<"):
        s_idx = val.find(sep)
        if s_idx >= 0:
            val = val[:s_idx]
    val = val.strip()
    if not val or val.lower() == "none":
        return None
    if val.endswith(")") and " (" in val:
        prefix, suffix = val.rsplit(" (", 1)
        if suffix[:-1].strip().lower() in ("minimal", "low", "medium", "high", "max", "thinking"):
            return prefix.strip()
    return val


def scan_antigravity(start, end):
    """Antigravity CLI and clients: ~/.gemini/{antigravity,antigravity-ide,antigravity-cli}/brain/<id>/.system_generated/logs/transcript.jsonl."""
    start_utc = start.astimezone(UTC)
    best = {}  # conv_id -> (path, mtime, size)
    for sub in ("antigravity", "antigravity-ide", "antigravity-cli"):
        brain = HOME / ".gemini" / sub / "brain"
        if not brain.exists():
            continue
        try:
            entries = list(brain.iterdir())
        except OSError:
            continue
        for conv_dir in entries:
            if conv_dir.name.startswith("."):
                continue
            p = conv_dir / ".system_generated" / "logs" / "transcript.jsonl"
            try:
                st = p.stat()
            except OSError:
                continue
            if st.st_mtime < start_utc.timestamp():
                continue
            prev = best.get(conv_dir.name)
            if prev is None or (st.st_mtime, st.st_size) > (prev[1], prev[2]):
                best[conv_dir.name] = (p, st.st_mtime, st.st_size)

    scanned = 0
    for _conv_id, (path, _mtime, _size) in best.items():
        scanned += 1
        model = "gemini"
        by_step = {}
        unindexed = []
        for line in iter_lines(path, must_contain=('"PLANNER_RESPONSE"', '"Model Selection"', '"model"')):
            obj = json_obj(line)
            if not obj:
                continue
            m = _extract_antigravity_model(obj)
            if m:
                model = m
            if obj.get("type") != "PLANNER_RESPONSE":
                continue
            ts = parse_iso(obj.get("created_at") or obj.get("timestamp") or "")
            if not within(ts, start, end):
                continue
            inp = max(0, obj.get("input_tokens") or 0)
            cr = max(0, obj.get("cache_read_tokens") or 0)
            cw = max(0, obj.get("cache_write_tokens") or 0)
            out = max(0, obj.get("output_tokens") or 0)
            tot = inp + cr + cw + out
            if tot <= 0:
                continue
            step = obj.get("step_index")
            rec = (ts, model, inp, cr, cw, out, tot)
            if isinstance(step, int):
                if step not in by_step or tot > by_step[step][6]:
                    by_step[step] = rec
            else:
                unindexed.append(rec)
        for ts, m, inp, cr, cw, out, _tot in list(by_step.values()) + unindexed:
            add(ts, m, "Antigravity", in_uncached=inp, cache_read=cr, cache_write=cw, out=out)
    return scanned


# ---------------------------------------------------------------- formatting

def fmt_int(n):
    return f"{n:,}"


def fmt_tok(n):
    if n >= 1e9:
        return f"{n / 1e9:.2f}B"
    if n >= 1e6:
        return f"{n / 1e6:.2f}M"
    if n >= 1e3:
        return f"{n / 1e3:.1f}K"
    return str(n)


def fmt_cny(v):
    return f"¥{v:,.2f}"


def fmt_usd(v):
    return f"${v:,.2f}"


# ---------------------------------------------------------------- report

CSS = """
:root { --bg:#0f1115; --card:#181c23; --border:#262c38; --text:#e6e9ef;
        --muted:#8b93a3; --accent:#4d9fff; }
* { box-sizing:border-box; margin:0; padding:0; }
body { background:var(--bg); color:var(--text);
       font:14px/1.6 -apple-system, "PingFang SC", "Helvetica Neue", sans-serif;
       padding:32px 20px 60px; }
.wrap { max-width:1080px; margin:0 auto; }
h1 { font-size:22px; margin-bottom:4px; }
h2 { font-size:16px; margin:36px 0 12px; color:var(--text); }
.sub { color:var(--muted); font-size:13px; margin-bottom:24px; }
.cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(230px,1fr));
         gap:12px; margin-bottom:8px; }
.card { background:var(--card); border:1px solid var(--border); border-radius:12px;
        padding:16px 18px; }
.card .k { color:var(--muted); font-size:12px; margin-bottom:6px; }
.card .v { font-size:24px; font-weight:650; letter-spacing:.2px; }
.card .d { color:var(--muted); font-size:12px; margin-top:4px; }
table { width:100%; border-collapse:collapse; background:var(--card);
        border:1px solid var(--border); border-radius:12px; overflow:hidden;
        font-size:13px; }
th, td { padding:8px 12px; text-align:right; border-bottom:1px solid var(--border);
         white-space:nowrap; }
th:first-child, td:first-child { text-align:left; }
th { color:var(--muted); font-weight:500; font-size:12px; background:#1c212b; }
tr:last-child td { border-bottom:none; }
td.num { font-variant-numeric:tabular-nums; }
.day { font-variant-numeric:tabular-nums; color:var(--text); }
.muted { color:var(--muted); }
.chart { background:var(--card); border:1px solid var(--border);
         border-radius:12px; padding:18px 18px 8px; }
.legend { display:flex; flex-wrap:wrap; gap:16px; padding:10px 2px 8px;
          color:var(--muted); font-size:12px; }
.legend .dot { display:inline-block; width:10px; height:10px; border-radius:3px;
               margin-right:6px; vertical-align:-1px; }
.notes { background:var(--card); border:1px solid var(--border); border-radius:12px;
         padding:16px 20px; font-size:13px; color:var(--muted); }
.notes li { margin:6px 0 6px 18px; }
.notes b { color:var(--text); font-weight:600; }
.total-row td { font-weight:650; background:#1c212b; }
.scroll { overflow-x:auto; }
.scroll table { min-width:100%; }
a { color:var(--accent); }
"""


def stacked_bar_chart(days, series, values, height=300, unit="tokens", money=False):
    """series: list of provider names; values: {(day, provider): float}."""
    W = 1000
    L, R, T, B = 56, 12, 16, 26
    plot_w, plot_h = W - L - R, height - T - B
    totals = {d: sum(values.get((d, s), 0) for s in series) for d in days}
    vmax = max(totals.values()) or 1
    # nice ceiling
    import math
    mag = 10 ** math.floor(math.log10(vmax))
    nice = [x * mag for x in (1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10)]
    vmax = next((x for x in nice if x >= vmax), vmax)

    def y(v):
        return T + plot_h - (v / vmax) * plot_h

    parts = [f'<svg viewBox="0 0 {W} {height}" xmlns="http://www.w3.org/2000/svg" '
             f'role="img" style="width:100%;height:auto;display:block">']
    # gridlines
    for i in range(5):
        v = vmax * i / 4
        yy = y(v)
        parts.append(f'<line x1="{L}" y1="{yy:.1f}" x2="{W - R}" y2="{yy:.1f}" '
                     f'stroke="#262c38" stroke-width="1"/>')
        label = fmt_cny(v) if money else fmt_tok(v)
        parts.append(f'<text x="{L - 8}" y="{yy + 4:.1f}" fill="#8b93a3" font-size="11" '
                     f'text-anchor="end">{label}</text>')
    n = len(days)
    slot = plot_w / max(n, 1)
    bw = max(4, min(30, slot * 0.62))
    # per-bar value labels only when there is room: few bars and a tall enough bar
    show_labels = n <= 32
    for i, d in enumerate(days):
        x = L + i * slot + (slot - bw) / 2
        cum = 0.0
        total = totals[d]
        for s in series:
            v = values.get((d, s), 0)
            if v <= 0:
                continue
            y0, y1 = y(cum), y(cum + v)
            h = max(1.0, y0 - y1)
            parts.append(f'<rect x="{x:.1f}" y="{y1:.1f}" width="{bw:.1f}" height="{h:.1f}" '
                         f'fill="{PROVIDER_COLORS.get(s, "#888")}" rx="1.5">'
                         f'<title>{d} · {s}: '
                         f'{fmt_cny(v) if money else fmt_tok(v) + " tokens"}</title></rect>')
            cum += v
        if total > 0 and show_labels and (T + plot_h - y(total)) >= 20:
            tip = fmt_cny(total) if money else fmt_tok(total) + " tok"
            parts.append(f'<text x="{x + bw / 2:.1f}" y="{y(total) - 5:.1f}" fill="#8b93a3" '
                         f'font-size="10" text-anchor="middle">{tip}</text>')
        # x labels: show first, last, and every ~7th day
        show = i in (0, n - 1) or (n > 14 and i % 7 == 6) or n <= 14
        if show:
            parts.append(f'<text x="{x + bw / 2:.1f}" y="{height - 8}" fill="#8b93a3" '
                         f'font-size="10" text-anchor="middle">{d[5:]}</text>')
    parts.append("</svg>")
    return "".join(parts)


def build_html(start, end, day_totals, model_totals, provider_totals, files_seen,
               month_totals=None):
    days = sorted(day_totals.keys())
    providers = [p for p in ("Codex", "Claude", "DeepSeek", "Antigravity", "Kimi", "其他")
                 if any((p == k[1]) for k in USAGE)]
    months = sorted(month_totals.keys()) if month_totals else []
    m_providers = [p for p in providers if any(p in month_totals[m]["providers"] for m in months)]
    month_tok_vals = {(m, p): month_totals[m]["providers"][p]["tok"]
                      for m in months for p in month_totals[m]["providers"]}
    month_cost_vals = {(m, p): month_totals[m]["providers"][p]["cny_eq"]
                       for m in months for p in month_totals[m]["providers"]}

    tok_vals = {(d, p): day_totals[d]["providers"][p]["tok"] for d in days for p in day_totals[d]["providers"]}
    cost_vals = {(d, p): day_totals[d]["providers"][p]["cny_eq"] for d in days for p in day_totals[d]["providers"]}

    grand = {
        "in_uncached": sum(c["in_uncached"] for c in USAGE.values()),
        "cache_read": sum(c["cache_read"] for c in USAGE.values()),
        "cache_write": sum(c["cache_write"] for c in USAGE.values()),
        "out": sum(c["out"] for c in USAGE.values()),
    }
    grand["total"] = sum(grand.values())
    total_usd = sum(c["cost_usd"] for c in USAGE.values())
    total_cny = sum(c["cost_cny"] for c in USAGE.values())
    total_turns = sum(c["turns"] for c in USAGE.values())
    cny_eq = total_usd * USD_TO_CNY + total_cny
    active_days = len([d for d in days if day_totals[d].get("__total_tok", 0) > 0])
    peak_day = max(days, key=lambda d: day_totals[d].get("__total_tok", 0)) if days else "-"

    now = datetime.now(CST).strftime("%Y-%m-%d %H:%M")
    h = [f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Token 花费报告 {start:%Y-%m-%d} → {end:%Y-%m-%d}</title>
<style>{CSS}</style></head><body><div class="wrap">
<h1>Token 花费报告</h1>
<div class="sub">统计期间 {start:%Y-%m-%d} → {end:%Y-%m-%d}（CST 日界，与 App 一致）· 生成于 {now} ·
数据源：Codex / Claude / pi / dsh / kimi-code 本地会话日志（{files_seen} 个文件）</div>
<div class="cards">
  <div class="card"><div class="k">总 Token（输入+输出+缓存读写）</div>
    <div class="v">{fmt_tok(grand["total"])}</div>
    <div class="d">输入 {fmt_tok(grand["in_uncached"])} · 输出 {fmt_tok(grand["out"])}<br>
    缓存读 {fmt_tok(grand["cache_read"])} · 缓存写 {fmt_tok(grand["cache_write"])}</div></div>
  <div class="card"><div class="k">API 等价总花费（按官方价目折算）</div>
    <div class="v">{fmt_cny(cny_eq)}</div>
    <div class="d">≈ {fmt_usd(total_usd)}（Codex/Claude/DeepSeek/Kimi，×{USD_TO_CNY}）<br>
    + {fmt_cny(total_cny)}（DeepSeek，原生计价）</div></div>
  <div class="card"><div class="k">LLM 调用次数</div>
    <div class="v">{fmt_int(total_turns)}</div>
    <div class="d">一次 API 请求记一次（Claude 按 requestId 去重）</div></div>
  <div class="card"><div class="k">活跃天数 / 峰值日</div>
    <div class="v">{active_days} 天</div>
    <div class="d">峰值 {peak_day}（{fmt_tok(day_totals[peak_day]["__total_tok"] if peak_day in day_totals else 0)} tokens）</div></div>
</div>

<h2>每日 Token 消耗（按供应商堆叠）</h2>
<div class="chart">{stacked_bar_chart(days, providers, tok_vals)}
<div class="legend">""" + "".join(
        f'<span><span class="dot" style="background:{PROVIDER_COLORS[p]}"></span>{p} '
        f'{fmt_tok(provider_totals[p]["tok"])}</span>' for p in providers) + f"""</div></div>

<h2>按月汇总</h2>
<div class="chart">{stacked_bar_chart(months, m_providers, month_tok_vals, height=240)}
<div class="legend">""" + "".join(
        f'<span><span class="dot" style="background:{PROVIDER_COLORS[p]}"></span>{p}</span>'
        for p in m_providers) + f"""</div></div>

<h2>每日花费（折合人民币，API 价目等价）</h2>
<div class="chart">{stacked_bar_chart(days, providers, cost_vals, height=240, money=True)}</div>
"""]

    h.append(f"""
<h2>统计口径与注意事项</h2>
<div class="notes"><ul>
<li><b>统计范围</b>：{start:%Y-%m-%d} → {end:%Y-%m-%d}（2026 年内本地留存的全部记录，CST 日界，
与 App 一致）。各来源实际覆盖起点不同：Codex 2026-05-25 起、Claude 更早、pi 2026-08-10 起、
Kimi 2026-07-31 → 08-15（日志保留范围有限）。</li>
<li><b>Token 口径</b>：输入(未命中缓存)、缓存读、缓存写、输出(含 reasoning)四列相加；
reasoning 是输出的子集，不重复计入。Codex 日志的 input_tokens 含缓存部分，已做拆分。
Kimi 只计 usageScope=turn 的记录（session 级累计行不重复计）。</li>
<li><b>花费口径</b>：Codex / Claude 为订阅套餐，费用按官方 API 价目折算的"等价价值"（与 App 内
Plan value 同一价格表），并非现金支出；<b>DeepSeek 为真实按量支出</b>（pi 记录精确成本，dsh
与经 Claude Code 路由的调用按模型价目估算）；<b>Kimi（k3-256k）按 Moonshot 平台价 $3/$15、缓存命中 $0.30 每百万 token 估算</b>
（kimi-for-coding 为同一模型的套餐别名，按同价估算），Kimi Coding 套餐额度内实际不产生现金。</li>
<li><b>已知误差</b>：Claude 日志按 requestId 去重（同一请求按内容块重复落盘，77% 请求落盘 2 行）；dsh 的费用为估算值；Codex 逐轮
累加比日志自带累计账本高约 1%（失败轮次回冲）。Cursor / Gemini CLI / opencode 本地无可用
用量记录，未纳入。</li>
""" + ("""<li><b>调度重试</b>：同日同项目同提示词的重复会话（调度器反复拉起）未计入，
共 """ + fmt_tok(sum(v["tok"] for v in RETRY_EXCLUDED.values())) + " tokens ≈" +
     fmt_cny(sum(v["cost_usd"] for v in RETRY_EXCLUDED.values()) * USD_TO_CNY) + """，已剔除。</li>
"""
 if RETRY_EXCLUDED else "") + f"""
<li>汇率按 {USD_TO_CNY}（与 App 显示一致）。</li>
</ul></div>
</div></body></html>""")
    return "".join(h)


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--start", default=None, help="CST 起始日 YYYY-MM-DD（默认 2026-01-01）")
    ap.add_argument("--end", default=None, help="CST 结束日 YYYY-MM-DD（默认今天）")
    ap.add_argument("--out", default=None, help="输出 HTML 路径")
    args = ap.parse_args()

    start = (datetime.strptime(args.start, "%Y-%m-%d").replace(tzinfo=CST)
             if args.start else DEFAULT_START)
    end = ((datetime.strptime(args.end, "%Y-%m-%d").replace(tzinfo=CST) + timedelta(days=1) - timedelta(seconds=1))
           if args.end else datetime.now(CST))
    out = args.out or str(Path(__file__).resolve().parent.parent / "usage-report.html")

    n = {}
    n["codex"] = scan_codex(start, end)
    n["claude"] = scan_claude(start, end)
    n["pi"] = scan_pi(start, end)
    n["dsh"] = scan_dsh(start, end)
    n["antigravity"] = scan_antigravity(start, end)
    n["kimi"] = scan_kimi(start, end)
    files_seen = sum(n.values())

    # (day, provider) totals for charts and the daily table
    day_totals = defaultdict(lambda: {
        "providers": defaultdict(lambda: {"tok": 0, "usd": 0.0, "cny": 0.0, "cny_eq": 0.0}),
        "__total_tok": 0, "__total_cost": 0.0})
    provider_totals = defaultdict(lambda: {"tok": 0, "usd": 0.0, "cny": 0.0, "cny_eq": 0.0, "turns": 0})
    for (day, provider, model), c in USAGE.items():
        tok = c["in_uncached"] + c["cache_read"] + c["cache_write"] + c["out"]
        dt = day_totals[day]
        pv = dt["providers"][provider]
        pv["tok"] += tok
        pv["usd"] += c["cost_usd"]
        pv["cny"] += c["cost_cny"]
        pv["cny_eq"] = pv["usd"] * USD_TO_CNY + pv["cny"]
        dt["__total_tok"] += tok
        dt["__total_cost"] += c["cost_usd"] * USD_TO_CNY + c["cost_cny"]
        pt = provider_totals[provider]
        pt["tok"] += tok
        pt["usd"] += c["cost_usd"]
        pt["cny"] += c["cost_cny"]
        pt["turns"] += c["turns"]

    # monthly aggregation (chart + table)
    month_totals = defaultdict(lambda: {
        "providers": defaultdict(lambda: {"tok": 0, "usd": 0.0, "cny": 0.0, "cny_eq": 0.0}),
        "__total_tok": 0, "__total_cost": 0.0})
    for (day, provider, model), c in USAGE.items():
        tok = c["in_uncached"] + c["cache_read"] + c["cache_write"] + c["out"]
        month = day[:7]
        mt = month_totals[month]
        pv = mt["providers"][provider]
        pv["tok"] += tok
        pv["usd"] += c["cost_usd"]
        pv["cny"] += c["cost_cny"]
        pv["cny_eq"] = pv["usd"] * USD_TO_CNY + pv["cny"]
        mt["__total_tok"] += tok
        mt["__total_cost"] += c["cost_usd"] * USD_TO_CNY + c["cost_cny"]

    model_totals = sorted(USAGE.items(), key=lambda kv: -sum(
        kv[1][k] for k in ("in_uncached", "cache_read", "cache_write", "out")))

    html_doc = build_html(start, end, day_totals,
                          [((k[2], k[1]), c) for k, c in model_totals],
                          provider_totals, files_seen, month_totals)
    Path(out).write_text(html_doc, encoding="utf-8")

    # stdout summary for quick verification
    grand_total = sum(c["in_uncached"] + c["cache_read"] + c["cache_write"] + c["out"]
                      for c in USAGE.values())
    total_usd = sum(c["cost_usd"] for c in USAGE.values())
    total_cny = sum(c["cost_cny"] for c in USAGE.values())
    print(f"files scanned: {n}")
    print(f"window: {start:%Y-%m-%d} → {end:%Y-%m-%d} (CST)")
    print(f"total tokens: {grand_total:,}")
    for p in ("Codex", "Claude", "DeepSeek", "Antigravity", "Kimi", "其他"):
        pt = provider_totals.get(p)
        if pt:
            print(f"  {p:9s} tok={pt['tok']:>13,} turns={pt['turns']:>7,} "
                  f"usd=${pt['usd']:,.2f} cny=¥{pt['cny']:,.2f}")
    print(f"cost: ${total_usd:,.2f} + ¥{total_cny:,.2f} (≈¥{total_usd * USD_TO_CNY + total_cny:,.2f})")
    if RETRY_EXCLUDED:
        ex_tok = sum(v["tok"] for v in RETRY_EXCLUDED.values())
        ex_cost = sum(v["cost_usd"] for v in RETRY_EXCLUDED.values())
        print(f"excluded scheduler retries: {ex_tok:,} tok (≈¥{ex_cost * USD_TO_CNY:,.2f}) "
              f"on {len(RETRY_EXCLUDED)} days: " +
              ", ".join(f"{d}({v['sessions']})" for d, v in sorted(RETRY_EXCLUDED.items())))
    print(f"report: {out}")


if __name__ == "__main__":
    main()
