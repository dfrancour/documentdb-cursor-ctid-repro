#!/usr/bin/env bash
# Runs every repro against DocumentDB and MongoDB. Needs only Docker with the compose plugin.
#
#   ./run.sh            start both servers, run every repro on each, print one line per result
#   ./run.sh <repro>    run one: dup | dup-dynamic | dup-trace | loop | analyzed | skip | skip-autovacuum | skip-variants | skip-dynamic
#   ./run.sh down       stop and remove the containers and their data
set -euo pipefail
cd "$(dirname "$0")"

DC=(docker compose --progress quiet)
DDB_URI="mongodb://repro:repro-local-only@documentdb:10260/?directConnection=true"
MDB_URI="mongodb://mongodb:27017/?directConnection=true"

mongosh_on() { local uri=$1; shift; "${DC[@]}" run --rm -T client "$uri" "$@"; }
psql_ddb()   { "${DC[@]}" exec -T documentdb psql -p 9712 -d postgres -qAt "$@" | tail -1; }
ddb_table()  {   # PostgreSQL table behind collection ctid_repro.<name>
  psql_ddb -c "select 'documentdb_data.documents_' || collection_id from documentdb_api_catalog.collections
               where database_name = 'ctid_repro' and collection_name = '$1'"
}
dynamic_cursors() {   # on | off. The setting is user-settable; a reload reaches the gateway's sessions.
  if [[ $1 == on ]]; then psql_ddb -c "ALTER SYSTEM SET documentdb.enableDynamicCursors = on" >/dev/null
  else psql_ddb -c "ALTER SYSTEM RESET documentdb.enableDynamicCursors" >/dev/null; fi
  psql_ddb -c "SELECT pg_reload_conf()" >/dev/null
  sleep 2
}
say() { printf '%-11s %s\n' "$1" "$2"; }

# skip_on <system> <uri> <mode> <reclaim: vacuum|autovacuum> [label]
skip_on() {
  local sys=$1 uri=$2 mode=$3 reclaim=$4 label=${5:-skip:$3} del=2000 index=true
  [[ $reclaim == autovacuum ]] && del=5000   # enough dead rows to cross autovacuum's threshold
  [[ $mode == no_index ]] && index=false
  mongosh_on "$uri" --eval "globalThis.DELETE = $del; globalThis.INDEX = $index" skip-setup.js >/dev/null
  if [[ $sys == documentdb ]]; then
    local t; t=$(ddb_table miss)
    # Leave the table the way a long-lived one is: free space recorded, and column statistics
    # present. Statistics matter: without them, the dynamic-cursor planner picks a primary-key
    # scan for the unhinted query; with them it picks the {status: 1} index.
    if [[ $reclaim == vacuum ]]; then
      psql_ddb -c "VACUUM ANALYZE $t" >/dev/null
    else
      # No manual VACUUM: wait until autovacuum has reclaimed the deleted rows and analyzed the
      # table on its own schedule. The table is new (setup drops the collection), so its counters
      # start at zero. Requiring n_tup_del >= del first means the delete's statistics are in
      # before n_dead_tup is trusted.
      local q="select coalesce(autovacuum_count, 0) || ' ' || coalesce(autoanalyze_count, 0) || ' ' ||
                      coalesce(n_tup_del, 0) || ' ' || coalesce(n_dead_tup, 0)
               from pg_stat_user_tables where relid = '$t'::regclass"
      local runs analyzes dels dead waited=0
      while :; do
        read -r runs analyzes dels dead <<<"$(psql_ddb -c "$q")"
        (( runs >= 1 && analyzes >= 1 && dels >= del && dead < 100 )) && break
        (( waited >= 300 )) && { say "$sys" "$label	autovacuum did not run within 300s"; return; }
        sleep 5; waited=$((waited + 5))
      done
      label="$label (autovacuum after ${waited}s)"
    fi
  fi
  say "$sys" "$(mongosh_on "$uri" --eval "globalThis.MODE = '$mode'; globalThis.LABEL = '$label'" skip-run.js | tail -1)"
}

# dup with documentdb.enableDynamicCursors = on, twice: on a freshly loaded table, and after ANALYZE.
# Without statistics the planner picks a primary-key scan for this query, which resumes on _id and
# hides the problem; with statistics it picks the {status: 1} index.
dup_dynamic_on() {
  local sys=$1 uri=$2 stats
  for stats in "no statistics" "after ANALYZE"; do
    mongosh_on "$uri" --eval "globalThis.PHASE = 'setup'" dup.js >/dev/null
    [[ $sys == documentdb && $stats == "after ANALYZE" ]] && psql_ddb -c "ANALYZE $(ddb_table jobs)" >/dev/null
    say "$sys" "$(mongosh_on "$uri" --eval "globalThis.PHASE = 'run'; globalThis.LABEL = 'dup:dynamic ($stats)'" dup.js | tail -1)"
  done
}

# dup and loop again, with ANALYZE between loading the data and opening the cursor. dup and loop
# otherwise run seconds after loading, before autovacuum has gathered statistics.
analyzed_on() {
  local sys=$1 uri=$2 test table
  for test in dup loop; do
    table=jobs; [[ $test == loop ]] && table=cur
    mongosh_on "$uri" --eval "globalThis.PHASE = 'setup'" "$test.js" >/dev/null
    [[ $sys == documentdb ]] && psql_ddb -c "ANALYZE $(ddb_table $table)" >/dev/null
    say "$sys" "$(mongosh_on "$uri" --eval "globalThis.PHASE = 'run'; globalThis.LABEL = '$test:analyzed'" "$test.js" | tail -1)"
  done
}

