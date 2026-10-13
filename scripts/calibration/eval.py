# Step 2: build cluster embeddings exactly like the app, score, and print all tables (markdown) to stdout.
# Run from calib/:  ../.venv/bin/python eval.py > results_raw.md
import json, itertools, collections, sys, numpy as np

R = 20  # random gallery draws per probe
BORDER, STRONG, ENROLL, MARGIN = 0.50, 0.78, 0.82, 0.10  # recommended thresholds, evaluated in the last table
PCT = [0.1, 1, 5, 50, 95, 99, 99.9]
rows = json.load(open("manifest.json")); E = dict(np.load("emb.npz"))
norm = lambda x: x / np.linalg.norm(x, axis=-1, keepdims=True)
E = {k: norm(v) for k, v in E.items()}  # per-excerpt L2 normalisation

# Label error found in MLS: this session is labelled speaker 3503 but scores 0.79-0.89 against every session of speaker 2422 and only
# 0.36-0.42 against 3503's other sessions (a two-reader dialogue recording). Excluded from all trials.
EXCLUDE = {("mls3503", "3742/kriton_1_platon_64kb.mp3")}


def estimate_gender():
    """MLS ships no gender in the HF parquet and the F0 tracker in embed.py turned out unreliable (61.8% vs VoxPopuli labels), so
    gender for MLS is ESTIMATED: project the speaker-mean embedding on the (female mean - male mean) direction learnt from the
    VoxPopuli labels. Returns leave-one-speaker-out accuracy on VoxPopuli."""
    idx = collections.defaultdict(list)
    for i, r in enumerate(rows): idx[r["spk"]].append(i)
    mean = {s: norm(E["c"][v].mean(0)) for s, v in idx.items()}
    lab = {r["spk"]: r["gender"] for r in rows if r["gender_src"] == "label"}
    def fit(spks):
        f = np.mean([mean[s] for s in spks if lab[s] == "f"], 0); m = np.mean([mean[s] for s in spks if lab[s] == "m"], 0)
        return f - m, (f + m) / 2
    pred = lambda s, w, mid: "f" if (mean[s] - mid) @ w > 0 else "m"
    acc = np.mean([pred(s, *fit([t for t in lab if t != s])) == lab[s] for s in lab])
    w, mid = fit(list(lab))
    for r in rows:
        if r["gender_src"] != "label": r["gender"] = pred(r["spk"], w, mid)
    return acc, len(lab)


def cluster(variant, idx):  # app step 1: normalise each excerpt, average, normalise again
    return norm(E[variant][idx].mean(0))


def stats(x):
    x = np.asarray(x)
    if len(x) == 0: return "| 0 |" + " – |" * 11
    p = np.percentile(x, PCT)
    return f"| {len(x)} | {x.mean():.3f} | {x.std():.3f} | {x.min():.3f} | " + " | ".join(f"{v:.3f}" for v in p) + f" | {x.max():.3f} |"


HDR = "| n | mean | std | min | p0.1 | p1 | p5 | p50 | p95 | p99 | p99.9 | max |"


def eer(t, i):
    t, i = np.sort(t), np.sort(i); th = np.unique(np.concatenate([t, i]))
    frr = np.searchsorted(t, th, "left") / len(t); far = 1 - np.searchsorted(i, th, "left") / len(i)
    k = np.argmin(np.abs(far - frr)); return (far[k] + frr[k]) / 2, th[k]


assert abs(eer(np.array([.6, .7, .8, .2]), np.array([.1, .3, .65, .0]))[0] - 0.25) < 1e-9  # self-check


