// skip, step 3: open a cursor (batch size 100). After the first batch, a separate operation
// increments a non-indexed field on the last 2,000 documents (_id >= 18000). They match before
// and after, and the cursor hasn't reached them yet. Drain the cursor; count what never came back.
//
// MODE (run.sh sets it):
//   index          find on {status: "pending"}, planned on the {status: 1} index
//   no_index       the same find, on a collection set up without the {status: 1} index (control)
//   aggregate      the same filter as an aggregate $match
//   sort_id        find with sort {_id: 1}
//   hint_id        find with hint {_id: 1}
//   blocking_sort  find with sort {pad: 1}, a non-indexed field
//   txn            the index find inside a transaction (default read concern)
//   snapshot_read  the index find with readConcern {level: "snapshot"}, outside a transaction
//   range_id       no cursor: page explicitly with {_id: {$gt: last}}, sort {_id: 1}, limit 100
//   dynamic        the index find, run while documentdb.enableDynamicCursors = on
//   dynamic_hint   find with hint {status: 1}, run while documentdb.enableDynamicCursors = on
const d = db.getSiblingDB("ctid_repro");
const MODE = globalThis.MODE || "index", LABEL = globalThis.LABEL || "skip:" + MODE;
const before = new Set(d.miss.find({ status: "pending" }, { _id: 1 }).toArray().map((x) => x._id));
const sess = db.getMongo().startSession();       // find and getMore in one session
const sd = sess.getDatabase("ctid_repro");
const base = { find: "miss", filter: { status: "pending" }, batchSize: 100 };
const cmd = {
  index: base,
  no_index: base,
  aggregate: { aggregate: "miss", pipeline: [{ $match: { status: "pending" } }], cursor: { batchSize: 100 } },
  sort_id: { ...base, sort: { _id: 1 } },
  hint_id: { ...base, hint: { _id: 1 } },
  blocking_sort: { ...base, sort: { pad: 1 } },
  txn: base,
  snapshot_read: { ...base, readConcern: { level: "snapshot" } },
  range_id: base,   // not used as one command; see below
  dynamic: base,
  dynamic_hint: { ...base, hint: { status: 1 } },
}[MODE];
if (!cmd) throw new Error("unknown MODE: " + MODE);
const ids = new Set();
let returned = 0, batch = 0;
const writer = () => d.miss.updateMany({ _id: { $gte: 18000 } }, { $inc: { attempts: 1 } });
if (MODE === "range_id") {
  // Each page is a separate query that resumes on _id, which an update never changes.
  let last = null;
  for (;;) {
    const filter = last === null ? { status: "pending" } : { status: "pending", _id: { $gt: last } };
    const docs = d.miss.find(filter).sort({ _id: 1 }).limit(100).toArray();
    docs.forEach((x) => { ids.add(x._id); returned++; });
    if (batch++ === 0) writer();
    if (docs.length < 100) break;
    last = docs[docs.length - 1]._id;
  }
} else {
  if (MODE === "txn") sess.startTransaction();
  let r = sd.runCommand(cmd);
  if (!r.ok) throw new Error(MODE + ": " + EJSON.stringify(r));
  for (;;) {
    const docs = r.cursor.firstBatch || r.cursor.nextBatch;
    docs.forEach((x) => { ids.add(x._id); returned++; });
    if (batch++ === 0) writer();
    if (r.cursor.id == 0) break;
    r = sd.runCommand({ getMore: r.cursor.id, collection: "miss", batchSize: 100 });
  }
  if (MODE === "txn") sess.commitTransaction();
}
const missing = [...before].filter((id) => !ids.has(id));
print(LABEL + "\t" + EJSON.stringify({ expected: before.size, returned, distinct: ids.size, missing: missing.length,
  missing_range: missing.length ? [Math.min(...missing), Math.max(...missing)] : [] }));
