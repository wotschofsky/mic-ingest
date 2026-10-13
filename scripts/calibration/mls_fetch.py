# Fetch selected row groups (one per speaker+book, up to 4 books for speakers with >=3 books) of MLS German train
# via exact HTTP range requests -> data/mls_train_sel.parquet
import pyarrow as pa, pyarrow.parquet as pq, fsspec, json, collections, concurrent.futures as cf
from mls_footers import BASE
R = json.load(open("data/mls_train_rg.json"))
d = collections.defaultdict(lambda: collections.defaultdict(list))
for r in R:
    if r["spk"][0] == r["spk"][1] and r["book"][0] == r["book"][1] and r["n"] == 100: d[r["spk"][0]][r["book"][0]].append(r)
sel = []
for s, books in sorted(d.items()):
    if len(books) < 3: continue
    for b in sorted(books, key=lambda b: len(books[b]))[:4]:  # smallest books first: fewer chapters -> more utts per mp3
        sel.append(books[b][0])
print(len({r["spk"][0] for r in sel}), "speakers", len(sel), "row groups", round(sum(r["bytes"] for r in sel) / 1e6), "MB")
by_shard = collections.defaultdict(list)
for r in sel: by_shard[r["shard"]].append(r["rg"])
COLS = ["audio", "original_path", "audio_duration", "speaker_id", "chapter_id", "id"]
def fetch(item):
    i, rgs = item
    with fsspec.filesystem("http").open(BASE.format(i), cache_type="none") as fh:
        return pq.ParquetFile(fh, pre_buffer=True).read_row_groups(rgs, columns=COLS)
if __name__ == "__main__":
    with cf.ThreadPoolExecutor(6) as ex: tabs = list(ex.map(fetch, sorted(by_shard.items())))
    pq.write_table(pa.concat_tables(tabs), "data/mls_train_sel.parquet", row_group_size=100)
    print("done")