class Corpus:
    def __init__(self, name, min_full):
        self.name, self.min_full = name, min_full
        by = collections.defaultdict(list)
        for i, r in enumerate(rows):
            if r["corpus"] == name and (r["spk"], r["sess"]) not in EXCLUDE: by[(r["spk"], r["sess"])].append((r["j"], i))
        self.sess = []
        for (spk, s), v in sorted(by.items()):
            idx = [i for _, i in sorted(v)]; r = rows[idx[0]]
            self.sess.append(dict(spk=spk, sess=s, book=r["book"], gender=r["gender"], idx=idx, enrol=len(idx) >= min_full))
        self.spk = np.array([s["spk"] for s in self.sess]); self.gender = np.array([s["gender"] for s in self.sess])
        self.book = np.array([s["book"] for s in self.sess]); self.ok = np.array([s["enrol"] for s in self.sess])
        self.persons = sorted({s["spk"] for s in self.sess if s["enrol"]})
        self.psess = {p: [e for e, s in enumerate(self.sess) if s["spk"] == p and s["enrol"]] for p in self.persons}

    def enrol(self, variant):  # one profile sample per session: up to 8 excerpts
        return np.stack([cluster(variant, s["idx"][:8]) for s in self.sess])

    def tests(self, variant, k):  # several test clusters per session
        T, ts = [], []
        for e, s in enumerate(self.sess):
            n = len(s["idx"])
            if k == 8: groups = ([s["idx"][:8]] if n >= self.min_full else []) + ([s["idx"][8:16]] if n >= 16 else [])
            else: groups = [s["idx"][a:a + k] for a in range(0, min(n, 8) - k + 1, k)]
            for g in groups: T.append(cluster(variant, g)); ts.append(e)
        return np.stack(T), np.array(ts)


def verification(c, tv, k, ev, label, extra=False):
    """1-sample and 3-sample profile trials. Returns dict of score arrays."""
    En = c.enrol(ev); T, ts = c.tests(tv, k); S = T @ En.T
    same = c.spk[ts][:, None] == c.spk[None, :]; samesess = ts[:, None] == np.arange(len(c.sess))[None, :]
    ok = np.broadcast_to(c.ok[None, :], S.shape); sameg = c.gender[ts][:, None] == c.gender[None, :]
    sameb = c.book[ts][:, None] == c.book[None, :]
    tgt = S[same & ~samesess & ok]; imp = S[~same & ok]; e, th = eer(tgt, imp)
    print(f"\n**{label}** — 1-sample profile; EER {100 * e:.2f}% at {th:.3f}; {len(T)} test clusters, {len({c.spk[t] for t in ts})} speakers\n\n| set {HDR}\n|---" + "|---" * 12 + "|")
    print("| target (same person, other session)", stats(tgt)); print("| impostor (all)", stats(imp)); print("| impostor (same gender)", stats(S[~same & ok & sameg]))
    if extra and c.name == "mls":
        print("| target, same book / other chapter", stats(S[same & ~samesess & ok & sameb])); print("| target, different book", stats(S[same & ~samesess & ok & ~sameb]))
    # 3-sample profiles: all 3-combinations of a person's sessions (target: excluding the probe's session)
    combos = [(p, cb) for p in c.persons for cb in itertools.combinations(c.psess[p], 3)]
    out = dict(t1=tgt, i1=imp)
    if combos:
        cp = np.array([p for p, _ in combos]); ci = np.array([cb for _, cb in combos])
        Smax = S[:, ci].max(2); Scen = T @ norm(En[ci].mean(1)).T
        csame = c.spk[ts][:, None] == cp[None, :]; cont = (ci[None, :, :] == ts[:, None, None]).any(2)
        four = (csame & ~cont).any(1)  # probes that have a 3-sample target trial (speaker has 3 other sessions)
        m1 = same & ~samesess & ok & four[:, None]
        print(f"\n1 vs 3 enrolled samples ({label}; targets restricted to the {len({s for s, f in zip(c.spk[ts], four) if f})} speakers with 3 other sessions)\n\n| profile | EER | set {HDR}\n|---|---" + "|---" * 12 + "|")
        for name, t, i in (("1 sample", S[m1], imp), ("3 samples, max", Smax[csame & ~cont], Smax[~csame]), ("3 samples, centroid", Scen[csame & ~cont], Scen[~csame])):
            e, th = eer(t, i); print(f"| {name} | {100 * e:.2f}% @ {th:.3f} | target", stats(t)); print(f"| {name} | | impostor", stats(i))
        out.update(t3max=Smax[csame & ~cont], i3max=Smax[~csame], t3cen=Scen[csame & ~cont], i3cen=Scen[~csame])
    return out


