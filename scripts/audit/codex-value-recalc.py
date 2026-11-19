#!/usr/bin/env python3
"""Recompute the Codex plan-value estimate from raw local data.

Why this exists: the app extrapolates `monthly = Σlocal cost / official used_percent`
(CodexValue.extrapolate). That assumes every quota point was earned by tokens in
`~/.codex/sessions`. On an account where part of the weekly quota is consumed by
surfaces that never touch this Mac's Codex client (Codex Cloud executor, remote
control, Dot), the ratio is diluted and the multiple collapses toward 1x.

This script reports both numbers side by side:
  * naive   = Σcost / Δpct            (what the app shows)
  * local   = Σcost / Δpct, counting only 15-minute bins in which the local client
              actually produced tokens (the community calibration in
              stakeswky/Balance docs/subscription-quota-value-algorithm.md §11/§12)

Read-only: parses rollout JSONL + the app's state.json. No network, no writes.

Usage:
  python3 scripts/audit/codex-value-recalc.py
"""

import collections
import datetime
import glob
import json
import os

HOME = os.path.expanduser("~")
STATE = os.path.join(HOME, ".config/howmanyusage/state.json")
APPLE_EPOCH_OFFSET = 978307200  # state.json encodes Date as seconds since 2001-01-01
BIN = datetime.timedelta(minutes=15)
SCAN_DAYS = 9

# $/token, standard short-context API rates; cached input is a subset of input.
# Cross-checked against the official Codex credits table (1 credit ~ $0.04):
#   gpt-6.1-sol 50/2.5/250 cr per MTok = $2 / $0.10 / $10
PRICES = {
    "gpt-6.1-sol": (2.0e-6, 0.1e-6, 10.0e-6),
    "gpt-6-sol": (2.0e-6, 0.2e-6, 10.0e-6),
    "gpt-6-luna": (0.1e-6, 0.01e-6, 0.5e-6),
    "gpt-6-astra": (10.0e-6, 1.0e-6, 50.0e-6),
    "gpt-5.6-sol": (4.0e-6, 0.4e-6, 20.0e-6),
    "gpt-5.6-terra": (2.0e-6, 0.2e-6, 12.0e-6),
    "gpt-5.6-luna": (0.2e-6, 0.02e-6, 1.2e-6),
    "gpt-5.5": (5.0e-6, 0.5e-6, 30.0e-6),
    "gpt-5.4": (2.5e-6, 0.25e-6, 15.0e-6),
    "gpt-5.3-codex": (1.75e-6, 0.175e-6, 14.0e-6),
    "gpt-5.2-codex": (1.75e-6, 0.175e-6, 14.0e-6),
    "gpt-5.1-codex": (1.25e-6, 0.125e-6, 10.0e-6),
    "gpt-5-codex": (1.25e-6, 0.125e-6, 10.0e-6),
}

PLAN_PRICE_USD = {"pro 5x": 100.0, "pro 20x": 200.0, "plus": 20.0}


def parse_ts(value):
    """Rollout timestamps are ISO-8601 UTC; return local naive datetime."""
    try:
        return (
            datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
            .astimezone()
            .replace(tzinfo=None)
        )
    except (TypeError, ValueError):
        return None


def read_state():
    with open(STATE, encoding="utf-8") as handle:
        return json.load(handle)


def window_bounds(state):
    """(start, official used percent, reset) for the current Codex weekly window.

    Note the two encodings in state.json: `lastResetAt` stores a Unix epoch string,
    while `history[].ts` (and providerCache reset markers) are Date values encoded
    as seconds since 2001-01-01.
    """
    reset_raw = state.get("lastResetAt", {}).get("codex.weekly")
    reset = datetime.datetime.fromtimestamp(float(reset_raw)) if reset_raw else None
    start = reset - datetime.timedelta(days=7) if reset else None

    anchors = []
    for entry in state.get("history", []):
        pct = entry.get("codexWeekly")
        if pct is None:
            continue
        ts = datetime.datetime.fromtimestamp(entry["ts"] + APPLE_EPOCH_OFFSET)
        if start and ts < start:
            continue
        anchors.append((ts, float(pct)))
    anchors.sort()
    used = anchors[-1][1] if anchors else None
    if used is None:  # history trimmed/empty: fall back to the cached provider reading
        used = ((state.get("providerCache", {}).get("codex") or {}).get("weekly") or {}).get("usedPercent")
        used = float(used) if used is not None else None
    return start, used, reset, anchors


