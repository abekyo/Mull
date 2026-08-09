#!/bin/bash
# Cut a window out of a REAL mull database and write it as an eval case skeleton.
#
# Why this exists (SELECTION-LAYER §6.2): every case in eval/selection_eval.swift was
# invented by the person who wrote the ranker, after they wrote it. The distractors
# in those cases are therefore distractors that ranker already beats — "groceries"
# and "call dentist" next to a query about stripe webhooks. Real distractors are
# not like that. Real distractors are four other events that also say アイコン, six
# identical copies of the same window title, and an IDE toast that repeats all day.
# You cannot imagine that corpus; you can only harvest it.
#
#   ./eval/real/harvest.sh --at "2026-08-08 15:10:00" --window 45 --name icons \
#                          --anchor Mull --query "アイコンの案どれだっけ"
#
# Writes eval/real/cases/<name>.json with `gold: []` and prints a numbered
# worksheet of the window. YOU fill in the gold — the event ids that should have
# come back — and the one discipline that makes this worth doing is:
#
#   *** LABEL GOLD BEFORE YOU RUN THE RANKER. ***
#
# If you look at Selection's output first, you will unconsciously ratify it, and
# you are back to the benchmark that scores 1.000 because it was written to.
#
# The output contains your actual keystrokes and clipboard. eval/real/cases/ is
# gitignored and must stay that way.
set -euo pipefail

DB="${HOME}/Library/Application Support/mull/mull.sqlite"
AT=""; WINDOW=45; NAME=""; ANCHOR=""; ENTITY=""; TYPE=""; K=8; QUERY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)     DB="$2";     shift 2 ;;
    --at)     AT="$2";     shift 2 ;;   # end of the window; the moment the question is asked
    --window) WINDOW="$2"; shift 2 ;;   # minutes of history before --at
    --name)   NAME="$2";   shift 2 ;;
    --anchor) ANCHOR="$2"; shift 2 ;;   # implicit prior: what was on screen
    --entity) ENTITY="$2"; shift 2 ;;   # explicit scope: the caller named a project
    --type)   TYPE="$2";   shift 2 ;;
    --k)      K="$2";      shift 2 ;;
    --query)  QUERY="$2";  shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$NAME" ]] || { echo "--name is required" >&2; exit 2; }
[[ -n "$AT"   ]] || { echo "--at is required (e.g. \"2026-08-08 15:10:00\")" >&2; exit 2; }
[[ -f "$DB"   ]] || { echo "no database at: $DB" >&2; exit 2; }

cd "$(dirname "$0")"
mkdir -p cases
OUT="cases/${NAME}.json"

# json_quote keeps the shell's strings out of the SQL string literals; every
# user-supplied value goes in as a bound parameter, not concatenated text.
sqlite3 "$DB" \
  -cmd ".parameter init" \
  -cmd ".parameter set :name '$(printf '%s' "$NAME" | sed "s/'/''/g")'" \
  -cmd ".parameter set :query '$(printf '%s' "$QUERY" | sed "s/'/''/g")'" \
  -cmd ".parameter set :anchor '$(printf '%s' "$ANCHOR" | sed "s/'/''/g")'" \
  -cmd ".parameter set :entity '$(printf '%s' "$ENTITY" | sed "s/'/''/g")'" \
  -cmd ".parameter set :type '$(printf '%s' "$TYPE" | sed "s/'/''/g")'" \
  -cmd ".parameter set :at '$(printf '%s' "$AT" | sed "s/'/''/g")'" \
  -cmd ".parameter set :win $WINDOW" \
  -cmd ".parameter set :k $K" \
"
SELECT json_object(
  'name',    :name,
  'query',   :query,
  'anchor',  nullif(:anchor,''),
  'entity',  nullif(:entity,''),
  'type',    nullif(:type,''),
  'k',       :k,
  'now',     :at,
  'gold',    json_array(),
  'events',  json_group_array(json_object(
               'id', id, 'ts', ts, 'eventType', eventType, 'app', app,
               'title', title, 'entity', entity, 'contentType', contentType,
               'salience', salience, 'mode', mode, 'text', text))
)
FROM (
  SELECT id, timestamp AS ts, eventType, appName AS app, windowTitle AS title,
         entity, contentType, salience, mode, textContent AS text
  FROM recording_events
  WHERE timestamp <= :at
    AND timestamp >= datetime(:at, '-' || :win || ' minutes')
    AND textContent IS NOT NULL
  ORDER BY timestamp
);
" > "$OUT"

echo "wrote $(cd .. && cd .. && pwd)/eval/real/$OUT"
echo

# Worksheet. Read this, decide which ids should have come back, put them in
# \"gold\". Do not run the eval first.
sqlite3 -separator '  ' "$DB" "
SELECT id, strftime('%H:%M', timestamp), COALESCE(entity,'-'), eventType,
       substr(replace(replace(textContent, char(10),' '), char(13),' '), 1, 110)
FROM recording_events
WHERE timestamp <= '$AT'
  AND timestamp >= datetime('$AT', '-$WINDOW minutes')
  AND textContent IS NOT NULL
ORDER BY timestamp;
"
echo
echo "→ edit $OUT: set \"query\" and put the event ids that SHOULD surface in \"gold\"."
echo "→ label first, run ./eval/real/run.sh second. That order is the whole point."
