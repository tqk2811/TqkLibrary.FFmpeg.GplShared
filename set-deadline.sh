#!/bin/bash
# Set/adjust the RunOvernight deadline AT RUNTIME.
#
# RunOvernight.sh re-reads DEADLINE_FILE before starting every combo, so writing
# a new value here changes the cutoff of an already-running build without a
# restart. The combo in progress always finishes; only the START of the next
# combo is gated by the new deadline.
#
# Usage:
#   ./set-deadline.sh 06:30                 # today 06:30 in TZONE
#   ./set-deadline.sh "2026-07-09 06:30"    # explicit date + time
#   ./set-deadline.sh 1783299600            # raw epoch seconds
#   ./set-deadline.sh off                   # effectively no cutoff (far future)
#   ./set-deadline.sh                       # print the current deadline and exit
#
# Env: DEADLINE_FILE (default <repo>/deadline.conf), TZONE (default Asia/Ho_Chi_Minh).
set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DEADLINE_FILE="${DEADLINE_FILE:-$REPO_DIR/deadline.conf}"
TZONE="${TZONE:-Asia/Ho_Chi_Minh}"

show_current() {
  if [ -s "$DEADLINE_FILE" ]; then
    local raw ep
    raw="$(head -1 "$DEADLINE_FILE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if printf '%s' "$raw" | grep -qE '^[0-9]+$'; then ep="$raw"
    else ep="$(TZ="$TZONE" date -d "$raw" +%s 2>/dev/null)"; fi
    if [ -n "${ep:-}" ]; then
      echo "Current deadline: $(TZ="$TZONE" date -d "@$ep" '+%F %T %Z')  (epoch $ep)  [$DEADLINE_FILE]"
    else
      echo "Current deadline file holds unparseable value: '$raw'  [$DEADLINE_FILE]"
    fi
  else
    echo "No deadline file yet: $DEADLINE_FILE"
  fi
}

if [ $# -lt 1 ]; then
  show_current
  exit 0
fi

val="$*"
if [ "$val" = "off" ] || [ "$val" = "none" ]; then
  ep="$(date -d '+10 years' +%s)"
elif printf '%s' "$val" | grep -qE '^[0-9]+$'; then
  ep="$val"
else
  ep="$(TZ="$TZONE" date -d "$val" +%s 2>/dev/null)"
  if [ -z "$ep" ]; then
    echo "ERROR: cannot parse time: '$val'" >&2
    echo "Try: '06:30', '2026-07-09 06:30', an epoch, or 'off'." >&2
    exit 1
  fi
fi

echo "$ep" > "$DEADLINE_FILE"
echo "Deadline set to: $(TZ="$TZONE" date -d "@$ep" '+%F %T %Z')  (epoch $ep)"
echo "Written to: $DEADLINE_FILE"
echo "RunOvernight re-reads this before each combo; the in-progress combo still finishes."