def identification(c, tv, k, ev, n, method, rng):
    """Open-set identification with random galleries. n = samples per enrolled person (fewer if the person has fewer sessions).
    Per (probe, draw) and gallery size g in 5/15/all: best and second-best score among g OTHER persons (true speaker not enrolled),
    plus the true person's score when enrolled from sessions other than the probe's (NaN if the speaker has no other session)."""
    En = c.enrol(ev); T, ts = c.tests(tv, k); S = T @ En.T; P = len(c.persons); pid = {p: a for a, p in enumerate(c.persons)}
    o = collections.defaultdict(list)
    for _ in range(R):
        perm = {p: list(rng.permutation(c.psess[p])) for p in c.persons}
        if method == "max": G = np.stack([S[:, perm[p][:n]].max(1) for p in c.persons], 1)
        else: G = T @ norm(np.stack([En[perm[p][:n]].mean(0) for p in c.persons])).T
        for i in range(len(T)):
            me = pid.get(c.spk[ts[i]]); others = rng.permutation(np.delete(G[i], me) if me is not None else G[i])
            for g in GAL:
                top = np.sort(others[:g])[::-1]; o[f"best_{g}"].append(top[0]); o[f"second_{g}"].append(top[1])
            mine = [e for e in perm.get(c.spk[ts[i]], []) if e != ts[i]][:n]
            o["true"].append(np.nan if not mine else S[i, mine].max() if method == "max" else T[i] @ norm(En[mine].mean(0)))
    return {k_: np.array(v) for k_, v in o.items()}, len(T), P


GAL = (5, 15, None)  # None = all other speakers
gname = lambda g: g or "all"


def pr(x, ps=(50, 95, 99, 99.9)):
    return " | ".join(f"{v:.3f}" for v in np.percentile(x, ps)) + f" | {np.max(x):.3f}"


def decisions(o, g, thr, margin):
    """Rule: assign the best person iff best >= thr and (best - second-best person) >= margin.
    Returns (false-ID rate for unenrolled probes, miss rate and mis-ID rate for enrolled probes)."""
    b, s = o[f"best_{g}"], o[f"second_{g}"]
    fa = np.mean((b >= thr) & (b - s >= margin))
    v = ~np.isnan(o["true"]); t, b, s = o["true"][v], b[v], s[v]
    correct = t > b; top = np.maximum(t, b); sec = np.where(correct, b, np.maximum(t, s)); acc = (top >= thr) & (top - sec >= margin)
    return fa, 1 - np.mean(acc & correct), np.mean(acc & ~correct)


