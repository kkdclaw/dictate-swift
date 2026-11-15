"""Ф0: mlx-whisper как в dictate — language=ru, initial_prompt, word_timestamps. Вывод JSONL."""
import json, os, re, subprocess, sys, time
import numpy as np, soundfile as sf
import mlx_whisper
import mlx.core as mx

manifest, audio_dir, repo, out = sys.argv[1:5]
limit = int(sys.argv[5]) if len(sys.argv) > 5 else 0
rows = json.load(open(manifest))
if limit: rows = rows[:limit]

def load(i):
    a, sr = sf.read(os.path.join(audio_dir, f"{i}.wav"), dtype="float32")
    assert sr == 16000
    return a

t0 = time.time()
mlx_whisper.transcribe(np.zeros(8000, np.float32), path_or_hf_repo=repo, language="ru")  # загрузка + прогрев
load_s = time.time() - t0
with open(out, "w") as f:
    for r in rows:
        a = load(r["id"])
        t = time.time()
        res = mlx_whisper.transcribe(a, path_or_hf_repo=repo, language="ru",
                                     initial_prompt=r["prompt"] or None, word_timestamps=True)
        dt = time.time() - t
        f.write(json.dumps(dict(id=r["id"], sec=round(dt, 3), dur=len(a) / 16000,
                                text=res["text"].strip()), ensure_ascii=False) + "\n")
        f.flush()
fp = subprocess.run(["footprint", str(os.getpid())], capture_output=True, text=True).stdout
m = re.search(r"Footprint: ([\d.]+ [KMG]B)", fp)
print(json.dumps(dict(engine="mlx-whisper", model=repo, load_s=round(load_s, 2),
                      footprint=m.group(1) if m else "?", peak_metal_gb=round(mx.get_peak_memory() / 1e9, 2))))
