// loop: the "read a batch, mark it, read the next batch" pattern. After each batch, increment
// a non-indexed counter on the documents just returned. 5,000 documents, batch size 100.
// The cursor should return 5,000 documents in 50 full batches, then an empty one that closes it.
// The script stops at 1,000 batches.
//
// Run with plain mongosh, this loads the data and runs the cursor. run.sh can instead set
// PHASE = "setup" (load only) or "run" (cursor only), so it can analyze the table in between.
const d = db.getSiblingDB("ctid_repro");
const N = 5000, pad = "x".repeat(200), GUARD = 1000;
const PHASE = globalThis.PHASE, LABEL = globalThis.LABEL || "loop";

if (PHASE !== "run") {
  d.cur.drop();
  const docs = [];
  for (let i = 0; i < N; i++) docs.push({ _id: i, status: "pending", seen: 0, pad });
  d.cur.insertMany(docs);
  d.cur.createIndex({ status: 1 });
}

if (PHASE !== "setup") {
  const sd = db.getMongo().startSession().getDatabase("ctid_repro");
  let r = sd.runCommand({ find: "cur", filter: { status: "pending" }, batchSize: 100 });
  let returned = 0, batches = 0, closed = false;
  const ids = new Set();
  for (;;) {
    const batch = r.cursor.firstBatch || r.cursor.nextBatch;
    batches++; returned += batch.length; batch.forEach((x) => ids.add(x._id));
    if (batch.length) d.cur.updateMany({ _id: { $in: batch.map((x) => x._id) } }, { $inc: { seen: 1 } });
    if (r.cursor.id == 0) { closed = true; break; }
    if (batches >= GUARD) break;
    r = sd.runCommand({ getMore: r.cursor.id, collection: "cur", batchSize: 100 });
  }
  print(LABEL + "\t" + EJSON.stringify({ expected: N, returned, distinct: ids.size, batches,
    cursor: closed ? "closed" : `still open after ${GUARD} batches (stopped by the script)` }));
}
