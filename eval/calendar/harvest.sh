#!/bin/bash
# Cut a day out of a REAL mull database, so the titles it would write to a calendar
# can be scored against the day they came from.
#
# Why this exists. The mirror's titles are window titles, and CLAUDE.md §0 場面 D is
# the record of what happens when mull ships text it never scored: about 25 lines of
# pasted context of which 2 or 3 were usable, and nobody knew because nothing counted.
# The calendar is the same output with more exposure — it is read every day, without
# being asked for, and it syncs to a phone.
#
# The synthetic cases in Tests/CalendarMirrorTests.swift are labelled by hand and are
# the gate's specification. They are not a measurement: they contain the failures their
# author had already thought of. A real day has the ones nobody thought of, in the
# proportions they actually occur.
#
#   ./eval/calendar/harvest.sh --on 2026-08-13
#   ./eval/calendar/run.sh
#
# Writes eval/calendar/cases/<date>.json. That file is your raw window titles and
# clipboard: cases/ is gitignored and must stay that way.
set -euo pipefail

DB="${HOME}/Library/Application Support/mull/mull.sqlite"
ON=""
NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --db)   DB="$2";   shift 2 ;;
    --on)   ON="$2";   shift 2 ;;   # a calendar day, YYYY-MM-DD
    --name) NAME="$2"; shift 2 ;;   # defaults to the date
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$ON" ]] || { echo "--on is required (e.g. 2026-08-13)" >&2; exit 2; }
[[ "$ON" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "--on must be YYYY-MM-DD, got: $ON" >&2; exit 2; }
[[ -f "$DB" ]] || { echo "no database at: $DB" >&2; exit 2; }
NAME="${NAME:-$ON}"

cd "$(dirname "$0")"
mkdir -p cases
OUT="cases/${NAME}.json"

# Every event of the day, in order. No filter on textContent: the segmenter reads
# window titles from `windowTitle` and only the clipboard rows carry text, so the
# filter eval/real/harvest.sh uses would drop most of what makes a block.
# The value of a `.parameter set` is an SQL *expression*, and sqlite's dot-command
# tokenizer strips one layer of quoting before evaluating it. A bare '2026-08-12'
# therefore arrives as arithmetic and binds the integer 2006, which selects nothing and
# says nothing — the first run of this script wrote four empty cases. The inner quotes
# are what make it a string literal; the date is regex-checked above as well.
sqlite3 "$DB" \
  -cmd ".parameter init" \
  -cmd ".parameter set :name \"'$(printf '%s' "$NAME" | sed "s/'/''/g")'\"" \
  -cmd ".parameter set :day \"'$(printf '%s' "$ON" | sed "s/'/''/g")'\"" \
"
SELECT json_object(
  'name',   :name,
  'day',    :day,
  'events', json_group_array(json_object(
              'ts', ts, 'eventType', eventType, 'app', app,
              'title', title, 'text', text))
)
FROM (
  SELECT timestamp AS ts, eventType, appName AS app,
         COALESCE(windowTitle, '') AS title, COALESCE(textContent, '') AS text
  FROM recording_events
  WHERE timestamp >= datetime(:day, 'start of day')
    AND timestamp <  datetime(:day, 'start of day', '+1 day')
    AND appName IS NOT NULL
  ORDER BY timestamp
);
" > "$OUT"

echo "wrote eval/calendar/$OUT"
echo "→ ./eval/calendar/run.sh"
