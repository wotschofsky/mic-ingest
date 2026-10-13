# Read ONLY the parquet footers of the 63 MLS German train shards (exact HTTP range requests, ~0.2 MB each)
# and save per-row-group stats (speaker/book/mp3 min-max, byte size) -> data/mls_train_rg.json
import pyarrow.parquet as pq, fsspec, json, concurrent.futures as cf
BASE = "https://huggingface.co/datasets/facebook/multilingual_librispeech/resolve/main/german/train-{:05d}-of-00063.parquet"
def scan(i):
    with fsspec.filesystem("http").open(BASE.format(i), cache_type="none") as fh:
        md = pq.ParquetFile(fh).metadata
    out = []
    for g in range(md.num_row_groups):
        rg = md.row_group(g); st = {rg.column(j).path_in_schema: rg.column(j).statistics for j in range(rg.num_columns)}
        out.append(dict(shard=i, rg=g, n=rg.num_rows, bytes=sum(rg.column(j).total_compressed_size for j in range(rg.num_columns)),
                        spk=(st["speaker_id"].min, st["speaker_id"].max), book=(st["chapter_id"].min, st["chapter_id"].max),
                        mp3=(st["original_path"].min.split("/")[-1], st["original_path"].max.split("/")[-1]), footer=md.serialized_size))
    return out
if __name__ == "__main__":
    with cf.ThreadPoolExecutor(8) as ex: res = [r for out in ex.map(scan, range(63)) for r in out]
    json.dump(res, open("data/mls_train_rg.json", "w"))
    print(len(res), "row groups; footer bytes total", sum({r["shard"]: r["footer"] for r in res}.values()))
