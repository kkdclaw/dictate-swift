# Замер движков распознавания

Сравнение на реальных диктовках: те же wav, та же подсказка-словарь, что получил Whisper в приложении. Эталона нет. Мерило — расхождение (WER) с выводом Python-версии на large-v3 + словарь, плюс попадание терминов словаря.

Корпус (личный, в git не кладётся): `audio/<id>.wav` + `manifest.json` с полями `id`, `raw`, `text`, `duration`, `app`, `prompt`.

```sh
# 1. корпус с машины, где в Python-версии включена галка «Хранить аудио»
cp -R ~/dictate/audio/ corpus/audio/
(cd ~/dictate && .venv/bin/python <repo>/bench/mkmanifest.py) > corpus/manifest.json

# 2. Python-эталон (mlx-whisper, как в приложении)
cd ~/dictate && .venv/bin/python <repo>/bench/bench_mlx.py corpus/manifest.json corpus/audio mlx-community/whisper-large-v3-turbo out/mlx-turbo.jsonl

# 3. whisper.cpp; модель ggml — из кэша Python-версии, без скачивания:
#    ~/dictate/.venv/bin/python tools/mlx2ggml.py ~/.cache/huggingface/hub/models--mlx-community--whisper-large-v3-turbo/snapshots/* \
#      ~/dictate/.venv/lib/python3.12/site-packages/mlx_whisper/assets ggml-large-v3-turbo.bin
cd bench/whisper-cpp && swift build -c release
.build/release/wcbench corpus/manifest.json corpus/audio ggml-large-v3-turbo.bin out/cpp-turbo.jsonl   # NO_PROMPT=1 — без словаря

# 3б. Parakeet TDT v3 (словаря нет): модель ggml-org/parakeet-GGUF, ggml-parakeet-tdt-0.6b-v3-f16.bin
.build/release/pkbench corpus/manifest.json corpus/audio ggml-parakeet-tdt-0.6b-v3-f16.bin out/pk-f16.jsonl

# 4. сводка
python3 bench/score.py corpus/manifest.json out/*.jsonl
```

Если `wcbench` не находит `whisper.framework` — `DYLD_FRAMEWORK_PATH=.build/release`.
