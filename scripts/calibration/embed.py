# Step 1: select sessions/utterances, build clean + degraded excerpts, embed with the Core ML pair.
# Output: emb.npz (one [n_utts,256] array per variant) + manifest.json (one row per utterance).
# Run from calib/:  ../.venv/bin/python embed.py
import io, json, collections, numpy as np, soundfile as sf, pyarrow.parquet as pq, coremltools as ct
from scipy.signal import fftconvolve

SR, N, F, SEED = 16000, 160000, 589, 20261002
MAX_UTT, MAX_SESS = 16, 4  # utterances kept per session, sessions kept per speaker
fb = ct.models.CompiledMLModel("../FBank.mlmodelc"); em = ct.models.CompiledMLModel("../Embedding.mlmodelc")


def decode(b):
    x, sr = sf.read(io.BytesIO(b), dtype="float32"); assert sr == SR and x.ndim == 1
    return x[:N]  # app rule: an utterance longer than 10 s contributes its first 10 s


def load_mls(split):
    """session = one LibriVox mp3 (one chapter recording) with >= 8 utterances; book = MLS 'chapter_id'."""
    pf = pq.ParquetFile(f"data/mls_{split}.parquet")
    meta = pf.read(columns=["original_path", "speaker_id", "chapter_id", "id"]).to_pylist()
    by = collections.defaultdict(lambda: collections.defaultdict(list))
    for i, r in enumerate(meta): by[r["speaker_id"]][(r["chapter_id"], r["original_path"].split("/")[-1])].append((r["id"], i))
    want = {}
    for spk, sess in by.items():
        sess = {k: sorted(v)[:MAX_UTT] for k, v in sess.items() if len(v) >= 8}
        if split == "train_sel":  # one session per book: the mp3 with most utterances in the fetched row group
            best = {}
            for k in sorted(sess, key=lambda k: -len(sess[k])): best.setdefault(k[0], k)
            keys = list(best.values())[:MAX_SESS]
        else:  # dev/test: up to MAX_SESS mp3s, distinct books first, then by size
            order, seen = [], set()
            for k in sorted(sess, key=lambda k: -len(sess[k])):
                if k[0] not in seen: seen.add(k[0]); order.append(k)
            order += [k for k in sorted(sess, key=lambda k: -len(sess[k])) if k not in order]
            keys = order[:MAX_SESS]
        for k in keys:
            for j, (_, i) in enumerate(sess[k]): want[i] = dict(corpus="mls", split=split, spk="mls" + spk, book=k[0], sess=f"{k[0]}/{k[1]}", gender=None, j=j)
    return read_audio(pf, want)


def load_vp():
    """session = one plenary date for one speaker; utterances >= 3 s; sessions with >= 2 such utterances."""
    pf = pq.ParquetFile("data/vp_test.parquet")
    meta = pf.read(columns=["audio_id", "speaker_id", "gender"]).to_pylist()
    rows = read_audio(pf, {i: dict(corpus="vp", split="test", spk="vp" + r["speaker_id"], book=r["audio_id"][:8], sess=r["audio_id"][:8],
                                   gender=r["gender"][0], aid=r["audio_id"]) for i, r in enumerate(meta) if r["speaker_id"] != "None"})
    by = collections.defaultdict(list)
    for r in rows:
        if r["full_len"] >= 3 * SR: by[(r["spk"], r["sess"])].append(r)
    out = []
    for (spk, sess), v in sorted(by.items()):
        if len(v) < 2: continue
        v = sorted(v, key=lambda r: r["aid"])[:MAX_UTT]
        for j, r in enumerate(v): r["j"] = j
        out += v
    # cap sessions per speaker like MLS (largest first)
    cnt = collections.Counter((r["spk"], r["sess"]) for r in out); keep = collections.defaultdict(list)
    for (spk, sess), c in sorted(cnt.items(), key=lambda kv: -kv[1]): keep[spk].append(sess)
    return [r for r in out if r["sess"] in keep[r["spk"]][:6]]


def read_audio(pf, want):
    out, base = [], 0
    for g in range(pf.metadata.num_row_groups):
        n = pf.metadata.row_group(g).num_rows; idx = [i for i in range(base, base + n) if i in want]
        if idx:
            col = pf.read_row_group(g, columns=["audio"]).column("audio").to_pylist()
            for i in idx:
                b = col[i - base]["bytes"]; x = decode(b); full = len(sf.SoundFile(io.BytesIO(b)))
                out.append(dict(want[i], wav=x, full_len=full))
        base += n
    return out


def f0_median(x):
    """Crude autocorrelation pitch tracker. NOT USED downstream: it agreed with only 61.8% of VoxPopuli gender labels,
    so eval.py estimates MLS gender from the embeddings instead. Kept because the saved manifest was produced with it."""
    f0 = []; thr = 0.3 * np.sqrt(np.mean(x ** 2))
    for s in range(0, len(x) - 640, 320):
        fr = x[s:s + 640] - x[s:s + 640].mean()
        if np.sqrt(np.mean(fr ** 2)) < thr: continue
        ac = np.correlate(fr, fr, "full")[639:]; lo, hi = SR // 400, SR // 60
        k = lo + int(np.argmax(ac[lo:hi]))
        if ac[k] > 0.5 * ac[0]: f0.append(SR / k)
    return float(np.median(f0)) if f0 else float("nan")


