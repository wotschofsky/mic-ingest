# Step 3: assemble RESULTS.md = prose + tables copied verbatim from results_raw.md (no hand-typed table numbers).
# Run from calib/:  ../.venv/bin/python make_results.py
import re
raw = open("results_raw.md").read().split("\n# ")
sec = {"MLS": raw[1], "VP": raw[2]}
short = lambda l: l.replace("clean test, ", "clean, ").replace("degraded test, ", "degraded, ").replace(" excerpts vs ", " exc vs ").replace(" enrol |", " |")
SEP = lambda n: "|---" * n + "|"


def dist():
    out = ["| corpus | condition (test vs profile, 1 sample) | EER | set | n | mean | std | min | p0.1 | p1 | p5 | p50 | p95 | p99 | p99.9 | max |", SEP(16)]
    for c, s in sec.items():
        for m in re.finditer(r"\*\*(\(.+?)\*\* — 1-sample profile; EER ([\d.]+%) at ([\d.]+).*?\n\n\| set.*?\n\|---.*?\n((?:\|.*\n)+)", s):
            for line in m.group(4).strip().split("\n"):
                out.append(f"| {c} | {short(m.group(1) + ' |')[:-2]} | {m.group(2)} @ {m.group(3)} {line.replace('(same person, other session)', '').replace('impostor (all)', 'impostor')}")
    return "\n".join(out)


def grab(title, keep, head):
    out = [head, SEP(head.count("|") - 1)]
    for c, s in sec.items():
        block = s.split(title)[1].split("\n## ")[0]
        out += [f"| {c} {short(l)}" for l in block.split("\n") if l.startswith("| (") and keep(l)]
    return "\n".join(out)


speech = sec["MLS"].split("## Amount of speech")[1].split("\n## ")[0].strip().split("\n", 2)[2]
T = dict(
    dist=dist(),
    openset=grab("## Open-set identification", lambda l: "3 samples max" in l, "| corpus | condition | profile | gallery size | n draws (probes) | p50 | p95 | p99 | p99.9 | max |"),
    margin=grab("## Margin", lambda l: re.match(r"\| \((a|c|c3)\) ", l) and "| 1 |" in l, "| corpus | condition | profile samples | gallery | case | n | p1 | p5 | p50 | p95 | p99 | max |"),
    rec=grab("## Recommended thresholds", lambda l: "centroid" not in l, "| corpus | condition | profile | cand g=5 | cand g=15 | cand g=all | false-ID | false-enrol | auto | band | lost | enrol-ok | wrong |"),
    cen=grab("## Recommended thresholds", lambda l: "3 " in l.split("|")[2], "| corpus | condition | profile | cand g=5 | cand g=15 | cand g=all | false-ID | false-enrol | auto | band | lost | enrol-ok | wrong |"),
    speech=speech)
open("RESULTS.md", "w").write(open("RESULTS.template.md").read().format(**T))
print("RESULTS.md written,", len(open("RESULTS.md").read().split()), "tokens incl. tables")
