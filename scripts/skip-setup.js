// skip, step 1: 20,000 matching documents, then delete the first DELETE of them (default 2,000)
// so the first heap pages are empty. Step 2 (VACUUM or autovacuum, run by run.sh) records that
// space in PostgreSQL's free space map. MongoDB has no equivalent step.
//
// INDEX = false skips the {status: 1} index (the no_index control).
const d = db.getSiblingDB("ctid_repro");
const N = 20000, pad = "x".repeat(200);   // 25 docs per 8 KiB heap page on DocumentDB
const DELETE = globalThis.DELETE ?? 2000, INDEX = globalThis.INDEX ?? true;
d.miss.drop();
for (let off = 0; off < N; off += 5000) {
  const docs = [];
  for (let i = off; i < off + 5000; i++) docs.push({ _id: i, status: "pending", attempts: 0, pad });
  d.miss.insertMany(docs);
}
if (INDEX) d.miss.createIndex({ status: 1 });
d.miss.deleteMany({ _id: { $lt: DELETE } });
