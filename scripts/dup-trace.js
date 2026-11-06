// dup-trace: shows where the new row versions from the dup repro's first batch land. DocumentDB
// only; run.sh reads the heap positions (ctid) through psql between the two phases.
//
//   PHASE "first":  same data as dup.js. Fetch the cursor's first batch (100 documents, as in
//                   dup.js), close the cursor, and print the _ids returned.
//   PHASE "update": update those documents one at a time, as dup.js does while it reads them.
const d = db.getSiblingDB("ctid_repro");
const N = 20000, pad = "x".repeat(200);
if (globalThis.PHASE === "first") {
  d.trace.drop();
  for (let off = 0; off < N; off += 5000) {
    const docs = [];
    for (let i = off; i < off + 5000; i++) docs.push({ _id: i, status: "pending", attempts: 0, pad });
    d.trace.insertMany(docs);
  }
  d.trace.createIndex({ status: 1 });
  const r = d.runCommand({ find: "trace", filter: { status: "pending" }, batchSize: 100 });
  const ids = r.cursor.firstBatch.map((x) => x._id);
  if (r.cursor.id != 0) d.runCommand({ killCursors: "trace", cursors: [r.cursor.id] });
  print(EJSON.stringify(ids));
} else if (globalThis.PHASE === "update") {
  for (const id of globalThis.IDS) d.trace.updateOne({ _id: id }, { $inc: { attempts: 1 } });
} else {
  throw new Error("PHASE must be first or update");
}
