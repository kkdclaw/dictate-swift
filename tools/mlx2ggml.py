#!/usr/bin/env python3
"""Перегнать модель Whisper из формата MLX (кэш Python-версии dictate) в ggml для whisper.cpp.

    python3 tools/mlx2ggml.py <папка модели MLX> <assets mlx_whisper> <выход.bin>

Папка модели — snapshot в ~/.cache/huggingface/hub/models--mlx-community--whisper-*/snapshots/<rev>
(config.json + weights.safetensors или weights.npz). Assets — mel_filters.npz и multilingual.tiktoken
из пакета mlx_whisper (~/dictate/.venv/lib/python3.12/site-packages/mlx_whisper/assets).

Формат файла — как у convert-pt-to-ggml.py из whisper.cpp. Отличия MLX от весов OpenAI:
свёртки хранятся (out, k, in) вместо (out, in, k); mlp1/mlp2 вместо mlp.0/mlp.2;
encoder.positional_embedding не хранится (синусоиды считаются при загрузке) — считаем сами.
Нужен только numpy."""
import base64, json, os, struct, sys
import numpy as np


def load_safetensors(path):
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        header = json.loads(f.read(n))
        base = 8 + n
    raw = np.memmap(path, dtype=np.uint8, mode="r")
    types = {"F16": np.float16, "F32": np.float32, "BF16": None, "I64": np.int64, "I32": np.int32}
    out = {}
    for name, meta in header.items():
        if name == "__metadata__":
            continue
        dt = types[meta["dtype"]]
        a, b = meta["data_offsets"]
        buf = raw[base + a: base + b]
        if dt is None:  # bfloat16 → float32
            arr = (np.frombuffer(buf, np.uint16).astype(np.uint32) << 16).view(np.float32)
        else:
            arr = np.frombuffer(buf, dt)
        out[name] = arr.reshape(meta["shape"])
    return out


def load_weights(model_dir):
    st = os.path.join(model_dir, "weights.safetensors")
    if os.path.exists(st):
        return load_safetensors(st)
    return dict(np.load(os.path.join(model_dir, "weights.npz")))


def sinusoids(length, channels, max_timescale=10000):
    inc = np.log(max_timescale) / (channels // 2 - 1)
    inv = np.exp(-inc * np.arange(channels // 2))
    t = np.arange(length)[:, None] * inv[None, :]
    return np.concatenate([np.sin(t), np.cos(t)], axis=1).astype(np.float32)


def main(model_dir, assets, out_path):
    hp = json.load(open(os.path.join(model_dir, "config.json")))
    w = load_weights(model_dir)
    if any(k.endswith(".scales") for k in w):
        sys.exit("квантованная модель MLX (есть .scales) — не поддерживается, нужна fp16")
    w.pop("alignment_heads", None)
    w["encoder.positional_embedding"] = sinusoids(hp["n_audio_ctx"], hp["n_audio_state"])

    filters = np.load(os.path.join(assets, "mel_filters.npz"))[f"mel_{hp['n_mels']}"]
    with open(os.path.join(assets, "multilingual.tiktoken")) as f:
        tokens = {base64.b64decode(t): int(r) for t, r in (l.split() for l in f if l.strip())}

    with open(out_path, "wb") as fout:
        fout.write(struct.pack("i", 0x67676D6C))
        for k in ("n_vocab", "n_audio_ctx", "n_audio_state", "n_audio_head", "n_audio_layer",
                  "n_text_ctx", "n_text_state", "n_text_head", "n_text_layer", "n_mels"):
            fout.write(struct.pack("i", hp[k]))
        fout.write(struct.pack("i", 1))  # f16
        fout.write(struct.pack("ii", *filters.shape))
        fout.write(filters.astype(np.float32).tobytes())
        fout.write(struct.pack("i", len(tokens)))
        for key in tokens:
            fout.write(struct.pack("i", len(key)))
            fout.write(key)

        for name in sorted(w):
            data = np.asarray(w[name])
            gname = name.replace(".mlp1.", ".mlp.0.").replace(".mlp2.", ".mlp.2.")
            if gname in ("encoder.conv1.weight", "encoder.conv2.weight"):
                data = data.transpose(0, 2, 1)  # (out, k, in) → (out, in, k)
            data = data.squeeze() if data.ndim > 1 else data
            if gname in ("encoder.conv1.bias", "encoder.conv2.bias"):
                data = data.reshape(data.shape[0], 1)
            small = data.ndim < 2 or gname in ("encoder.conv1.bias", "encoder.conv2.bias",
                                               "encoder.positional_embedding", "decoder.positional_embedding")
            data = np.ascontiguousarray(data.astype(np.float32 if small else np.float16))
            s = gname.encode()
            fout.write(struct.pack("iii", data.ndim, len(s), 0 if small else 1))
            for i in range(data.ndim):
                fout.write(struct.pack("i", data.shape[data.ndim - 1 - i]))
            fout.write(s)
            fout.write(data.tobytes())
    print(f"{out_path}: {len(w)} тензоров, {os.path.getsize(out_path) / 1e9:.2f} ГБ")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
