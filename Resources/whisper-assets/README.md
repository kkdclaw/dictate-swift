# Служебные файлы Whisper

Нужны конвертеру моделей MLX → ggml (`DictateCore/MLXConverter.swift`).

- `multilingual.tiktoken` — словарь токенов Whisper, без изменений.
- `mel_80.f32`, `mel_128.f32` — мел-фильтры из `mel_filters.npz` в сыром виде: float32 little-endian, строки по 201 значению (80×201 и 128×201).

Источник — [openai/whisper](https://github.com/openai/whisper) (`whisper/assets`), лицензия MIT, © 2022 OpenAI.