# Where the new row versions from the first batch of the dup repro land, relative to the cursor's
# resume point.
dup_trace() {
  local ids last t stop
  ids=$(mongosh_on "$DDB_URI" --eval "globalThis.PHASE = 'first'" dup-trace.js | tail -1)
  last=${ids##*,}; last=${last%]}
  t=$(ddb_table trace)
  local id_expr="documentdb_core.bson_get_value_text(document, '_id')::int"
  stop=$(psql_ddb -c "select ctid from $t where $id_expr = $last")   # where getMore would resume
  psql_ddb -c "set client_min_messages = warning; drop table if exists public.trace_before;
               create table public.trace_before as
                 select $id_expr as id, ctid::text as old_ctid from $t where $id_expr = any('{${ids:1:-1}}'::int[])" >/dev/null
  mongosh_on "$DDB_URI" --eval "globalThis.PHASE = 'update'; globalThis.IDS = $ids" dup-trace.js >/dev/null
  # Classify each new version: behind the resume point (harmless), or ahead of it, either on the
  # same page as the old version or on another page.
  say documentdb "dup-trace	$(psql_ddb -c "
    with cur as (select $id_expr as id, ctid from $t),
         moved as (select b.id, b.old_ctid::tid as old_ctid, c.ctid as new_ctid,
                          (b.old_ctid::point)[0] = (c.ctid::text::point)[0] as same_page
                   from public.trace_before b join cur c using (id)),
         ahead as (select * from moved where new_ctid > '$stop'::tid)
    select json_build_object(
      'first_batch', (select count(*) from moved),
      'resume_after', '$stop',
      'behind_cursor', (select count(*) from moved where new_ctid <= '$stop'::tid),
      'ahead_same_page', (select count(*) from ahead where same_page),
      'ahead_same_page_ids', coalesce((select min(id) || '..' || max(id) from ahead where same_page), ''),
      'ahead_same_page_ctids', coalesce((select min(new_ctid) || '..' || max(new_ctid) from ahead where same_page), ''),
      'ahead_other_page', (select count(*) from ahead where not same_page),
      'ahead_other_page_ids', coalesce((select json_agg(id order by id) from ahead where not same_page), '[]'),
      'ahead_other_page_ctids', coalesce((select json_agg(new_ctid::text order by id) from ahead where not same_page), '[]'))")"
  psql_ddb -c "drop table public.trace_before" >/dev/null
}

run_one() {
  local test=$1
  if [[ $test == dup-trace ]]; then dup_trace; return; fi
  for sys in mongodb documentdb; do
    local uri=$MDB_URI; [[ $sys == documentdb ]] && uri=$DDB_URI
    case $test in
      dup)
        say "$sys" "$(mongosh_on "$uri" dup.js)"
        say "$sys" "$(mongosh_on "$uri" --eval "globalThis.BATCH = 0; globalThis.LABEL = 'dup:default-batch'" dup.js | tail -1)" ;;
      loop)            say "$sys" "$(mongosh_on "$uri" loop.js)" ;;
      analyzed)        analyzed_on "$sys" "$uri" ;;
      skip)            skip_on "$sys" "$uri" index vacuum ;;
      skip-autovacuum) skip_on "$sys" "$uri" index autovacuum "skip:autovacuum" ;;
      skip-variants)
        for m in no_index aggregate sort_id hint_id blocking_sort range_id txn snapshot_read; do skip_on "$sys" "$uri" "$m" vacuum; done ;;
      dup-dynamic)
        # MongoDB has no such setting; it runs the same steps for comparison.
        if [[ $sys == documentdb ]]; then dynamic_cursors on; trap 'dynamic_cursors off' EXIT; fi
        dup_dynamic_on "$sys" "$uri"
        if [[ $sys == documentdb ]]; then dynamic_cursors off; trap - EXIT; fi ;;
      skip-dynamic)
        # MongoDB has no such setting; it runs the same two queries for comparison.
        if [[ $sys == documentdb ]]; then dynamic_cursors on; trap 'dynamic_cursors off' EXIT; fi
        for m in dynamic dynamic_hint; do skip_on "$sys" "$uri" "$m" vacuum; done
        if [[ $sys == documentdb ]]; then dynamic_cursors off; trap - EXIT; fi ;;
      *) echo "unknown repro: $test" >&2; exit 2 ;;
    esac
  done
}

case "${1:-all}" in
  down) "${DC[@]}" down -v --remove-orphans; exit ;;
esac

"${DC[@]}" up -d --wait documentdb mongodb >/dev/null 2>&1 || { "${DC[@]}" up -d --wait documentdb mongodb; exit 1; }
say mongodb "$(mongosh_on "$MDB_URI" version.js)"
say documentdb "$(mongosh_on "$DDB_URI" version.js)	$(psql_ddb -c "select 'postgres ' || current_setting('server_version') || ', documentdb extension ' || extversion from pg_extension where extname = 'documentdb'")"

if [[ "${1:-all}" == all ]]; then
  for t in dup dup-dynamic dup-trace loop analyzed skip skip-autovacuum skip-variants skip-dynamic; do run_one "$t"; done
else
  run_one "$1"
fi