def collect_turns(start):
    """Every priced `last_token_usage` event inside the window."""
    today = datetime.datetime.now()
    turns = []
    for offset in range(-SCAN_DAYS, 1):
        day = (today + datetime.timedelta(days=offset)).strftime("%Y/%m/%d")
        for path in glob.glob(os.path.join(HOME, ".codex/sessions", day, "*.jsonl")):
            model = None
            with open(path, encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    if '"token_count"' not in line and '"turn_context"' not in line:
                        continue
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    kind = entry.get("type")
                    if kind == "turn_context":
                        name = (entry.get("payload") or {}).get("model")
                        if name:
                            model = name
                        continue
                    payload = entry.get("payload") or {}
                    if payload.get("type") != "token_count":
                        continue
                    usage = (payload.get("info") or {}).get("last_token_usage") or {}
                    ts = parse_ts(entry.get("timestamp"))
                    if not usage or ts is None or (start and ts < start):
                        continue
                    pct = None
                    limits = payload.get("rate_limits") or {}
                    for slot in ("primary", "secondary"):
                        candidate = limits.get(slot) or {}
                        if candidate.get("window_minutes") == 10080:
                            pct = candidate.get("used_percent")
                    inp = usage.get("input_tokens", 0) or 0
                    cached = usage.get("cached_input_tokens", 0) or 0
                    out = usage.get("output_tokens", 0) or 0
                    price = PRICES.get(model)
                    cost = 0.0
                    if price:
                        cost = max(0, inp - cached) * price[0] + cached * price[1] + out * price[2]
                    turns.append(dict(ts=ts, cost=cost, tokens=inp + out, model=model, pct=pct))
    turns.sort(key=lambda t: t["ts"])
    return turns


def split_by_local_activity(turns, anchors, start):
    """Attribute percent rises to 15-minute bins; split local vs external."""
    cost = collections.Counter()
    tokens = collections.Counter()
    models = collections.defaultdict(collections.Counter)
    for turn in turns:
        key = int((turn["ts"] - start).total_seconds() // BIN.total_seconds())
        cost[key] += turn["cost"]
        tokens[key] += turn["tokens"]
        models[key][turn["model"]] += 1

    rises = collections.Counter()
    previous = None
    for ts, pct in anchors:
        if previous is not None:
            delta = pct - previous[1]
            # Ignore resets and gaps longer than two sample intervals (attribution
            # would be meaningless); the app has the same blind spot.
            if 0 < delta <= 25 and (ts - previous[0]) <= datetime.timedelta(minutes=30):
                rises[int((ts - start).total_seconds() // BIN.total_seconds())] += delta
        previous = (ts, pct)

    local_points = external_points = 0
    local_cost = local_tokens = 0.0
    local_models = collections.Counter()
    for key in set(list(rises) + list(cost)):
        delta = rises.get(key, 0.0)
        if delta <= 0:
            continue
        if cost.get(key, 0.0) > 0:
            local_points += delta
            local_cost += cost[key]
            local_tokens += tokens[key]
            local_models.update(models[key])
        else:
            external_points += delta
    return dict(
        local_points=local_points,
        external_points=external_points,
        local_cost=local_cost,
        local_tokens=local_tokens,
        local_models=local_models,
    )


def report(rate_usd_per_point, label, plan="pro 5x"):
    weekly = rate_usd_per_point * 100
    monthly = weekly * 30.44 / 7
    price = PLAN_PRICE_USD.get(plan, 100.0)
    return "%-22s $%7.3f/point -> week $%8.2f -> month $%9.2f -> %5.1fx on %s ($%.0f)" % (
        label,
        rate_usd_per_point,
        weekly,
        monthly,
        monthly / price,
        plan,
        price,
    )


def main():
    state = read_state()
    start, used, reset, anchors = window_bounds(state)
    if start is None or not used:
        print("no Codex weekly window found in state.json")
        return
    turns = collect_turns(start)
    total_cost = sum(t["cost"] for t in turns)
    mix = collections.Counter(t["model"] for t in turns)

    print("Codex plan-value recalculation (read-only)")
    print("  window        : %s -> %s" % (start.strftime("%Y-%m-%d %H:%M"), reset.strftime("%Y-%m-%d %H:%M")))
    print("  official used : %.0f%%   (API samples: %d)" % (used, len(anchors)))
    print("  local turns   : %d priced, API-equivalent $%.2f" % (len(turns), total_cost))
    print("  model mix     : %s" % dict(mix.most_common(4)))
    print()

    naive = total_cost / used
    print(report(naive, "naive (what app shows)"))

    split = split_by_local_activity(turns, anchors, start)
    points = split["local_points"] + split["external_points"]
    if split["local_points"] > 0:
        local_rate = split["local_cost"] / split["local_points"]
        print(report(local_rate, "local-active bins only"))
        print()
        print("  local-active points : %.0f  ($%.2f, %s tokens, %.2fM tokens/point)"
              % (split["local_points"], split["local_cost"],
                 format(int(split["local_tokens"]), ","),
                 split["local_tokens"] / split["local_points"] / 1e6))
        print("  top models there    : %s" % dict(split["local_models"].most_common(3)))
    if points:
        print("  no-local-spend points: %.0f of %.0f  (%.0f%% of this window has no local token behind it)"
              % (split["external_points"], points, 100 * split["external_points"] / points))
    print()
    print("  Note: the local-active rate is still a lower bound — concurrent non-local")
    print("  burn inside an active bin inflates the denominator (fewer $ per point).")


if __name__ == "__main__":
    main()