def pink(n, rng):
    X = np.fft.rfft(rng.standard_normal(n)); X[1:] /= np.sqrt(np.arange(1, len(X))); X[0] = 0
    return np.fft.irfft(X, n)


def room(rng):
    """Synthetic room for one session: exp-decaying noise IR. DRR -7..0 dB ~ talker 1-2 m from the mic in a small room."""
    rt60, drr, snr = rng.uniform(0.4, 0.6), rng.uniform(-7, 0), rng.uniform(5, 10)
    t = np.arange(int(1.2 * rt60 * SR)) / SR
    tail = rng.standard_normal(len(t)) * np.exp(-6.908 * t / rt60); tail[:32] = 0  # 2 ms gap after the direct sound
    tail /= np.sqrt(np.sum(tail ** 2))
    h = tail * 10 ** (-drr / 20); h[0] = 1.0  # energy(direct)/energy(tail) = DRR
    return dict(rt60=rt60, drr=drr, snr=snr, h=h.astype(np.float32), hd=tail.astype(np.float32))


def degrade(x, L, rm, others, rng):
    """Reverb + babble (4-6 other speakers, diffuse) + pink noise at rm['snr'] dB, then -20 dB attenuation. x: <=10 s clean."""
    y = fftconvolve(x, rm["h"])[:len(x)]
    bab = np.zeros(N, np.float32)
    for o in others:
        o = np.resize(o, N); bab += np.roll(o, rng.integers(N)) / (np.sqrt(np.mean(o ** 2)) + 1e-9)
    bab = fftconvolve(bab, rm["hd"])[:len(x)]
    pk = pink(len(x), rng); noise = bab + pk * np.sqrt(np.mean(bab ** 2) / np.mean(pk ** 2)) * 10 ** (-10 / 20)
    y, noise = y[:L], noise[:L]
    noise *= np.sqrt(np.mean(y ** 2) / np.mean(noise ** 2)) * 10 ** (-rm["snr"] / 20)
    out = 0.1 * (y + noise)
    assert abs(10 * np.log10(np.mean((0.1 * y) ** 2) / np.mean((0.1 * noise) ** 2)) - rm["snr"]) < 1e-3  # self-check: SNR as intended
    return out.astype(np.float32)


def embed(excerpts):
    out = []
    for s in range(0, len(excerpts), 32):
        chunk = excerpts[s:s + 32]
        a = np.stack([np.resize(x, N) for x in chunk])[:, None].astype(np.float32)  # loop-pad to 10 s
        feats = fb.predict({"audio": a})["fbank_features"]
        out.append(em.predict({"fbank_features": feats, "weights": np.ones((len(chunk), F), np.float32)})["embedding"].reshape(len(chunk), -1))
        if s % 640 == 0: print(f"  {s}/{len(excerpts)}", flush=True)
    return np.concatenate(out)


if __name__ == "__main__":
    rows = load_mls("dev") + load_mls("test") + load_mls("train_sel") + load_vp()
    print(len(rows), "utterances;", {c: len({r["spk"] for r in rows if r["corpus"] == c}) for c in ("mls", "vp")}, "speakers;",
          {c: len({(r["spk"], r["sess"]) for r in rows if r["corpus"] == c}) for c in ("mls", "vp")}, "sessions")
    rng = np.random.default_rng(SEED)
    # gender: VoxPopuli label; MLS estimated from median F0 over the speaker's utterances (threshold 160 Hz)
    f0 = collections.defaultdict(list)
    for r in rows:
        if r["j"] < 2: f0[r["spk"]].append(f0_median(r["wav"]))
    f0 = {s: float(np.nanmedian(v)) for s, v in f0.items()}
    for r in rows:
        r["f0"] = f0[r["spk"]]; r["gender_src"] = "label" if r["gender"] else "f0"
        r["gender"] = r["gender"] or ("m" if f0[r["spk"]] < 160 else "f")
    # excerpt length: MLS utterances are all 10-20 s, so draw 3-10 s to mimic diarised turns; VoxPopuli keeps natural length
    rooms, by_corpus = {}, collections.defaultdict(list)
    for i, r in enumerate(rows):
        r["L"] = int(rng.uniform(3, 10) * SR) if r["corpus"] == "mls" else len(r["wav"])
        by_corpus[r["corpus"]].append(i)
        if (r["spk"], r["sess"]) not in rooms: rooms[(r["spk"], r["sess"])] = room(rng)
    V = {"c": [], "c3": [], "c10": [], "d": []}
    for i, r in enumerate(rows):
        x = r["wav"]; pool = by_corpus[r["corpus"]]; others = []
        while len(others) < rng.integers(4, 7):
            o = rows[pool[rng.integers(len(pool))]]
            if o["spk"] != r["spk"]: others.append(o["wav"])
        V["c"].append(x[:r["L"]]); V["c3"].append(x[:3 * SR]); V["c10"].append(x)
        V["d"].append(degrade(x, r["L"], rooms[(r["spk"], r["sess"])], others, rng))
    E = {}
    for k, v in V.items():
        print("embedding variant", k, flush=True); E[k] = embed(v)
    np.savez("emb.npz", **E)
    for r in rows:
        rm = rooms[(r["spk"], r["sess"])]; r.update(rt60=rm["rt60"], drr=rm["drr"], snr=rm["snr"], nat_len=len(r["wav"])); del r["wav"]
    json.dump(rows, open("manifest.json", "w"))
    print("saved", {k: v.shape for k, v in E.items()})
