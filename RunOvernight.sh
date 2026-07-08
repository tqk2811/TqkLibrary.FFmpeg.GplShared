#!/bin/bash
# Overnight FFmpeg *shared* builds via the BtbN/FFmpeg-Builds submodule.
#
# Order: FFmpeg version (newest first) -> license variant -> platform.
# Stops issuing NEW builds once it reaches STOP_HOUR (default 08:00) in TZONE
# (default Asia/Ho_Chi_Minh). A build already running is allowed to finish.
# Resumable: any combo whose archive already exists in ./artifacts is skipped.
#
# RAM safety: makeimage.sh is patched to buildkit max-parallelism=1, so only one
# dependency compiles at a time (peak RAM bounded to a single library, make -j8).
#
# After each combo: remove that combo's docker image, prune dangling images and
# builder cache, and drop the per-combo local cache. Base images/caches are kept
# so cross toolchains are not rebuilt every time.
set -u

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$REPO_DIR/FFmpeg-Builds"
ARTIFACTS_DIR="$REPO_DIR/artifacts"
LOG_DIR="$REPO_DIR/logs"
CACHE_BASE_DIR="$BUILD_DIR/.cache/ghcr.io/btbn/ffmpeg-builds"
mkdir -p "$ARTIFACTS_DIR" "$LOG_DIR"

PROGRESS="$LOG_DIR/progress.log"

VERSIONS="${VERSIONS:-8.1 8.0 7.1 7.0 6.1 6.0 5.1 5.0 4.4}"
VARIANTS="${VARIANTS:-lgpl-shared gpl-shared gpl2-shared lgpl2-shared}"
PLATFORMS="${PLATFORMS:-win64 win32 winarm64 linux64 linuxarm64}"
STOP_HOUR="${STOP_HOUR:-8}"
TZONE="${TZONE:-Asia/Ho_Chi_Minh}"
# NO_DEADLINE=1 disables the STOP_HOUR cutoff entirely (run until all combos done).
NO_DEADLINE="${NO_DEADLINE:-0}"

# Deadline file: past_deadline() re-reads this before every combo, so the cutoff
# can be CHANGED AT RUNTIME (write a new value into it -- e.g. via ./set-deadline.sh)
# without restarting the run. The in-progress combo always finishes; only the
# START of the next combo is gated. File content may be an epoch (seconds) or any
# string `date -d` accepts ("06:30", "2026-07-09 06:30"), interpreted in TZONE.
DEADLINE_FILE="${DEADLINE_FILE:-$REPO_DIR/deadline.conf}"

# Initial deadline = next occurrence of STOP_HOUR:00 in TZONE (epoch is TZ-independent).
now_epoch="$(date +%s)"
today_deadline="$(TZ="$TZONE" date -d "today ${STOP_HOUR}:00" +%s)"
if [ "$now_epoch" -lt "$today_deadline" ]; then
    DEADLINE="$today_deadline"
else
    DEADLINE="$(TZ="$TZONE" date -d "tomorrow ${STOP_HOUR}:00" +%s)"
fi
# Seed the deadline file with the computed default unless one was pre-placed
# (a pre-existing file lets you fix a custom cutoff before launch).
if [ ! -s "$DEADLINE_FILE" ]; then
    echo "$DEADLINE" > "$DEADLINE_FILE"
fi

log() { echo "[$(TZ="$TZONE" date '+%F %T %Z')] $*" | tee -a "$PROGRESS"; }

# Resolve the effective deadline epoch from DEADLINE_FILE (falls back to $DEADLINE
# if the file is missing/empty/unparseable). Called fresh before every combo.
read_deadline() {
  local line ep
  line="$(head -1 "$DEADLINE_FILE" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if [ -z "$line" ]; then echo "$DEADLINE"; return; fi
  if printf '%s' "$line" | grep -qE '^[0-9]+$'; then
    echo "$line"
  else
    ep="$(TZ="$TZONE" date -d "$line" +%s 2>/dev/null)"
    if [ -n "$ep" ]; then echo "$ep"; else echo "$DEADLINE"; fi
  fi
}
past_deadline() { [ "$NO_DEADLINE" = "1" ] && return 1; [ "$(date +%s)" -ge "$(read_deadline)" ]; }
disk_free() { df -h --output=avail "$REPO_DIR" 2>/dev/null | tail -1 | tr -d ' '; }

built=0; skipped=0; failed=0

log "================================================================"
log "RunOvernight start (PID $$)"
if [ "$NO_DEADLINE" = "1" ]; then
  log "Deadline: DISABLED (NO_DEADLINE=1) -- runs until all combos done"
