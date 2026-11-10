# documentdb-cursor-ctid-repro

Reported upstream as [documentdb/documentdb#822](https://github.com/documentdb/documentdb/issues/822).

## Summary

On [DocumentDB](https://github.com/documentdb/documentdb), a cursor can skip a matching document,
or return it twice, if that document is updated while the cursor is open. The update doesn't need
to touch an indexed or filtered field, and the cursor finishes normally with no error. MongoDB
returned every document exactly once in the same tests.

This affects a `find` or `aggregate` with no sort whose query plan uses a secondary index (any
index other than `_id`). Code that works correctly on MongoDB can fail this way on DocumentDB.

The tests reproduce two failures:

- **Skipped documents.** Another client updates documents the cursor hasn't reached yet. If
  earlier deletes or updates left free space in the table, the new versions can land in pages the
  cursor has already passed, and those documents are never returned. In the test, 2,000 of 18,000
  were missed.
- **Duplicates.** The application updates documents as it reads them. The minimal reproduction
  below returned 617 to 908 of 20,000 documents twice across ten runs. When the application
  updates each batch before fetching the next, a cursor over 5,000 documents returned about
  76,000: each document about 15 times.

**Cause.** DocumentDB doesn't keep a query with no sort open between batches. Each `getMore` runs
the query again, on a new snapshot, and skips the rows the cursor has already returned. To know
which rows those are, it saves a position after each batch, and what it saves depends on the plan:

- **On the `_id` index, or with no usable index** (DocumentDB turns a full table scan into an
  `_id` index scan), rows come back in `_id` order, and the position is the last `_id` returned.
  An update never changes a document's `_id`, so this is safe, at least on unsharded collections.
- **On any other index**, DocumentDB rewrites the scan as a PostgreSQL bitmap heap scan. That scan
  collects the addresses of all matching rows from the index, then reads the table page by page
  in physical order. So rows come back sorted by TID, a row's physical address (heap page, line
  pointer), not by index key. The position is the TID of the last row returned.

A TID belongs to one row *version*, not to a document. PostgreSQL doesn't update rows in place:
an update writes a new version at a new TID. That TID can be before the saved position, in space
freed by earlier deletes or updates, or after it: at the end of the table, or later on the page
where the cursor stopped. The next `getMore` runs on a new snapshot, in which the old version is
gone and only the new one is visible. If the new version is before the saved position, the
document is never returned. If the document was already returned and its new version is after
the saved position, it is returned again.

**Workarounds.** Add any `sort`, use `hint({_id: 1})`, or page by `_id`. Transactions, dynamic
cursors and `readConcern: "snapshot"` don't help. DocumentDB accepts the snapshot read concern
without error, but it has no effect.

**MongoDB's documentation** allows reads to miss documents that a concurrent multi-document write
updates, so the skips are arguably permitted. It mentions duplicates only when an indexed field
changes, which isn't the case here. See
[Is this allowed?](#is-this-allowed-by-mongodbs-documented-semantics)

Reproduced on DocumentDB 1.0 and on `main` at
[`7f05115`](https://github.com/documentdb/documentdb/commit/7f051156), compared with MongoDB 9.0.4.
`./run.sh` runs every test in a few minutes and needs only Docker.

## Minimal reproduction

This reproduces the duplicate case, which needs only `mongosh` and an empty database. It runs
unchanged against either server. The skip case also needs a concurrent writer and free space in
the table, so `./run.sh skip` sets it up (see
[Skipped documents](#skipped-documents)).

```js
const c = db.getSiblingDB("ctid_repro").jobs;
c.drop();
const pad = "x".repeat(200);   // about 25 documents per 8 KiB heap page in DocumentDB
for (let off = 0; off < 20000; off += 5000)
  c.insertMany(Array.from({ length: 5000 }, (_, i) =>
    ({ _id: off + i, status: "pending", attempts: 0, pad })));
c.createIndex({ status: 1 });

const seen = new Set(), dupes = [];
let returned = 0;
c.find({ status: "pending" }).batchSize(100).forEach((doc) => {   // batch size: see below
  returned++;
  if (seen.has(doc._id)) dupes.push(doc._id); else seen.add(doc._id);
  c.updateOne({ _id: doc._id }, { $inc: { attempts: 1 } });   // a field in no index and no filter
});
print({ returned, distinct: seen.size, duplicated: dupes.length });
```

| | Expected | MongoDB 9.0.4 | DocumentDB 1.0 and `main` |
|---|---|---|---|
| Documents returned | 20,000 | 20,000 | **about 20,900** |
| Returned twice | none | none | **about 900 documents** (617 to 908 across ten runs) |

The first duplicates are `_id` 76 to 99. [Duplicates](#duplicates) explains why.

The batch size matters. Without `.batchSize(100)`, both servers send 101 documents and then the
remaining 19,899 in a single `getMore`. Only the updates made during the first batch can then
affect the cursor, so far fewer documents come back twice: usually 5 (`_id` 0, 25, 50, 75 and
100), and between 5 and 62 across ten runs.

[`scripts/dup.js`](scripts/dup.js) is the same test, with the result printed as one line of JSON.
`./run.sh dup` runs it both ways.

## All results

All tests use documents of the form `{ _id: n, status: "pending", attempts: 0, pad: "x" × 200 }`,
inserted in `_id` order. Each test has an index on `{status: 1}` and filters on
`{status: "pending"}`. Updates change only `attempts` (or `seen`), so every document matches
throughout. Every test except the heap trace is a `mongosh` script that runs unchanged against both
servers. The raw output is in [`results/`](results/): for each build, one clean run of every test
followed by four more runs of `dup` and `loop`, so each of those has ten runs in total.

### Main tests

| Test | What the client does | MongoDB 9.0.4 | DocumentDB 1.0 and `main` |
|---|---|---|---|
| Concurrent update ahead of the cursor<br>`skip` | The [skip test](#skipped-documents), with `VACUUM ANALYZE` | 18,000 of 18,000 returned | **16,000 returned.** `_id` 18,000–19,999 are missing. |
| Same, with autovacuum instead of `VACUUM`<br>`skip-autovacuum` | Deletes `_id` < 5,000, then waits for autovacuum to vacuum and analyze the table | 15,000 of 15,000 returned | **13,000 returned.** `_id` 18,000–19,999 are missing. |
| Update each document as it's read<br>`dup` | The minimal reproduction: 20,000 documents, batch size 100 | 20,000 returned, each once | **20,617 to 20,908 returned** across 10 runs; 9 of the 10 returned at least 20,844 |
| Same, with the server's default batch sizes<br>`dup` (second line) | 101 documents, then the other 19,899 in one `getMore` | 20,000 returned, each once | **20,005 returned** in 8 of 10 runs: `_id` 0, 25, 50, 75, 100 twice. The others returned 20,006 and 20,062. |
| Update each batch before fetching the next<br>`loop` | 5,000 documents, batch size 100. After each batch, one `updateMany` increments `seen` on the 100 documents just returned. | 5,000 returned in 50 batches, plus the empty batch that closes the cursor | **75,994 to 76,098 returned** in 760 or 761 batches across 10 runs, so each document came back about 15 times. |
| Both again, after `ANALYZE`<br>`analyzed` | Runs `ANALYZE` between loading the data and opening the cursor | Same as without | Same as without: **895 and 906 duplicates** from `dup`, **75,994 returned** from `loop` |
| Heap trace (DocumentDB only)<br>`dup-trace` | Repeats the first batch of the minimal reproduction and its updates, and reads each row's `ctid` through `psql` | n/a | The resume point is `(3,25)`, the last row on page 3. 72 new versions land behind it. **28 land past it**: 4 move to `(800,1)`–`(800,4)`, and 24 stay on page 3 at `(3,26)`–`(3,49)`. |

### What changes the outcome

These rerun the skip test with one change each (`skip-variants`, `skip-dynamic`):

| Change | MongoDB 9.0.4 | DocumentDB 1.0 and `main` |
|---|---|---|
| None (the test as described) | 0 missing | **2,000 missing** |
| No `{status: 1}` index. This is the control: the plan becomes a primary-key scan. | 0 missing | 0 missing |
| `aggregate([{$match: {status: "pending"}}])` instead of `find` | 0 missing | **2,000 missing** |
| `sort: {_id: 1}`. Any sort makes the cursor [persisted](#how-documentdb-resumes-a-cursor): it holds one snapshot open between batches. | 0 missing | 0 missing |
| `hint: {_id: 1}`, with no sort. The cursor still re-runs the query on each batch, but resumes on `_id`. | 0 missing | 0 missing |
| `sort: {pad: 1}`, a field with no index. Also persisted, at the cost of a blocking sort. | 0 missing | 0 missing |
| No cursor: page explicitly with `{_id: {$gt: last}}`, `sort: {_id: 1}`, `limit: 100`. Each page is a separate query. | 0 missing | 0 missing |
| Cursor inside a transaction (default read concern). The other client's update stays outside it.<sup>1</sup> | 0 missing | **2,000 missing** |
| `readConcern: {level: "snapshot"}` on the `find`, outside a transaction | 0 missing | **2,000 missing**, and no error |
| `documentdb.enableDynamicCursors = on` | 0 missing | **2,000 missing** |
| `documentdb.enableDynamicCursors = on`, plus `hint: {status: 1}` | 0 missing | **2,000 missing** |

<sup>1</sup> MongoDB doesn't guarantee this result. Its
[transactions page](https://www.mongodb.com/docs/manual/core/transactions/#local) says a
transaction with read concern `"local"` *might* read from a snapshot, not that it will.

Running the minimal reproduction with `documentdb.enableDynamicCursors = on` (`dup-dynamic`) can
make that setting look like a fix when it isn't:

| Table state | MongoDB 9.0.4 | DocumentDB 1.0 and `main` |
|---|---|---|
| Freshly loaded, no statistics yet | 0 duplicates | 0 duplicates. The planner picks a primary-key scan, which resumes on `_id`. |
| After `ANALYZE` | 0 duplicates | **864 and 874 duplicates** in two runs |

On a fresh table, the duplicates disappear only because the planner has no statistics yet and
picks a primary-key scan. After `ANALYZE`, they come back. This is also why the skip tests run
`ANALYZE` before opening the cursor.

## How it happens

### How DocumentDB resumes a cursor

DocumentDB is a PostgreSQL extension. A gateway speaks the MongoDB wire protocol and translates
each command into SQL. A few details matter here:

- **Storage.** Each collection is one heap table, `documentdb_data.documents_<collection_id>`:
  - Columns: `shard_key_value`, `object_id` (the `_id`) and `document` (the whole BSON document).
  - Primary key: a btree on `(shard_key_value, object_id)`.
  - Each secondary index, such as `{status: 1}`, is a `documentdb_extended_rum` index on the
    `document` column.
  - Because secondary indexes cover the whole `document` column, any update changes an indexed
    column. So no update can be HOT: each one writes a new heap tuple and a new index entry.
- **Streaming cursors.** A `find` or `aggregate` with no sort and no blocking stage doesn't keep a
  PostgreSQL cursor open between `getMore` calls. Instead:
  - Each `getMore` plans and runs the query again, as a new statement with a new snapshot.
  - The query carries a continuation token from the previous page.
  - A custom scan node discards rows until it passes the continuation point.
- **Persisted cursors.** Any `sort` on a `find` makes the cursor persisted instead
  ([`ApplyFindSpec`](https://github.com/documentdb/documentdb/blob/v1.0-0/pg_documentdb/src/aggregation/bson_aggregation_pipeline.c#L2449-L2452)).
  The query runs once, as a PostgreSQL cursor held open between `getMore` calls, on one snapshot.
  No continuation is involved, so this bug can't happen.
- **What the continuation records.** That depends on the plan
  ([`UpdatePathsWithExtensionStreamingCursorPlans`](https://github.com/documentdb/documentdb/blob/v1.0-0/pg_documentdb/src/customscan/custom_scan_continuation.c#L789-L833)):
  - **Primary-key index scan:** resumes after the last `_id`, which an update never changes, so
    this is safe (for unsharded collections; see [Scope and caveats](#scope-and-caveats)).
  - **Sequential scan:** converted to a primary-key index scan while
    `documentdb.enablePrimaryKeyCursorScan` is on, which is the default
    ([L1166–L1182](https://github.com/documentdb/documentdb/blob/v1.0-0/pg_documentdb/src/customscan/custom_scan_continuation.c#L1166-L1182)).
    Safe for the same reason.
  - **Any other index scan:** converted to a bitmap heap scan. A bitmap heap scan first collects
    the TIDs of all matching rows from the index into a bitmap, then visits the heap in page
    order, so it returns rows in TID order rather than index-key order. It resumes after the TID
    of the last row returned
    ([L1106–L1142](https://github.com/documentdb/documentdb/blob/v1.0-0/pg_documentdb/src/customscan/custom_scan_continuation.c#L1106-L1142)).
    This is the case that breaks.

On `getMore`,
[`SkipWithUserContinuation`](https://github.com/documentdb/documentdb/blob/v1.0-0/pg_documentdb/src/customscan/custom_scan_continuation.c#L2326-L2391)
discards rows until the first one whose TID is greater than the saved one. A comment in that loop
notes the dependency on TID order, and names VACUUM as a risk to it:

> Note that there is an implicit dependency that the slot is returned in ascending slot order. This
> does present a small problem with vacuum and autovacuum. These would need to be reconciled as we
> build more scans on top of this.
> TODO: Consider impact of VACUUM on the cursor state execution and skip

The comment doesn't mention updates, which break the same assumption: an update moves a document
to a new TID.

The links above are to the `v1.0-0` tag. The same code is on `main` at `7f05115`:
[`UpdatePathsWithExtensionStreamingCursorPlans`](https://github.com/documentdb/documentdb/blob/7f05115636419fa2500da34a38f96ba355984189/pg_documentdb/src/customscan/custom_scan_continuation.c#L822-L864),
[the bitmap conversion](https://github.com/documentdb/documentdb/blob/7f05115636419fa2500da34a38f96ba355984189/pg_documentdb/src/customscan/custom_scan_continuation.c#L1137-L1173),
and
[`SkipWithUserContinuation`](https://github.com/documentdb/documentdb/blob/7f05115636419fa2500da34a38f96ba355984189/pg_documentdb/src/customscan/custom_scan_continuation.c#L2357-L2423),
with the same comment.

### Where an updated document lands

A TID identifies one row *version*, not a document. When an update writes a new version, PostgreSQL
places it as follows:

1. On the same heap page, if that page has room (after pruning dead versions there). Pruning
   frees the dead version's space but not its line pointer, which index entries still reference
   until `VACUUM`. So the new version gets a new line pointer, numbered after every row already on
   the page, and its TID is higher than theirs.
2. Otherwise, on a page the free space map reports as having room. This can be anywhere in the
   table, including pages before the cursor's position.
3. Otherwise, on a new page at the end of the table.

The next `getMore` uses a new snapshot, so the old version is invisible to it and only the new
version can be returned:

- **New version before the saved TID:** the document is never returned.
- **New version after the saved TID:** the document is returned a second time. This happens when
  the new version goes to the end of the table, and also when it stays on the page where the
  cursor stopped, because its new line pointer is numbered after the saved one.

### Skipped documents

The skip test arranges free space before the cursor's position:

1. Load 20,000 documents with an index on `{status: 1}`.
2. Delete `_id` < 2,000 and run `VACUUM ANALYZE`. Heap pages 0–79 are now empty and recorded in the
   free space map.
3. Open a cursor on `{status: "pending"}` with batch size 100.
4. After the first batch, another client runs `updateMany({_id: {$gte: 18000}}, {$inc: {attempts: 1}})`.

```text
heap pages, in the order the cursor reads them

page      0 ............ 79 | 80 .................................... 799
          empty: deleted,     live rows _id 2000 .. 19999
          then VACUUM

batch 1   returns _id 2000..2099 (pages 80-83) and saves the TID of the last row on page 83
writer    updateMany({_id: {$gte: 18000}}) writes 2,000 new versions into pages 0-79
getMore   new snapshot: the old versions on pages 720-799 are gone, the new ones are on 0-79,
          and only rows after the saved TID are returned
result    _id 18000..19999 are never returned
```

- **The numbers are contrived.** Pages 0–79 hold exactly 2,000 documents, so all 2,000 updated
  documents land before the cursor. In a real table, how many land there depends on how much free
  space exists and where.
- **A manual `VACUUM` isn't needed.** A variant deletes 5,000 documents instead, which crosses the
  default autovacuum threshold (50 + 20% of 20,000 = 4,050 dead rows). It then waits for
  autovacuum, and the result is the same.
- **Free space like this is normal.** Any table that has had deletes or updates has it once it
  has been vacuumed.

### Duplicates

In the minimal reproduction, documents are loaded in `_id` order, 25 to a page, so document *n*
starts on heap page ⌊*n*/25⌋. Then:

1. The first batch is 100 documents: `_id` 0–99, on pages 0–3. The continuation is the TID of
   `_id` 99, which is `(3,25)`, the last row on page 3.
2. The loop updates those 100 documents one at a time:
   - 72 new versions stay on pages 0–2, before `(3,25)`. That's harmless, because those documents
     were already returned.
   - 4 new versions go to page 800, just past the end of the table: `(800,1)`–`(800,4)`. These
     are `_id` 0, 25, 50 and 75, the first document updated on each page.
   - 24 new versions stay on page 3, but at `(3,26)`–`(3,49)`, after the continuation. These are
     `_id` 76–99.
3. The next `getMore` returns those 28 again: `_id` 76–99 first, then 0, 25, 50 and 75 when it
   reaches page 800.

[`scripts/dup-trace.js`](scripts/dup-trace.js) measures this split by reading `ctid` through
`psql` before and after the updates (`./run.sh dup-trace`). It covers only the first batch. Every
later batch can add more, and documents that come back twice are updated again. We haven't
modeled how that adds up to the totals, which vary from run to run:

- With batch size 100, ten runs returned 617 to 908 documents twice ([`results/`](results/)).
- With the server's default batch sizes, the first batch is `_id` 0–100 and ends at `(4,1)`, the
  first row on page 4. `_id` 100 is the only document on that page to be updated, so no new
  version stays on page 4 after the continuation. Only the first document updated on each page
  moves past it, to the end of the table: `_id` 0, 25, 50, 75 and 100. The next `getMore` returns
  everything that's left, so later updates can't affect the cursor. Those 5 came back twice in 8
  of 10 runs. In the other two, 6 and 62 came back twice.

<details>
<summary>Why the first document on each page moves (an inference, not measured)</summary>

The trace shows which documents move, but not why. This explanation fits the counts:

- The pages are full after loading.
- Updating a document leaves a dead old version that no snapshot needs.
- The next update on that page can prune it and reuse the space.
- The first update on each page has nothing to prune, so its new version must go elsewhere.

A likely reason the count varies with timing is that pruning needs the dead version to be
removable at the moment of the update.

</details>

### Why MongoDB doesn't do this

This is our understanding of MongoDB's storage design, not something these tests verify.
WiredTiger keeps a document's `RecordId` across updates. Index entries are keyed by
`(key, RecordId)`, and an index scan that yields between batches resumes from that position. An
update that leaves the index key unchanged therefore leaves the document in the same place relative
to the cursor.

## Is this allowed by MongoDB's documented semantics?

MongoDB's documentation is permissive. Its
[read isolation page](https://www.mongodb.com/docs/manual/core/read-isolation-consistency-recency/#read-uncommitted-and-multiple-document-write)
says this of reads that interleave with a multi-document write outside a transaction, such as an
`updateMany`:

> Reads may miss matching documents that are updated during the course of the read operation.

The skip test is exactly that case, so the skips are arguably within MongoDB's documented behavior.

The same page's
["Cursor Snapshot"](https://www.mongodb.com/docs/manual/core/read-isolation-consistency-recency/#cursor-snapshot)
section says:

> If one of these operations changes the indexed field on the index used by the query, then the
> cursor could return the same document more than once.

The docs don't promise that a cursor returns every matching document exactly once. The case for
fixing this anyway:

- **The duplicates have a cause the docs don't mention.** The docs mention duplicates when an
  indexed field changes. Here, none does.
- **The duplication can be large.** In the batch-at-a-time test, the cursor returned about 15
  times as many documents as the collection holds before it closed. We haven't investigated why
  it stops where it does.
- **Compatibility.** DocumentDB aims to be MongoDB-compatible, but code written and tested
  against MongoDB can process documents twice, or skip them, on DocumentDB. Whether it skips
  depends on state the application can't see: free space left by earlier deletes or updates.
- **The remedy MongoDB documents has no effect.** The "Cursor Snapshot" section points to read
  concern `"snapshot"`. On a plain `find`, DocumentDB accepts it without error and still misses
  2,000 documents. Inside a transaction, the gateway rejects it (see
  [Workarounds](#workarounds)).

## Workarounds

Tested on DocumentDB 1.0 and `main`:

- **Works:** `hint({_id: 1})` with no sort. The cursor stays a streaming cursor, but it resumes on
  the primary key, which an update never changes. Tested on unsharded collections only.
- **Works:** page explicitly with `{_id: {$gt: last}}`, `sort({_id: 1})` and a `limit`. Each page
  is a separate query that resumes on `_id`.
- **Works:** any sort, such as `sort({_id: 1})` or a sort on a field with no index. The sort makes
  the cursor persisted: it runs on one snapshot and the server holds it open between `getMore`
  calls. A sort on a field with no index also costs a blocking sort.
- **Doesn't work:** read concern `"snapshot"` on a plain `find`. It is accepted without error and
  has no effect on the result. That may be worth its own issue: MongoDB has supported this read
  concern outside transactions since 5.0, and DocumentDB neither honors it nor rejects it.
- **Doesn't work:** a transaction. With the default read concern, the gateway starts transactions
  at PostgreSQL `READ COMMITTED`
  ([`transaction_store.rs`](https://github.com/documentdb/documentdb/blob/v1.0-0/pg_documentdb_gw/documentdb_gateway_core/src/context/transaction/transaction_store.rs#L214-L216)),
  so each `getMore` still gets a new snapshot. Read concern `"snapshot"` in a transaction is
  rejected by default, and we found no way to enable it (details below).
- **Doesn't work:** `documentdb.enableDynamicCursors = on` (off by default).
  - With statistics, dynamic cursors plan an ordered scan on the `{status: 1}` index and resume on
    the index key plus the TID.
  - Within one key value the index is in TID order, and the scan skips entries whose TID is below
    the saved one
    ([`dynamic_cursor_scan.c`](https://github.com/documentdb/documentdb/blob/v1.0-0/pg_documentdb/src/customscan/dynamic_cursor_scan.c#L1714-L1723)).
    So it misses and repeats the same documents.

<details>
<summary>Why snapshot transactions couldn't be tested</summary>

- Read concern `"snapshot"` in a transaction maps to `REPEATABLE READ`
  ([`common_fields.rs`](https://github.com/documentdb/documentdb/blob/v1.0-0/pg_documentdb_gw/documentdb_gateway_core/src/requests/common_fields.rs#L227-L230)).
- The gateway rejects it unless the dynamic setting `mongoAllowTransactionSnapshot` is true
  ([`validation.rs`](https://github.com/documentdb/documentdb/blob/v1.0-0/pg_documentdb_gw/documentdb_gateway_core/src/requests/validation.rs#L111-L124)).
  That check applies only inside transactions, which is why a plain `find` accepts the read
  concern.
- The gateway reads the setting from PostgreSQL settings named `documentdb.*`
  ([`query_catalog.rs`](https://github.com/documentdb/documentdb/blob/v1.0-0/pg_documentdb_gw/documentdb_gateway_core/src/postgres/query_catalog.rs#L597)).
  The extension reserves that prefix
  ([`pg_documentdb.c`](https://github.com/documentdb/documentdb/blob/v1.0-0/pg_documentdb/src/pg_documentdb.c#L70))
  without registering this name, so PostgreSQL rejects it.

We found no way to turn the setting on in the 1.0 image, so whether snapshot transactions would
avoid the problem is untested.

</details>

## Running the tests

Requires only Docker with the compose plugin. Nothing is published on host ports.

```sh
./run.sh            # start both servers and run every test on each (a few minutes)
./run.sh dup        # or one: dup | dup-dynamic | dup-trace | loop | analyzed | skip | skip-autovacuum | skip-variants | skip-dynamic
./run.sh down       # remove the containers and their data
```

- Images are pinned by digest in [`compose.yaml`](compose.yaml).
- To try another build, set `DDB_IMAGE` and/or `MONGO_IMAGE`, for example
  `DDB_IMAGE=ghcr.io/documentdb/documentdb/documentdb-local:<tag> ./run.sh`.
- The minimal reproduction ([`scripts/dup.js`](scripts/dup.js)) and the batch-at-a-time test
  ([`scripts/loop.js`](scripts/loop.js)) also run with plain `mongosh "<uri>" <script>` against any
  server.
- The other tests need `psql` access to the DocumentDB container, which `run.sh` provides through
  `docker compose exec`. They use it to run `VACUUM ANALYZE` and `ANALYZE`, wait for autovacuum,
  toggle `documentdb.enableDynamicCursors`, and read `ctid`s.

<details>
<summary>Sample output</summary>

Each test prints one line of JSON per server and case. `dup` runs with batch size 100 and then
with the server's default batch sizes:

```console
$ ./run.sh dup
mongodb     version	{"version":"9.0.4"}
documentdb  version	{"version":"7.0.0"}	postgres 17.11 (Debian 17.11-1.pgdg13+2), documentdb extension 1.0-0
mongodb     dup	{"expected":20000,"returned":20000,"distinct":20000,"duplicated":0,"first_duplicated_ids":[]}
mongodb     dup:default-batch	{"expected":20000,"returned":20000,"distinct":20000,"duplicated":0,"first_duplicated_ids":[]}
documentdb  dup	{"expected":20000,"returned":20907,"distinct":20000,"duplicated":907,"first_duplicated_ids":[76,77,78,79,80,81,82,83,84,85]}
documentdb  dup:default-batch	{"expected":20000,"returned":20005,"distinct":20000,"duplicated":5,"first_duplicated_ids":[0,25,50,75,100]}
```

`7.0.0` is the MongoDB wire version that DocumentDB reports, not its own release.

</details>

## Scope and caveats

- **Single node, unsharded collections only.** Each build ran as one node, and sharded collections
  weren't tested. The primary-key continuation requires an equality filter on the shard key,
  which DocumentDB adds for unsharded collections
  ([L877–L898](https://github.com/documentdb/documentdb/blob/v1.0-0/pg_documentdb/src/customscan/custom_scan_continuation.c#L877-L898),
  [L1117–L1118](https://github.com/documentdb/documentdb/blob/v1.0-0/pg_documentdb/src/customscan/custom_scan_continuation.c#L1117-L1118)).
  On a sharded collection, `hint({_id: 1})` may therefore fall back to the TID continuation.
- **Builds:**
  - DocumentDB 1.0: the published `documentdb-local:pg17-1.0.0` image, pinned by digest
    (extension `1.0-0`, PostgreSQL 17.11).
  - DocumentDB `main` at `7f05115` (2026-11-03, extension `1.3-0`). No image is published from
    `main`, so it was built locally with upstream's `packaging/build_packages.sh` and
    `Dockerfile_documentdb_local`. The exact commands are in the header of its results file. Every
    test gives the same outcome as on 1.0.
  - MongoDB 9.0.4 (WiredTiger), as a single-node replica set so the transaction test can run.
- **Statistics:**
  - The skip tests analyze the table before opening the cursor.
  - The minimal reproduction and the batch-at-a-time test run seconds after loading, before any
    statistics exist.
  - With dynamic cursors off, running `ANALYZE` first gives the same results (`./run.sh analyzed`).
- **Counts:** the exact numbers depend on this physical layout. The mechanism doesn't.
  - 2,000 missing was the same in every run.
  - The duplicate counts from `dup` vary from run to run (see [Duplicates](#duplicates)). We
    haven't established why.
- **Preconditions:**
  - A skip needs free space before the cursor's position.
  - A duplicate needs only that a document's new version lands after the cursor's position. That
    happens when its page is full, or when it is on the page where the cursor stopped. It doesn't
    need `VACUUM`.

## Files

| Path | Purpose |
|---|---|
| [`run.sh`](run.sh) | Starts the servers, runs the tests, and does the `psql` steps on the DocumentDB side |
| [`compose.yaml`](compose.yaml) | DocumentDB (`documentdb-local`), MongoDB as a single-node replica set, and a `mongosh` client container |
| [`scripts/skip-setup.js`](scripts/skip-setup.js), [`scripts/skip-run.js`](scripts/skip-run.js) | The skip test and its variants |
| [`scripts/dup.js`](scripts/dup.js) | Update each document as it's read (the minimal reproduction), with batch size 100 or the server's defaults |
| [`scripts/dup-trace.js`](scripts/dup-trace.js) | The heap trace's `mongosh` side. `run.sh` reads the `ctid`s. |
| [`scripts/loop.js`](scripts/loop.js) | Update each batch before fetching the next |
| [`results/`](results/) | Output of a clean run on each tested DocumentDB build, plus four more runs of `dup` and `loop` |

## License

[MIT](LICENSE)