if __name__ == "__main__":
    rng = np.random.default_rng(1)
    acc, nlab = estimate_gender()
    print(f"MLS gender is estimated from the embedding (VoxPopuli-trained direction); leave-one-speaker-out accuracy on VoxPopuli labels: {100 * acc:.1f}% of {nlab} speakers")
    print("MLS estimated gender by split:", {sp: dict(collections.Counter(g for g in {r["spk"]: r["gender"] for r in rows if r["split"] == sp and r["corpus"] == "mls"}.values())) for sp in ("dev", "test", "train_sel")})
    for name, min_full in (("mls", 8), ("vp", 3)):
        c = Corpus(name, min_full)
        ns = collections.Counter(len(v) for v in c.psess.values())
        g = collections.Counter(c.gender[c.psess[p][0]] for p in c.persons)
        print(f"\n# {name.upper()}\n\n{len(c.persons)} speakers ({ {str(a): b for a, b in g.items()} }), {int(c.ok.sum())} enrolment-capable sessions ({len(c.sess)} total); sessions/speaker histogram {sorted(ns.items())}; "
              f"excerpts per enrolment sample: {sorted(collections.Counter(min(len(s['idx']), 8) for s in c.sess if s['enrol']).items())}")
        L = np.array([min(r["L"], r["nat_len"]) / 16000 for r in rows if r["corpus"] == name])
        print(f"excerpt length (s): mean {L.mean():.1f}, p5 {np.percentile(L, 5):.1f}, p50 {np.percentile(L, 50):.1f}, p95 {np.percentile(L, 95):.1f}")
        conds = [("(a) clean test, 8 excerpts vs clean enrol", "c", 8, "c"), ("(b) clean test, 2 excerpts vs clean enrol", "c", 2, "c"),
                 ("(c) degraded test, 8 excerpts vs clean enrol", "d", 8, "c"), ("(c2) degraded test, 2 excerpts vs clean enrol", "d", 2, "c"),
                 ("(c3) degraded test, 8 excerpts vs degraded enrol", "d", 8, "d")]
        print("\n## Verification score distributions")
        for i, (label, tv, k, ev) in enumerate(conds): verification(c, tv, k, ev, label, extra=(i == 0))

        print("\n## Amount of speech (clean test cluster vs clean 8-excerpt enrolment sample, 1-sample profile)\n")
        print("| excerpt length | #excerpts | EER | target mean | target p1 | target p5 | impostor p99 | impostor p99.9 | impostor max |\n|---|---|---|---|---|---|---|---|---|")
        En = c.enrol("c")
        for v, vl in (("c3", "3 s"), ("c", "mixed 3-10 s" if name == "mls" else "natural"), ("c10", "10 s")):
            if name == "vp" and v == "c10": continue
            for k in (1, 2, 4, 8):
                T, ts = c.tests(v, k); S = T @ En.T; same = c.spk[ts][:, None] == c.spk[None, :]; ss = ts[:, None] == np.arange(len(c.sess))[None, :]
                t, i = S[same & ~ss & c.ok[None, :]], S[~same & c.ok[None, :]]; e, _ = eer(t, i)
                print(f"| {vl} | {k} | {100 * e:.2f}% | {t.mean():.3f} | {np.percentile(t, 1):.3f} | {np.percentile(t, 5):.3f} | {np.percentile(i, 99):.3f} | {np.percentile(i, 99.9):.3f} | {i.max():.3f} |")
        T2, ts2 = c.tests("c", 2); S = T2 @ T2.T; same = c.spk[ts2][:, None] == c.spk[ts2][None, :]; ss = ts2[:, None] == ts2[None, :]
        e, _ = eer(S[same & ~ss], S[~same])
        print(f"| 2 excerpts vs 2 excerpts (weak enrolment sample) | 2 | {100 * e:.2f}% | {S[same & ~ss].mean():.3f} | {np.percentile(S[same & ~ss], 1):.3f} | {np.percentile(S[same & ~ss], 5):.3f} | {np.percentile(S[~same], 99):.3f} | {np.percentile(S[~same], 99.9):.3f} | {S[~same].max():.3f} |")

        print("\n## Open-set identification: best impostor score when the true speaker is NOT enrolled\n")
        print(f"{R} random galleries per probe. Percentiles of max-over-gallery score.\n\n| condition | profile | gallery | n | p50 | p95 | p99 | p99.9 | max |\n|---|---|---|---|---|---|---|---|---|")
        ident = {}
        for label, tv, k, ev in conds:
            for n, method in ((1, "max"), (3, "max"), (3, "centroid")):
                o, nt, P = identification(c, tv, k, ev, n, method, rng); ident[(label, n, method)] = o
                for g in GAL:
                    print(f"| {label} | {n} sample{'s' if n > 1 else ''} {method if n > 1 else ''} | {g or f'all ({P - 1}-{P})'} | {len(o['true'])} ({nt} probes) | {pr(o[f'best_{g}'])} |")

        print("\n## Margin (best − second-best person)\n")
        print("| condition | profile | gallery | case | n | p1 | p5 | p50 | p95 | p99 | max |\n|---|---|---|---|---|---|---|---|---|---|---|")
        ps = (1, 5, 50, 95, 99)
        for (label, n, method), o in ident.items():
            if method == "centroid": continue
            for g in GAL:
                v = ~np.isnan(o["true"]); t, b, s = o["true"][v], o[f"best_{g}"][v], o[f"second_{g}"][v]; correct = t > b
                print(f"| {label} | {n} | {gname(g)} | correct best-match (true speaker enrolled) | {correct.sum()} | {pr((t - b)[correct], ps)} |")
                if (~correct).any(): print(f"| {label} | {n} | {gname(g)} | false best-match (true speaker enrolled; {100 * np.mean(~correct):.2f}% of probes) | {(~correct).sum()} | {pr((b - np.maximum(t, s))[~correct], ps)} |")
                print(f"| {label} | {n} | {gname(g)} | false best-match (true speaker NOT enrolled) | {len(o['true'])} | {pr(o[f'best_{g}'] - o[f'second_{g}'], ps)} |")

        print("\n## Threshold grid\n\nRule: assign iff best >= T and best − second >= M. false-ID = worst case over gallery sizes 5/15/all and profiles (1, 3 max) for "
              "unenrolled probes; miss = enrolled probe not assigned to its true person (gallery all); mis-ID = enrolled probe assigned to a wrong person (worst over galleries).\n")
        short = [l.split(")")[0] + ")" for l, *_ in conds]
        print("| T | M | profile | " + " | ".join(f"false-ID {s_}" for s_ in short) + " | " + " | ".join(f"miss {s_}" for s_ in short) + " | max mis-ID |\n|---" * 1 + "|---" * (3 + 2 * len(short)) + "|")
        for thr in (0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70, 0.72, 0.75, 0.78, 0.80, 0.82, 0.85):
            for mg in (0, 0.10, 0.15, 0.20):
                for prof in ((1, "max"), (3, "max"), (3, "centroid")):
                    fas, misses, mis = [], [], 0
                    for label, *_ in conds:
                        r_ = [decisions(ident[(label, *prof)], g, thr, mg) for g in GAL]
                        fas.append(max(x[0] for x in r_)); misses.append(r_[-1][1]); mis = max(mis, max(x[2] for x in r_))
                    print(f"| {thr:.2f} | {mg:.2f} | {prof[0]} {prof[1]} | " + " | ".join(f"{100 * x:.2f}%" for x in fas) + " | " + " | ".join(f"{100 * x:.1f}%" for x in misses) + f" | {100 * mis:.2f}% |")
        print(f"\n## Recommended thresholds: borderline {BORDER}, strong {STRONG}, enroll {ENROLL}, margin {MARGIN} (margin applied below strong)\n")
        print("Unenrolled probe: cand = shown as candidate (best >= borderline and margin ok), by gallery size 5/15/all; false-ID = best >= strong; false-enrol = best >= enroll (both worst over gallery sizes). "
              "Enrolled probe (gallery all): auto = true person >= strong and best; band = true person is best, in [borderline, strong), margin ok; lost = neither; "
              "enrol-ok = true person >= enroll; wrong = a wrong person is best and passes borderline+margin.\n")
        print("| condition | profile | cand g=5 | cand g=15 | cand g=all | false-ID | false-enrol | auto | band | lost | enrol-ok | wrong |\n" + "|---" * 12 + "|")
        for (label, n, method), o in ident.items():
            cand = [np.mean((o[f"best_{g}"] >= STRONG) | ((o[f"best_{g}"] >= BORDER) & (o[f"best_{g}"] - o[f"second_{g}"] >= MARGIN))) for g in GAL]
            fid = max(np.mean(o[f"best_{g}"] >= STRONG) for g in GAL); fen = max(np.mean(o[f"best_{g}"] >= ENROLL) for g in GAL)
            v = ~np.isnan(o["true"]); t, b, s_ = o["true"][v], o["best_None"][v], o["second_None"][v]; ok = t > b
            auto = ok & (t >= STRONG); band = ok & ~auto & (t >= BORDER) & (t - b >= MARGIN)
            wrong = ~ok & ((b >= STRONG) | ((b >= BORDER) & (b - np.maximum(t, s_) >= MARGIN)))
            print(f"| {label} | {n} {method} | " + " | ".join(f"{100 * x:.1f}%" for x in cand) + f" | {100 * fid:.2f}% | {100 * fen:.2f}% | {100 * auto.mean():.1f}% | {100 * band.mean():.1f}% | "
                  f"{100 * abs(1 - auto.mean() - band.mean()):.1f}% | {100 * np.mean(ok & (t >= ENROLL)):.1f}% | {100 * wrong.mean():.2f}% |")
        np.savez(f"ident_{name}.npz", **{f"{l.split(')')[0][1:]}|{n}|{m}|{k_}": v for (l, n, m), o in ident.items() for k_, v in o.items()})
