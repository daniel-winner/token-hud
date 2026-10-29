#!/usr/bin/env python3
"""独立实现的交叉对账脚本（不复用 Swift 逻辑）。

口径与 UsageStore 一致，但代码路径完全独立，用于验证 Swift 实现的正确性。
"""
import json, os, glob, datetime, sys

ROOT = os.path.expanduser("~/.workbuddy/projects")
today = datetime.date.today()
START = int(datetime.datetime.combine(today, datetime.time.min).timestamp() * 1000)
END = START + 86400000


def extract_text(content):
    if isinstance(content, list):
        return "".join(i.get("text", "") for i in content if isinstance(i, dict))
    if isinstance(content, str):
        return content
    return ""


def is_real_user(text):
    i = text.find("<user_query>")
    if i >= 0:
        j = text.find("</user_query>", i)
        if j >= 0:
            return bool(text[i + len("<user_query>"):j].strip())
    t = text.lstrip()
    for p in ("<system-reminder", "<identity_context", "<command-name",
              "<local-command-stdout", "<user_memory", "<product_identity"):
        if t.startswith(p):
            return False
    return True


def main():
    inp = out = cached = reasoning = calls = turns = 0
    gens = []
    sessions = set()
    models = {}
    files = [p for p in glob.glob(os.path.join(ROOT, "**", "*.jsonl"), recursive=True)
             if datetime.date.fromtimestamp(os.path.getmtime(p)) == today]

    for p in files:
        boundary = 0
        with open(p, encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                ts = d.get("timestamp")
                if ts is None or not (START <= ts < END):
                    continue
                t = d.get("type")
                if t == "function_call_result":
                    boundary = ts
                    continue
                if t == "message" and d.get("role") == "user":
                    if is_real_user(extract_text(d.get("content"))):
                        turns += 1
                        boundary = ts  # 真实用户提问 = 本轮请求起点
                    continue
                pd = d.get("providerData") or {}
                u = pd.get("usage")
                if not u:
                    continue
                calls += 1
                i_ = u.get("inputTokens", 0) or 0
                o_ = u.get("outputTokens", 0) or 0
                inp += i_
                out += o_
                cached += sum(x.get("cached_tokens", 0) for x in (u.get("inputTokensDetails") or []))
                reasoning += sum(x.get("reasoning_tokens", 0) for x in (u.get("outputTokensDetails") or []))
                sid = d.get("sessionId")
                if sid:
                    sessions.add(sid)
                m = pd.get("requestModelName") or pd.get("requestModelId") or pd.get("model") or "unknown"
                st = models.setdefault(m, {"calls": 0, "tokens": 0, "ms": 0, "out": 0})
                st["calls"] += 1
                st["tokens"] += u.get("totalTokens") or (i_ + o_)
                if boundary and ts > boundary:
                    ms = ts - boundary
                    gens.append((ts, ms, o_))
                    st["ms"] += ms
                    st["out"] += o_

    gens.sort()
    total_ms = sum(g[1] for g in gens)
    total_out = sum(g[2] for g in gens)
    avg = total_out / (total_ms / 1000.0) if total_ms else 0
    last = gens[-1][2] / (gens[-1][1] / 1000.0) if gens and gens[-1][1] else 0

    print(f"sessions      : {len(sessions)}")
    print(f"llmCalls      : {calls}")
    print(f"userTurns     : {turns}")
    print(f"input         : {inp}")
    print(f"output        : {out}")
    print(f"total         : {inp + out}")
    print(f"cached        : {cached} ({cached / inp * 100 if inp else 0:.1f}%)")
    print(f"reasoning     : {reasoning}")
    print(f"generations   : {len(gens)}")
    print(f"lastSpeed     : {last:.1f} tok/s")
    print(f"avgSpeed      : {avg:.1f} tok/s")
    print("--- models ---")
    for m, st in sorted(models.items(), key=lambda kv: -kv[1]["calls"]):
        a = st["out"] / (st["ms"] / 1000.0) if st["ms"] else 0
        print(f"  {m:<24} calls={st['calls']:<5} tokens={st['tokens']:<12} avgSpeed={a:.1f}")


if __name__ == "__main__":
    main()
