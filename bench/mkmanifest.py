import json, os, sqlite3, sys, io
_o = sys.stdout; sys.stdout = io.StringIO()
sys.path.insert(0, os.getcwd())
import dictate
dictate.load_config()
ids = sorted(int(f[:-4]) for f in os.listdir("audio") if f.endswith(".wav"))
db = sqlite3.connect("history.sqlite3")
rows, cache = [], {}
for i in ids:
    r = db.execute("select ts, text, raw_text, duration, app from transcriptions where id=?", (i,)).fetchone()
    if not r: continue
    app = r[4] or ""
    if app not in cache: cache[app] = dictate.asr_hint(app)
    rows.append(dict(id=i, ts=r[0], text=r[1], raw=r[2], duration=r[3], app=app, prompt=cache[app]))
sys.stdout = _o
print(json.dumps(rows, ensure_ascii=False))
