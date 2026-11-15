"""Сводка Ф0: скорость, пустые, WER к эталону (вывод large-v3 + словарь), попадание терминов словаря."""
import json, re, statistics as st, sys
man = {r["id"]: r for r in json.load(open(sys.argv[1]))}

def norm(s):
    s = s.lower().replace("ё", "е")
    return re.sub(r"[^\w\s]", " ", s).split()

def wer(ref, hyp):
    r, h = norm(ref), norm(hyp)
    d = list(range(len(h) + 1))
    for i, rw in enumerate(r, 1):
        prev, d[0] = d[0], i
        for j, hw in enumerate(h, 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (rw != hw))
            prev, d[j] = d[j], cur
    return d[len(h)], max(1, len(r))

def terms(prompt):
    return [t.strip() for t in prompt.rstrip(".").split(",") if t.strip() and t.strip() != "задеплоить"]

print(f"{'движок':34} {'n':>4} {'пустых':>6} {'медиана с':>9} {'p90 с':>6} {'×реалт':>7} {'WER%':>6} {'термины':>9}")
for path in sys.argv[2:]:
    rows = [json.loads(l) for l in open(path)]
    secs = sorted(r["sec"] for r in rows)
    dur = sum(r["dur"] for r in rows)
    empty = sum(1 for r in rows if not r["text"].strip())
    e = n = 0; th = tt = 0
    for r in rows:
        m = man[r["id"]]
        a, b = wer(m["raw"], r["text"]); e += a; n += b
        ref, hyp = m["raw"].lower(), r["text"].lower()
        for t in terms(m["prompt"]):
            if len(t) >= 3 and t.lower() in ref:
                tt += 1; th += t.lower() in hyp
    name = path.split("/")[-1].replace(".jsonl", "")
    print(f"{name:34} {len(rows):4} {empty:6} {st.median(secs):9.2f} {secs[int(len(secs)*0.9)]:6.2f} {dur/sum(secs):7.1f} {100*e/n:6.1f} {th:4}/{tt:<4}")