else
  log "Deadline (no new build after): $(TZ="$TZONE" date -d "@$(read_deadline)" '+%F %T %Z')  [live file: $DEADLINE_FILE]"
fi
log "VERSIONS = $VERSIONS"
log "VARIANTS = $VARIANTS"
log "PLATFORMS= $PLATFORMS"
log "Disk free: $(disk_free)"
log "================================================================"

# Apply our tracked customizations (gpl2/lgpl2 variants + license/kernel/sdl2 fixes)
# onto the pristine BtbN/FFmpeg-Builds submodule before building.
if "$REPO_DIR/apply-overlay.sh" >>"$PROGRESS" 2>&1; then
  log "Overlay applied onto FFmpeg-Builds."
else
  log "WARN: overlay apply failed -- gpl2/lgpl2 combos and fixes may be missing."
fi

for VERSION in $VERSIONS; do
  for VARIANT in $VARIANTS; do
    for PLATFORM in $PLATFORMS; do

      if past_deadline; then
        log "DEADLINE reached -> not starting new builds."
        log "SUMMARY: built=$built skipped=$skipped failed=$failed"
        log "RunOvernight done."
        exit 0
      fi

      COMBO="${PLATFORM}-${VARIANT}-${VERSION}"

      # Already built?
      if find "$ARTIFACTS_DIR" -maxdepth 1 -name "ffmpeg-*-${PLATFORM}-${VARIANT}-${VERSION}.*" 2>/dev/null | grep -q .; then
        skipped=$((skipped+1)); log "SKIP (exists): $COMBO"; continue
      fi
      # Variant defined in submodule?
      if [ ! -f "$BUILD_DIR/variants/${PLATFORM}-${VARIANT}.sh" ]; then
        skipped=$((skipped+1)); log "SKIP (no variant file): $COMBO"; continue
      fi
      # Version addin defined?
      if [ ! -f "$BUILD_DIR/addins/${VERSION}.sh" ]; then
        skipped=$((skipped+1)); log "SKIP (no addin ${VERSION}): $COMBO"; continue
      fi

      TARGET_CACHE="$CACHE_BASE_DIR/${COMBO}_latest"
      [ -d "$TARGET_CACHE" ] && rm -rf "$TARGET_CACHE"

      COMBO_LOG="$LOG_DIR/${COMBO}.log"
      log "BUILD START: $COMBO   (detail: logs/${COMBO}.log)"
      SECONDS=0
      if ( cd "$BUILD_DIR" && ./makeimage.sh "$PLATFORM" "$VARIANT" "$VERSION" \
                            && ./build.sh     "$PLATFORM" "$VARIANT" "$VERSION" ) \
             >"$COMBO_LOG" 2>&1; then
        # BtbN writes to FFmpeg-Builds/artifacts; move the new archive up.
        if [ -d "$BUILD_DIR/artifacts" ]; then
          find "$BUILD_DIR/artifacts" -maxdepth 1 -type f \
               -name "ffmpeg-*-${PLATFORM}-${VARIANT}-${VERSION}.*" \
               -exec mv -f {} "$ARTIFACTS_DIR/" \;
        fi
        if find "$ARTIFACTS_DIR" -maxdepth 1 -name "ffmpeg-*-${PLATFORM}-${VARIANT}-${VERSION}.*" 2>/dev/null | grep -q .; then
          built=$((built+1)); log "BUILD OK:   $COMBO  (${SECONDS}s)"
        else
          failed=$((failed+1)); log "BUILD WARN: $COMBO produced no archive (${SECONDS}s) -- see log"
        fi
      else
        failed=$((failed+1)); log "BUILD FAIL: $COMBO (${SECONDS}s) -- see log tail:"
        tail -n 15 "$COMBO_LOG" | sed 's/^/    /' | tee -a "$PROGRESS"
      fi

      # --- cleanup (keep base images/caches, drop this combo's footprint) ---
      docker rmi -f "ghcr.io/btbn/ffmpeg-builds/${COMBO}:latest" >/dev/null 2>&1
      [ -d "$TARGET_CACHE" ] && rm -rf "$TARGET_CACHE"
      docker image prune -f   >/dev/null 2>&1
      docker builder prune -f >/dev/null 2>&1
      log "CLEANUP done: $COMBO   (disk free: $(disk_free))"

    done
  done
done

log "ALL COMBINATIONS PROCESSED. built=$built skipped=$skipped failed=$failed"
log "RunOvernight done."
