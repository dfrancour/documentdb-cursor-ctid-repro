// dup: read a cursor on a secondary index and update each document as it is read.
// Every document matches for the whole run, and the updated field is in no index and no
// filter, so every _id should come back exactly once.
//
// Run with plain mongosh, this loads the data and runs the cursor with batch size 100. run.sh can
// also set:
//   PHASE = "setup" (load only) or "run" (cursor only), so it can analyze the table in between.
//   BATCH = 0 to use the server's default batch sizes: 101 documents first, then everything else
//           in one getMore (it all fits in 16 MiB). Only the first batch's updates can then
//           happen while the cursor is open.
const d = db.getSiblingDB("ctid_repro");
const N = 20000, pad = "x".repeat(200);   // 25 docs per 8 KiB heap page on DocumentDB
const PHASE = globalThis.PHASE, LABEL = globalThis.LABEL || "dup", BATCH = globalThis.BATCH ?? 100;

if (PHASE !== "run") {
  d.jobs.drop();
  for (let off = 0; off < N; off += 5000) {
    const docs = [];
    for (let i = off; i < off + 5000; i++) docs.push({ _id: i, status: "pending", attempts: 0, pad });
    d.jobs.insertMany(docs);
  }
  d.jobs.createIndex({ status: 1 });
}

if (PHASE !== "setup") {
  const seen = new Set(), dupes = [];
  let returned = 0;
  const cursor = d.jobs.find({ status: "pending" });
  if (BATCH > 0) cursor.batchSize(BATCH);
  cursor.forEach((doc) => {
    returned++;
    if (seen.has(doc._id)) dupes.push(doc._id); else seen.add(doc._id);
    d.jobs.updateOne({ _id: doc._id }, { $inc: { attempts: 1 } });
  });
  print(LABEL + "\t" + EJSON.stringify({ expected: N, returned, distinct: seen.size, duplicated: dupes.length,
    first_duplicated_ids: dupes.slice(0, 10) }));
}
