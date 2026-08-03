#!/bin/bash

set -e

# =========================
# Batch H.265 Transcode (Recursive)
# - Outputs -> completed_transcribing/ (mirrors original structure)
# - Filenames use *_out.mp4
# - Metadata & timestamps preserved
# - All audio tracks preserved (per-channel AAC bitrate)
# - Skips completed outputs and excludes completed_transcribing/
# =========================

# ---- USER CONFIGURATION ----
# Optional Topaz Video AI preprocessing. Both values must be exactly true or false.
# USE_TOPAZ_VIDEO_AI=false: direct FFmpeg -> CPU libx265
# USE_TOPAZ_VIDEO_AI=true:  Topaz enhancement -> CPU libx265
USE_TOPAZ_VIDEO_AI=true
# Adds Topaz stabilization before enhancement. Ignored when Topaz is disabled.
USE_TOPAZ_STABILIZATION=true

# Video encoding parameters
VIDEO_CODEC="libx265"              # Codec for video
VIDEO_CRF=28                        # Constant Rate Factor for quality (lower = better quality, larger file)
VIDEO_PRESET="slow"                # Preset for ffmpeg (slow, medium, fast)
AUDIO_CODEC="aac"                  # Audio codec
SUBTITLE_COPY=true                  # Whether to copy subtitle streams

# Output handling
OUTPUT_SUFFIX="_out"               # Suffix appended to filenames before extension
OUTPUT_DIR_NAME="completed_transcribing"  # Root folder for completed videos

# Folders to exclude from scanning (besides OUTPUT_DIR_NAME which is always excluded)
# Example: EXCLUDE_FOLDERS=("folder_to_skip" "folder2")
EXCLUDE_FOLDERS=()

# Progress and estimation
SPEED_X_DEFAULT=0.3                # Initial estimate until live FFmpeg speed is available
TOPAZ_STAB_SPEED_DEFAULT=1.0        # Initial Topaz stabilization-analysis estimate
EXPECTED_OUTPUT_RATIO_DEFAULT=0.35 # Initial output/input estimate; recalibrates live
PROGRESS_REFRESH_SECONDS=1         # FFmpeg progress update interval
PROGRESS_BAR_WIDTH=40               # Width of progress bar


# Supported extensions (lowercase)
EXTS=( "*.mp4" "*.mkv" "*.avi" "*.mov" "*.mts" "*.m2ts" "*.webm" )

# ---- Resolve script directory ----
SOURCE=${BASH_SOURCE[0]}
while [ -L "$SOURCE" ]; do
  DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE=$DIR/$SOURCE
done
CURRENT_DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )

# ---- Colors ----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NOCOLOR='\033[0m'

# ---- Binaries ----
ffmpeg_bin="/opt/homebrew/bin/ffmpeg"
ffprobe_bin="/opt/homebrew/bin/ffprobe"
exiftool_bin="/opt/homebrew/bin/exiftool"
topaz_ffmpeg_bin="/Applications/Topaz Video AI.app/Contents/MacOS/ffmpeg"
topaz_model_dir="/Applications/Topaz Video AI.app/Contents/Resources/models"

# Topaz settings copied from convert_videos_tvai.sh.
TOPAZ_CPE_FILTER="tvai_cpe=model=cpe-2"
TOPAZ_STB_FILTER="tvai_stb=model=ref-2:filename=__STAB_FILE__:smoothness=1.08:rst=0:wst=0:cache=128:dof=1111:ws=32:full=0:roll=1:reduce=0:device=-2:vram=1:instances=1"
TOPAZ_UP_FILTER="tvai_up=model=prob-4:scale=0:preblur=0:noise=0:details=0:halo=0:blur=0:compression=0:estimate=8:blend=0.2:device=-2:vram=1:instances=1"

# ---- Settings ----
COMPLETED_ROOT="$CURRENT_DIR/$OUTPUT_DIR_NAME"

# ---- Estimation speed (X real-time). Example: 1.4 means 1.4x faster than real-time
# Can be overridden by env var SPEED_X or --speed=X cli arg parsing (handled below)
SPEED_X=${SPEED_X:-$SPEED_X_DEFAULT}

# ---- Helpers ----
get_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
get_birthtime() { stat -f %B "$1" 2>/dev/null || echo ""; }
probe_duration() {
  local d=$("$ffprobe_bin" -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null || echo "")
  [[ -n "$d" && "$d" != "N/A" ]] && printf "%.0f\n" "$d" || echo "0"
}
probe_audio_channels_list() { "$ffprobe_bin" -v error -select_streams a -show_entries stream=channels -of csv=p=0 "$1" 2>/dev/null || true; }
probe_audio_stream_count() {
  local count
  count=$(probe_audio_channels_list "$1" | awk 'NF { count++ } END { print count + 0 }')
  printf '%d\n' "$count"
}

# ---- Time helpers for estimates ----
fmt_hms() {
  local s=$1
  [[ "$s" -lt 0 ]] && s=0
  printf "%02d:%02d:%02d" $((s/3600)) $(((s%3600)/60)) $((s%60))
}

fmt_bytes() {
  awk -v bytes="${1:-0}" 'BEGIN {
    split("B KiB MiB GiB TiB", units, " ")
    value = bytes + 0
    unit = 1
    while (value >= 1024 && unit < 5) {
      value /= 1024
      unit++
    }
    if (unit == 1) {
      printf "%.0f %s", value, units[unit]
    } else {
      printf "%.2f %s", value, units[unit]
    }
  }'
}

fmt_speed_milli() {
  awk -v milli="${1:-0}" 'BEGIN { printf "%.2fx", (milli + 0) / 1000 }'
}

fmt_ratio() {
  local output_bytes=${1:-0} input_bytes=${2:-0}
  if (( output_bytes <= 0 || input_bytes <= 0 )); then
    printf 'estimating'
    return
  fi
  awk -v out="$output_bytes" -v input="$input_bytes" 'BEGIN {
    printf "%.1f%% of source | %.2f:1 | %.1f%% saved",
      100 * out / input, input / out, 100 * (1 - out / input)
  }'
}

draw_progress_bar() {
  local progress=$1 total=$2 width=$3
  local percent filled empty i
  if (( total <= 0 )); then
    progress=0
    total=1
  fi
  (( progress < 0 )) && progress=0
  (( progress > total )) && progress=$total
  percent=$((100 * progress / total))
  filled=$((width * progress / total))
  empty=$((width - filled))
  printf "["
  for ((i=0;i<filled;i++)); do printf "#"; done
  for ((i=0;i<empty;i++)); do printf "-"; done
  printf "] %3d%%" "$percent"
}

# Add seconds to NOW in a portable way (macOS and GNU date)
add_seconds_to_now() {
  local secs=$1
  if date -v +1S +%Y-%m-%dT%H:%M:%S >/dev/null 2>&1; then
    # BSD date (macOS)
    date -v+"${secs}"S +"%Y-%m-%d %H:%M:%S"
  else
    # GNU date (Linux)
    date -d "+${secs} seconds" +"%Y-%m-%d %H:%M:%S"
  fi
}

# ---- Validation: output completeness ----
is_output_complete() {
  local input="$1" output="$2"
  
  # Check file exists and has content
  [[ -s "$output" ]] || { echo "  [DEBUG] Output file missing or empty" >&2; return 1; }

  # Check duration
  local din=$(probe_duration "$input") dout=$(probe_duration "$output")
  (( din > 0 && dout > 0 )) || { echo "  [DEBUG] Duration check failed: in=$din out=$dout" >&2; return 1; }
  local tol=$((din/200)); [[ $tol -lt 1 ]] && tol=1
  (( dout < din - tol || dout > din + tol )) && { echo "  [DEBUG] Duration mismatch: in=$din out=$dout tol=$tol" >&2; return 1; }

  # Only check audio streams if input has audio
  local ain=$(probe_audio_stream_count "$input")
  if [[ "$ain" -gt 0 ]]; then
    local aout=$(probe_audio_stream_count "$output")
    [[ "$ain" -eq "$aout" ]] || { echo "  [DEBUG] Audio stream count mismatch: in=$ain out=$aout" >&2; return 1; }

    local in_ch=() out_ch=() ch
    while IFS= read -r ch; do
      [[ -n "$ch" ]] && in_ch+=("$ch")
    done < <(probe_audio_channels_list "$input")
    while IFS= read -r ch; do
      [[ -n "$ch" ]] && out_ch+=("$ch")
    done < <(probe_audio_channels_list "$output")
    for i in "${!in_ch[@]}"; do
      [[ "${out_ch[$i]}" == "${in_ch[$i]}" ]] || { echo "  [DEBUG] Audio channel mismatch at stream $i: in=${in_ch[$i]} out=${out_ch[$i]}" >&2; return 1; }
    done
  fi

  # Check modification time
  local mt_in=$(get_mtime "$input") mt_out=$(get_mtime "$output")
  [[ "$mt_in" == "$mt_out" ]] || { echo "  [DEBUG] mtime mismatch: in=$mt_in out=$mt_out" >&2; return 1; }

  # Check birth time if available
  local bt_in=$(get_birthtime "$input") bt_out=$(get_birthtime "$output")
  if [[ -n "$bt_in" && -n "$bt_out" && "$bt_in" != "$bt_out" ]]; then 
    echo "  [DEBUG] birthtime mismatch: in=$bt_in out=$bt_out" >&2
    return 1
  fi

  return 0
}

fix_timestamps_and_metadata() {
  local input="$1" output="$2"
  # Copy all metadata from input to output
  "$exiftool_bin" -ee -api largefilesupport=1 -overwrite_original -TagsFromFile "$input" -All:All "$output" >/dev/null 2>&1 || true
  # Copy file timestamps from metadata
  "$exiftool_bin" -ee -overwrite_original -api largefilesupport=1 -TagsFromFile "$input" "-FileCreateDate<FileCreateDate" "-FileModifyDate<FileModifyDate" "$output" >/dev/null 2>&1 || true
  # Force filesystem timestamps to match input file
  touch -r "$input" "$output" 2>/dev/null || true
}

# ---- CLI Args ----
for arg in "$@"; do
  case $arg in
    --speed=*) SPEED_X="${arg#*=}" ;;
    *)
      printf 'Unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

# Coerce SPEED_X to the configured default if empty, then validate it before it
# is interpolated into awk/bc expressions.
if [[ -z "$SPEED_X" ]]; then SPEED_X=$SPEED_X_DEFAULT; fi
if ! [[ "$SPEED_X" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] ||
   ! awk -v speed="$SPEED_X" 'BEGIN { exit !(speed > 0) }'; then
  printf 'Invalid speed factor: %s (expected a positive number)\n' "$SPEED_X" >&2
  exit 2
fi
if ! [[ "$EXPECTED_OUTPUT_RATIO_DEFAULT" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] ||
   ! awk -v ratio="$EXPECTED_OUTPUT_RATIO_DEFAULT" 'BEGIN { exit !(ratio > 0) }'; then
  printf 'Invalid expected output ratio: %s\n' "$EXPECTED_OUTPUT_RATIO_DEFAULT" >&2
  exit 2
fi
if ! [[ "$PROGRESS_REFRESH_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  printf 'Invalid progress refresh interval: %s\n' "$PROGRESS_REFRESH_SECONDS" >&2
  exit 2
fi
case "$USE_TOPAZ_VIDEO_AI" in
  true|false) ;;
  *)
    printf 'Invalid USE_TOPAZ_VIDEO_AI value: %s (expected true or false)\n' \
      "$USE_TOPAZ_VIDEO_AI" >&2
    exit 2
    ;;
esac
case "$USE_TOPAZ_STABILIZATION" in
  true|false) ;;
  *)
    printf 'Invalid USE_TOPAZ_STABILIZATION value: %s (expected true or false)\n' \
      "$USE_TOPAZ_STABILIZATION" >&2
    exit 2
    ;;
esac
if ! [[ "$TOPAZ_STAB_SPEED_DEFAULT" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] ||
   ! awk -v speed="$TOPAZ_STAB_SPEED_DEFAULT" 'BEGIN { exit !(speed > 0) }'; then
  printf 'Invalid Topaz stabilization speed estimate: %s\n' \
    "$TOPAZ_STAB_SPEED_DEFAULT" >&2
  exit 2
fi
if [[ "$USE_TOPAZ_VIDEO_AI" == true ]]; then
  if [[ ! -x "$topaz_ffmpeg_bin" ]]; then
    printf 'Topaz FFmpeg is missing or not executable: %s\n' \
      "$topaz_ffmpeg_bin" >&2
    exit 2
  fi
  if [[ ! -d "$topaz_model_dir" ]]; then
    printf 'Topaz model directory is missing: %s\n' "$topaz_model_dir" >&2
    exit 2
  fi
  export TVAI_MODEL_DIR="$topaz_model_dir"
  export TVAI_MODEL_DATA_DIR="$topaz_model_dir"
fi
DEFAULT_OUTPUT_RATIO_PPM=$(awk -v ratio="$EXPECTED_OUTPUT_RATIO_DEFAULT" 'BEGIN { printf "%.0f", ratio * 1000000 }')
TOPAZ_STAB_SPEED_MILLI=$(awk -v speed="$TOPAZ_STAB_SPEED_DEFAULT" 'BEGIN { printf "%.0f", speed * 1000 }')
INITIAL_ENCODE_SPEED_MILLI=$(awk -v speed="$SPEED_X" 'BEGIN { printf "%.0f", speed * 1000 }')
WORK_PHASES_PER_FILE=1
MODE_DESCRIPTION="Direct FFmpeg -> CPU libx265"
TOPAZ_VIDEOAI_METADATA="Enhanced with prob-4 using Topaz Video AI"
if [[ "$USE_TOPAZ_VIDEO_AI" == true ]]; then
  MODE_DESCRIPTION="Topaz enhancement -> CPU libx265"
  if [[ "$USE_TOPAZ_STABILIZATION" == true ]]; then
    WORK_PHASES_PER_FILE=2
    MODE_DESCRIPTION="Topaz stabilization + enhancement -> CPU libx265"
    TOPAZ_VIDEOAI_METADATA="Stabilized with ref-2 and enhanced with prob-4 using Topaz Video AI"
  fi
fi

# ---- Info ----
echo -e "\n${YELLOW}Transcoding videos under:${NOCOLOR} $CURRENT_DIR"
echo -e "${YELLOW}Excluding:${NOCOLOR} $COMPLETED_ROOT"
if [[ ${#EXCLUDE_FOLDERS[@]} -gt 0 ]]; then
  echo -e "${YELLOW}Also excluding folders:${NOCOLOR} ${EXCLUDE_FOLDERS[*]}"
fi
echo -e "${YELLOW}Output:${NOCOLOR} $COMPLETED_ROOT (mirrors structure)"
echo -e "${YELLOW}Mode:${NOCOLOR} $MODE_DESCRIPTION"
echo -e "${YELLOW}Codec:${NOCOLOR} $VIDEO_CODEC CRF $VIDEO_CRF | Audio $AUDIO_CODEC per-stream | Subs copied | ${YELLOW}Est. speed:${NOCOLOR} ${SPEED_X}x"
echo -e "${RED}Existing *${OUTPUT_SUFFIX}.mp4 skipped if complete.${NOCOLOR}\n"

mkdir -p "$COMPLETED_ROOT"

# ---- Scan files (exclude completed_transcribing and EXCLUDE_FOLDERS) ----
TOTAL_VIDEO_SIZE_ORIGINAL=0
VIDEO_FILES=(); VIDEO_SIZES=(); VIDEO_DURATIONS=()

echo -e "${BLUE}Scanning video files...${NOCOLOR}\n"
find_cmd=( find "$CURRENT_DIR" -type d \( -name "$OUTPUT_DIR_NAME" )
for exclude_folder in "${EXCLUDE_FOLDERS[@]}"; do
  find_cmd+=( -o -name "$exclude_folder" )
done
find_cmd+=( \) -prune -o -type f \( -false )
for pat in "${EXTS[@]}"; do find_cmd+=( -o -iname "$pat" ); done
find_cmd+=( \) -print0 )
while IFS= read -r -d '' FILE; do
  FILE_SIZE=$(wc -c < "$FILE")
  DUR=$(probe_duration "$FILE")
  VIDEO_FILES+=("$FILE"); VIDEO_SIZES+=("$FILE_SIZE"); VIDEO_DURATIONS+=("$DUR")
  TOTAL_VIDEO_SIZE_ORIGINAL=$((TOTAL_VIDEO_SIZE_ORIGINAL + FILE_SIZE))
done < <("${find_cmd[@]}")

[[ ${#VIDEO_FILES[@]} -gt 0 ]] || { echo -e "${RED}No video files found.${NOCOLOR}"; exit 1; }

# ---- Sort by size ----
INDICES=(); for i in "${!VIDEO_FILES[@]}"; do INDICES+=("$i"); done
for ((i=0;i<${#INDICES[@]};i++)); do
  for ((j=i+1;j<${#INDICES[@]};j++)); do
    idx1=${INDICES[i]}; idx2=${INDICES[j]}
    if [[ ${VIDEO_SIZES[idx1]} -gt ${VIDEO_SIZES[idx2]} ]]; then tmp=${INDICES[i]}; INDICES[i]=${INDICES[j]}; INDICES[j]=$tmp; fi
  done
done
SORTED_VIDEO_FILES=(); SORTED_VIDEO_SIZES=(); SORTED_VIDEO_DURATIONS=()
for idx in "${INDICES[@]}"; do
  SORTED_VIDEO_FILES+=("${VIDEO_FILES[idx]}"); SORTED_VIDEO_SIZES+=("${VIDEO_SIZES[idx]}"); SORTED_VIDEO_DURATIONS+=("${VIDEO_DURATIONS[idx]}")
done
VIDEO_FILES=("${SORTED_VIDEO_FILES[@]}")
VIDEO_SIZES=("${SORTED_VIDEO_SIZES[@]}")
VIDEO_DURATIONS=("${SORTED_VIDEO_DURATIONS[@]}")

# ---- Build queue and establish the initial live-estimation baseline ----
PER_FILE_EST_SECONDS=()
VIDEO_SKIP_FLAGS=()
QUEUE_FINISH_TIMES=()
TOTAL_EST_SECONDS=0
TOTAL_MEDIA_SECONDS=0
CUMULATIVE_SECONDS=0
SKIPPED_COUNT=0
COMPLETED_INPUT_BYTES=0
COMPLETED_OUTPUT_BYTES=0
COMPLETED_MEDIA_SECONDS=0
NOW_EPOCH=$(date +%s)
for i in "${!VIDEO_FILES[@]}"; do
  FILE="${VIDEO_FILES[i]}"; SZ="${VIDEO_SIZES[i]}"; DUR="${VIDEO_DURATIONS[i]}"
  TOTAL_MEDIA_SECONDS=$((TOTAL_MEDIA_SECONDS + DUR))
  
  # Check if output already exists and is complete
  rel_path="${FILE#$CURRENT_DIR/}"
  rel_dir="$(dirname "$rel_path")"
  input_base="$(basename "$FILE")"
  base_noext="${input_base%.*}"
  dest_dir="$COMPLETED_ROOT/$rel_dir"
  output_file="$dest_dir/${base_noext}${OUTPUT_SUFFIX}.mp4"
  
  WILL_SKIP=false
  if [[ -e "$output_file" ]]; then
    if is_output_complete "$FILE" "$output_file" 2>/dev/null; then
      WILL_SKIP=true
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      COMPLETED_INPUT_BYTES=$((COMPLETED_INPUT_BYTES + SZ))
      COMPLETED_OUTPUT_BYTES=$((COMPLETED_OUTPUT_BYTES + $(wc -c < "$output_file")))
      COMPLETED_MEDIA_SECONDS=$((COMPLETED_MEDIA_SECONDS + DUR))
    fi
  fi
  VIDEO_SKIP_FLAGS+=("$WILL_SKIP")
  
  # estimated seconds for this file at SPEED_X
  if [[ "$DUR" -gt 0 &&
        "$USE_TOPAZ_VIDEO_AI" == true &&
        "$USE_TOPAZ_STABILIZATION" == true ]]; then
    EST=$(echo "$DUR / $TOPAZ_STAB_SPEED_DEFAULT + $DUR / $SPEED_X" | bc -l)
  else
    EST=$([[ "$DUR" -gt 0 ]] && echo "$DUR / $SPEED_X" | bc -l || echo 0)
  fi
  EST_INT=$(printf "%.0f" "$EST")
  PER_FILE_EST_SECONDS+=("$EST_INT")
  
  if [[ "$WILL_SKIP" == false ]]; then
    TOTAL_EST_SECONDS=$((TOTAL_EST_SECONDS + EST_INT))
    CUMULATIVE_SECONDS=$((CUMULATIVE_SECONDS + EST_INT))
    FINISH_TS=$(add_seconds_to_now "$CUMULATIVE_SECONDS")
    QUEUE_FINISH_TIMES+=("$FINISH_TS")
  else
    QUEUE_FINISH_TIMES+=("")
  fi
done

# Initial output-size projection uses verified completed files when available,
# otherwise the configured default. It is replaced by live observations.
INITIAL_RATIO_PPM=$DEFAULT_OUTPUT_RATIO_PPM
if (( COMPLETED_INPUT_BYTES > 0 )); then
  INITIAL_RATIO_PPM=$((COMPLETED_OUTPUT_BYTES * 1000000 / COMPLETED_INPUT_BYTES))
fi
INITIAL_EXPECTED_OUTPUT_BYTES=$((COMPLETED_OUTPUT_BYTES
  + (TOTAL_VIDEO_SIZE_ORIGINAL - COMPLETED_INPUT_BYTES) * INITIAL_RATIO_PPM / 1000000))
TOTAL_WORK_SECONDS=$((TOTAL_MEDIA_SECONDS * WORK_PHASES_PER_FILE))
TOTAL_EST_HMS=$(fmt_hms "$TOTAL_EST_SECONDS")
TOTAL_FINISH_TS=$(add_seconds_to_now "$TOTAL_EST_SECONDS")

# Always show the complete queue before asking for confirmation. The two-line
# layout remains readable when paths are long and the terminal wraps them.
QUEUE_NUMBER_WIDTH=${#VIDEO_FILES[@]}
QUEUE_NUMBER_WIDTH=${#QUEUE_NUMBER_WIDTH}
echo -e "${BLUE}╭─ PROCESSING QUEUE ────────────────────────────────────────${NOCOLOR}"
for i in "${!VIDEO_FILES[@]}"; do
  FILE="${VIDEO_FILES[i]}"
  SZ="${VIDEO_SIZES[i]}"
  DUR="${VIDEO_DURATIONS[i]}"
  EST_INT="${PER_FILE_EST_SECONDS[i]}"
  rel_path="${FILE#$CURRENT_DIR/}"
  queue_number=$((i + 1))

  if [[ "${VIDEO_SKIP_FLAGS[i]}" == true ]]; then
    printf "${GREEN}│  ✓ %0*d  SKIP${NOCOLOR}    %s\n" \
      "$QUEUE_NUMBER_WIDTH" "$queue_number" "$rel_path"
    printf "│       %s  •  duration %s  •  already verified\n" \
      "$(fmt_bytes "$SZ")" "$(fmt_hms "$DUR")"
  else
    printf "${YELLOW}│  ▶ %0*d  QUEUED${NOCOLOR}  %s\n" \
      "$QUEUE_NUMBER_WIDTH" "$queue_number" "$rel_path"
    printf "│       %s  •  duration %s  •  est. %s  •  finish %s\n" \
      "$(fmt_bytes "$SZ")" "$(fmt_hms "$DUR")" \
      "$(fmt_hms "$EST_INT")" "${QUEUE_FINISH_TIMES[i]}"
  fi

  if (( i + 1 < ${#VIDEO_FILES[@]} )); then
    printf "│\n"
  fi
done
echo -e "${BLUE}╰───────────────────────────────────────────────────────────${NOCOLOR}\n"

echo -e "${BLUE}QUEUE SUMMARY${NOCOLOR}"
echo -e "${YELLOW}Files to process:${NOCOLOR} $((${#VIDEO_FILES[@]} - SKIPPED_COUNT)) / ${#VIDEO_FILES[@]} ${GREEN}($SKIPPED_COUNT already complete)${NOCOLOR}"
echo -e "${YELLOW}Source size:${NOCOLOR} $(fmt_bytes "$TOTAL_VIDEO_SIZE_ORIGINAL")"
echo -e "${YELLOW}Initial expected output:${NOCOLOR} $(fmt_bytes "$INITIAL_EXPECTED_OUTPUT_BYTES") ($(fmt_ratio "$INITIAL_EXPECTED_OUTPUT_BYTES" "$TOTAL_VIDEO_SIZE_ORIGINAL"))"
echo -e "${YELLOW}Total estimated processing time:${NOCOLOR} ${RED}${TOTAL_EST_HMS}${NOCOLOR}"
echo -e "${YELLOW}Estimated batch completion time:${NOCOLOR} ${RED}${TOTAL_FINISH_TS}${NOCOLOR}\n"

# Wait for explicit confirmation AFTER showing the queue and totals
echo -e "Press Enter to process the QUEUED files or Ctrl+C to abort"
read -rp "" _

# ---- Process ----
NUM_FILES=${#VIDEO_FILES[@]}
DASHBOARD_TTY=false
[[ -t 1 ]] && DASHBOARD_TTY=true
BATCH_WALL_START=$(date +%s)
RUN_ENCODED_MEDIA_SECONDS=0
PROCESSED_FILES=$SKIPPED_COUNT

render_dashboard() {
  local input_file="$1" file_number=$2 stage="$3"
  local out_seconds=$4 duration=$5 current_speed_milli=$6 batch_speed_milli=$7
  local current_written=$8 projected_current=$9 expected_total=${10}
  local overall_done=${11} current_eta=${12} total_eta=${13}
  local finish_time="${14}" current_input_size=${15}
  local overall_written=$((COMPLETED_OUTPUT_BYTES + current_written))

  if [[ "$DASHBOARD_TTY" == true ]]; then
    printf '\033[2J\033[H'
    printf "${BLUE}H.265 TRANSCODE DASHBOARD${NOCOLOR}\n"
    printf "File:    %d/%d  %s\n" "$file_number" "$NUM_FILES" "$(basename "$input_file")"
    printf "Stage:   %s\n\n" "$stage"
    printf "Current: "
    draw_progress_bar "$out_seconds" "$duration" "$PROGRESS_BAR_WIDTH"
    printf "  %s / %s\n" "$(fmt_hms "$out_seconds")" "$(fmt_hms "$duration")"
    printf "Overall: "
    draw_progress_bar "$overall_done" "$TOTAL_WORK_SECONDS" "$PROGRESS_BAR_WIDTH"
    printf "  %d/%d files complete\n\n" "$PROCESSED_FILES" "$NUM_FILES"
    printf "Speed:   current %s | batch average %s\n" \
      "$(fmt_speed_milli "$current_speed_milli")" \
      "$(fmt_speed_milli "$batch_speed_milli")"
    printf "Current output: %s written | %s projected\n" \
      "$(fmt_bytes "$current_written")" "$(fmt_bytes "$projected_current")"
    printf "Current ratio:  %s\n" "$(fmt_ratio "$projected_current" "$current_input_size")"
    printf "Total output:   %s written | %s projected\n" \
      "$(fmt_bytes "$overall_written")" "$(fmt_bytes "$expected_total")"
    printf "Total ratio:    %s\n" "$(fmt_ratio "$expected_total" "$TOTAL_VIDEO_SIZE_ORIGINAL")"
    printf "ETA:      file %s | batch %s | finish %s\n" \
      "$(fmt_hms "$current_eta")" "$(fmt_hms "$total_eta")" "$finish_time"
  else
    printf '[%d/%d] %s | %s/%s | speed %s | projected %s | total %s | ETA %s/%s\n' \
      "$file_number" "$NUM_FILES" "$(basename "$input_file")" \
      "$(fmt_hms "$out_seconds")" "$(fmt_hms "$duration")" \
      "$(fmt_speed_milli "$current_speed_milli")" \
      "$(fmt_bytes "$projected_current")" "$(fmt_bytes "$expected_total")" \
      "$(fmt_hms "$current_eta")" "$(fmt_hms "$total_eta")"
  fi
}

monitor_ffmpeg_progress() {
  local input_file="$1" file_number=$2 duration=$3 input_size=$4
  local future_input_bytes=$5 future_duration=$6
  local stage="$7" phase_offset=$8
  local key value progress_state=""
  local out_time_us=0 out_seconds=0 current_written=0
  local current_speed_milli
  local batch_speed_milli ratio_ppm projected_current expected_total
  local threshold effective_ratio_ppm overall_done remaining_media current_eta total_eta
  local now wall run_media finish_time last_log_epoch=0

  current_speed_milli=$(awk -v speed="$SPEED_X" 'BEGIN { printf "%.0f", speed * 1000 }')

  while IFS='=' read -r key value; do
    case "$key" in
      out_time_us)
        [[ "$value" =~ ^[0-9]+$ ]] && out_time_us=$value
        ;;
      total_size)
        [[ "$value" =~ ^[0-9]+$ ]] && current_written=$value
        ;;
      speed)
        value="${value%x}"
        if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
          current_speed_milli=$(awk -v speed="$value" 'BEGIN { printf "%.0f", speed * 1000 }')
        fi
        ;;
      progress)
        progress_state="$value"
        out_seconds=$((out_time_us / 1000000))
        (( out_seconds > duration )) && out_seconds=$duration

        # Project the current output after enough media has been observed.
        threshold=$((duration / 20))
        (( threshold < 5 )) && threshold=5
        ratio_ppm=$DEFAULT_OUTPUT_RATIO_PPM
        if (( COMPLETED_INPUT_BYTES > 0 )); then
          ratio_ppm=$((COMPLETED_OUTPUT_BYTES * 1000000 / COMPLETED_INPUT_BYTES))
        fi
        if (( out_seconds >= threshold && current_written > 0 )); then
          projected_current=$((current_written * duration / out_seconds))
        else
          projected_current=$((input_size * ratio_ppm / 1000000))
        fi
        (( projected_current < current_written )) && projected_current=$current_written

        effective_ratio_ppm=$ratio_ppm
        if (( COMPLETED_INPUT_BYTES + input_size > 0 )); then
          effective_ratio_ppm=$(((COMPLETED_OUTPUT_BYTES + projected_current) * 1000000
            / (COMPLETED_INPUT_BYTES + input_size)))
        fi
        expected_total=$((COMPLETED_OUTPUT_BYTES + projected_current
          + future_input_bytes * effective_ratio_ppm / 1000000))

        now=$(date +%s)
        wall=$((now - BATCH_WALL_START))
        run_media=$((RUN_ENCODED_MEDIA_SECONDS + out_seconds))
        batch_speed_milli=$current_speed_milli
        if (( wall > 0 && run_media > 0 )); then
          batch_speed_milli=$((run_media * 1000 / wall))
        fi
        (( current_speed_milli <= 0 )) && current_speed_milli=1
        (( batch_speed_milli <= 0 )) && batch_speed_milli=$current_speed_milli
        (( batch_speed_milli <= 0 )) && batch_speed_milli=1

        current_eta=$(((duration - out_seconds) * 1000 / current_speed_milli))
        if [[ "$USE_TOPAZ_VIDEO_AI" == true &&
              "$USE_TOPAZ_STABILIZATION" == true ]]; then
          # batch_speed_milli is the effective rate across both Topaz phases.
          total_eta=$((current_eta + future_duration * 1000 / batch_speed_milli))
        else
          remaining_media=$((duration - out_seconds + future_duration))
          total_eta=$((remaining_media * 1000 / batch_speed_milli))
        fi
        finish_time=$(add_seconds_to_now "$total_eta")
        overall_done=$((COMPLETED_MEDIA_SECONDS * WORK_PHASES_PER_FILE
          + phase_offset + out_seconds))

        if [[ "$DASHBOARD_TTY" == false && "$progress_state" != "end" ]] &&
           (( now - last_log_epoch < 10 )); then
          continue
        fi
        last_log_epoch=$now
        render_dashboard \
          "$input_file" "$file_number" "$stage" \
          "$out_seconds" "$duration" "$current_speed_milli" "$batch_speed_milli" \
          "$current_written" "$projected_current" "$expected_total" \
          "$overall_done" "$current_eta" "$total_eta" "$finish_time" "$input_size"
        ;;
    esac
  done
  return 0
}

monitor_topaz_analysis_progress() {
  local input_file="$1" file_number=$2 duration=$3 input_size=$4
  local future_input_bytes=$5 future_duration=$6
  local key value progress_state=""
  local out_time_us=0 out_seconds=0 current_speed_milli
  local ratio_ppm projected_current expected_total overall_done
  local current_eta total_eta finish_time now last_log_epoch=0

  current_speed_milli=$TOPAZ_STAB_SPEED_MILLI
  ratio_ppm=$DEFAULT_OUTPUT_RATIO_PPM
  if (( COMPLETED_INPUT_BYTES > 0 )); then
    ratio_ppm=$((COMPLETED_OUTPUT_BYTES * 1000000 / COMPLETED_INPUT_BYTES))
  fi
  projected_current=$((input_size * ratio_ppm / 1000000))
  expected_total=$((COMPLETED_OUTPUT_BYTES + projected_current
    + future_input_bytes * ratio_ppm / 1000000))

  while IFS='=' read -r key value; do
    case "$key" in
      out_time_us)
        [[ "$value" =~ ^[0-9]+$ ]] && out_time_us=$value
        ;;
      speed)
        value="${value%x}"
        if [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
          current_speed_milli=$(awk -v speed="$value" \
            'BEGIN { printf "%.0f", speed * 1000 }')
        fi
        ;;
      progress)
        progress_state="$value"
        out_seconds=$((out_time_us / 1000000))
        (( out_seconds > duration )) && out_seconds=$duration
        (( current_speed_milli <= 0 )) && current_speed_milli=1

        # Include the rest of this analysis, this file's enhancement/encode,
        # and both phases for every future file.
        current_eta=$(((duration - out_seconds) * 1000 / current_speed_milli))
        total_eta=$((current_eta
          + duration * 1000 / INITIAL_ENCODE_SPEED_MILLI
          + future_duration * 1000 / TOPAZ_STAB_SPEED_MILLI
          + future_duration * 1000 / INITIAL_ENCODE_SPEED_MILLI))
        finish_time=$(add_seconds_to_now "$total_eta")
        overall_done=$((COMPLETED_MEDIA_SECONDS * WORK_PHASES_PER_FILE
          + out_seconds))

        now=$(date +%s)
        if [[ "$DASHBOARD_TTY" == false && "$progress_state" != "end" ]] &&
           (( now - last_log_epoch < 10 )); then
          continue
        fi
        last_log_epoch=$now
        render_dashboard \
          "$input_file" "$file_number" "Topaz stabilization analysis" \
          "$out_seconds" "$duration" "$current_speed_milli" \
          "$current_speed_milli" 0 "$projected_current" "$expected_total" \
          "$overall_done" "$current_eta" "$total_eta" "$finish_time" "$input_size"
        ;;
    esac
  done
  return 0
}

render_postprocess_stage() {
  local input_file="$1" file_number=$2 stage="$3"
  if [[ "$DASHBOARD_TTY" == true ]]; then
    printf '\033[2J\033[H'
    printf "${BLUE}H.265 TRANSCODE DASHBOARD${NOCOLOR}\n"
    printf "File:    %d/%d  %s\n" "$file_number" "$NUM_FILES" "$(basename "$input_file")"
    printf "Stage:   %s\n" "$stage"
  else
    printf '[%d/%d] %s | %s\n' "$file_number" "$NUM_FILES" "$(basename "$input_file")" "$stage"
  fi
}

FAILED_COUNT=0
for idx in "${!VIDEO_FILES[@]}"; do
  input_file="${VIDEO_FILES[idx]}"
  input_size="${VIDEO_SIZES[idx]}"
  duration="${VIDEO_DURATIONS[idx]}"
  file_number=$((idx + 1))
  rel_path="${input_file#$CURRENT_DIR/}"
  rel_dir="$(dirname "$rel_path")"
  input_base="$(basename "$input_file")"
  base_noext="${input_base%.*}"
  dest_dir="$COMPLETED_ROOT/$rel_dir"
  mkdir -p "$dest_dir"
  output_file="$dest_dir/${base_noext}${OUTPUT_SUFFIX}.mp4"

  # Skip outputs that were verified while building the queue.
  if [[ "${VIDEO_SKIP_FLAGS[idx]}" == true ]]; then
    if [[ "$DASHBOARD_TTY" == false ]]; then
      echo -e "${GREEN}Skipping complete:${NOCOLOR} $output_file"
    fi
    continue
  fi

  # An incomplete output may only need its metadata/timestamps repaired.
  if [[ -e "$output_file" ]]; then
    echo -e "${YELLOW}Re-checking incomplete output:${NOCOLOR} $output_file"
    fix_timestamps_and_metadata "$input_file" "$output_file"
    if is_output_complete "$input_file" "$output_file"; then
      echo -e "${GREEN}Fixed metadata/timestamps:${NOCOLOR} $output_file"
      COMPLETED_INPUT_BYTES=$((COMPLETED_INPUT_BYTES + input_size))
      COMPLETED_OUTPUT_BYTES=$((COMPLETED_OUTPUT_BYTES + $(wc -c < "$output_file")))
      COMPLETED_MEDIA_SECONDS=$((COMPLETED_MEDIA_SECONDS + duration))
      PROCESSED_FILES=$((PROCESSED_FILES + 1))
      continue
    fi
    echo -e "${RED}Re-encoding incomplete file...${NOCOLOR}"
  fi

  # Remaining source bytes/duration drive the live total-size and ETA models.
  future_input_bytes=0
  future_duration=0
  for ((future_idx=idx+1; future_idx<NUM_FILES; future_idx++)); do
    if [[ "${VIDEO_SKIP_FLAGS[future_idx]}" == false ]]; then
      future_input_bytes=$((future_input_bytes + VIDEO_SIZES[future_idx]))
      future_duration=$((future_duration + VIDEO_DURATIONS[future_idx]))
    fi
  done

  # Build per-audio-stream AAC args preserving channels
  audio_args=(); a_idx=0
  while IFS= read -r ch; do
    [[ -z "$ch" ]] && continue
    if (( ch <= 1 )); then br="96k"
    elif (( ch == 2 )); then br="160k"
    else br="384k"
    fi
    audio_args+=( -c:a:$a_idx "$AUDIO_CODEC" -b:a:$a_idx "$br" )
    a_idx=$((a_idx + 1))
  done < <(probe_audio_channels_list "$input_file")

  # Check if file has audio streams
  has_audio=false
  if [[ ${#audio_args[@]} -gt 0 ]]; then
    has_audio=true
  fi

  # Transcode. Topaz, when enabled, writes a lossless NUT stream to the
  # Homebrew FFmpeg process; final encoding always remains CPU libx265/CRF 28.
  error_log="$dest_dir/.${base_noext}${OUTPUT_SUFFIX}.ffmpeg-error.log"
  : > "$error_log"

  if [[ "$USE_TOPAZ_VIDEO_AI" == true ]]; then
    stabilization_file="$dest_dir/.${base_noext}${OUTPUT_SUFFIX}_stabilization.trf"
    topaz_process_filter="$TOPAZ_UP_FILTER"
    topaz_phase_offset=0
    processing_stage="Topaz enhancement + CPU encoding"

    if [[ "$USE_TOPAZ_STABILIZATION" == true ]]; then
      rm -f "$stabilization_file"
      render_postprocess_stage \
        "$input_file" "$file_number" "Starting Topaz stabilization analysis"
      set +e
      "$topaz_ffmpeg_bin" -y -nostdin -hide_banner -loglevel error -nostats \
        -stats_period "$PROGRESS_REFRESH_SECONDS" -progress pipe:1 \
        -i "$input_file" \
        -flush_packets 1 \
        -sws_flags spline+accurate_rnd+full_chroma_int \
        -filter_complex \
        "[0:v:0]${TOPAZ_CPE_FILTER}:filename=${stabilization_file}:device=-2[v]" \
        -map "[v]" \
        -f null - 2>>"$error_log" |
        monitor_topaz_analysis_progress \
          "$input_file" "$file_number" "$duration" "$input_size" \
          "$future_input_bytes" "$future_duration"
      analysis_pipeline_status=("${PIPESTATUS[@]}")
      set -e
      topaz_analysis_status=${analysis_pipeline_status[0]}
      if [[ "$topaz_analysis_status" -ne 0 ]]; then
        render_postprocess_stage \
          "$input_file" "$file_number" "Topaz stabilization analysis failed"
        echo -e "${RED}Topaz analysis failed with status $topaz_analysis_status.${NOCOLOR}" >&2
        sed -n '1,120p' "$error_log" >&2
        echo "Error log retained at: $error_log" >&2
        [[ -e "$stabilization_file" ]] &&
          echo "Stabilization data retained at: $stabilization_file" >&2
        exit "$topaz_analysis_status"
      fi

      topaz_stb_filter="${TOPAZ_STB_FILTER/__STAB_FILE__/$stabilization_file}"
      topaz_process_filter="${topaz_stb_filter},${TOPAZ_UP_FILTER}"
      topaz_phase_offset=$duration
      processing_stage="Topaz stabilization/enhancement + CPU encoding"
    fi

    topaz_audio_args=()
    output_audio_map_args=()
    if [[ "$has_audio" == true ]]; then
      topaz_audio_args=( -map 0:a -c:a copy )
      output_audio_map_args=( -map 0:a )
    fi

    set +e
    "$topaz_ffmpeg_bin" -y -nostdin -hide_banner -loglevel error -nostats \
      -i "$input_file" \
      -flush_packets 1 \
      -sws_flags spline+accurate_rnd+full_chroma_int \
      -filter_complex "[0:v:0]${topaz_process_filter}[v]" \
      -map "[v]" "${topaz_audio_args[@]}" \
      -c:v huffyuv -pix_fmt yuv422p \
      -f nut - 2>>"$error_log" |
      "$ffmpeg_bin" -y -nostdin -hide_banner -loglevel error -nostats \
        -stats_period "$PROGRESS_REFRESH_SECONDS" -progress pipe:1 \
        -copyts -i - \
        -map 0:v:0 "${output_audio_map_args[@]}" -map_metadata 0 \
        -c:v:0 "$VIDEO_CODEC" -preset "$VIDEO_PRESET" -pix_fmt yuv420p \
        -crf "$VIDEO_CRF" -tag:v:0 hvc1 \
        "${audio_args[@]}" \
        -metadata "videoai=$TOPAZ_VIDEOAI_METADATA" \
        -movflags +faststart \
        "$output_file" 2>>"$error_log" |
      monitor_ffmpeg_progress \
        "$input_file" "$file_number" "$duration" "$input_size" \
        "$future_input_bytes" "$future_duration" \
        "$processing_stage" "$topaz_phase_offset"
    encode_pipeline_status=("${PIPESTATUS[@]}")
    set -e
    topaz_status=${encode_pipeline_status[0]}
    ffmpeg_status=${encode_pipeline_status[1]}
    if [[ "$topaz_status" -ne 0 || "$ffmpeg_status" -ne 0 ]]; then
      render_postprocess_stage "$input_file" "$file_number" "Topaz encoding failed"
      echo -e "${RED}Topaz/FFmpeg failed (Topaz $topaz_status, FFmpeg $ffmpeg_status).${NOCOLOR}" >&2
      sed -n '1,120p' "$error_log" >&2
      echo "Error log retained at: $error_log" >&2
      [[ -e "$stabilization_file" ]] &&
        echo "Stabilization data retained at: $stabilization_file" >&2
      if [[ "$ffmpeg_status" -ne 0 ]]; then
        exit "$ffmpeg_status"
      fi
      exit "$topaz_status"
    fi
    [[ "$USE_TOPAZ_STABILIZATION" == true ]] && rm -f "$stabilization_file"
  else
    set +e
    if [[ "$has_audio" == true ]]; then
      "$ffmpeg_bin" -y -nostdin -hide_banner -loglevel error -nostats \
        -stats_period "$PROGRESS_REFRESH_SECONDS" -progress pipe:1 \
        -i "$input_file" \
        -map 0:v:0 -map 0:a -map_metadata 0 \
        -c:v:0 "$VIDEO_CODEC" -preset "$VIDEO_PRESET" -crf "$VIDEO_CRF" \
        -tag:v:0 hvc1 \
        "${audio_args[@]}" \
        -movflags +faststart \
        "$output_file" 2>"$error_log" |
        monitor_ffmpeg_progress \
          "$input_file" "$file_number" "$duration" "$input_size" \
          "$future_input_bytes" "$future_duration" "Encoding" 0
      ffmpeg_status=${PIPESTATUS[0]}
    else
      # No audio streams - only encode video
      "$ffmpeg_bin" -y -nostdin -hide_banner -loglevel error -nostats \
        -stats_period "$PROGRESS_REFRESH_SECONDS" -progress pipe:1 \
        -i "$input_file" \
        -map 0:v:0 -map_metadata 0 \
        -c:v:0 "$VIDEO_CODEC" -preset "$VIDEO_PRESET" -crf "$VIDEO_CRF" \
        -tag:v:0 hvc1 \
        -movflags +faststart \
        "$output_file" 2>"$error_log" |
        monitor_ffmpeg_progress \
          "$input_file" "$file_number" "$duration" "$input_size" \
          "$future_input_bytes" "$future_duration" "Encoding" 0
      ffmpeg_status=${PIPESTATUS[0]}
    fi
    set -e
    if [[ "$ffmpeg_status" -ne 0 ]]; then
      render_postprocess_stage "$input_file" "$file_number" "Encoding failed"
      echo -e "${RED}FFmpeg failed with status $ffmpeg_status.${NOCOLOR}" >&2
      sed -n '1,120p' "$error_log" >&2
      echo "Error log retained at: $error_log" >&2
      exit "$ffmpeg_status"
    fi
  fi
  rm -f "$error_log"

  # Add thumbnail as poster frame
  # Extract first frame as JPEG
  render_postprocess_stage "$input_file" "$file_number" "Generating thumbnail"
  temp_thumb="${output_file%.mp4}_thumb.jpg"
  "$ffmpeg_bin" -y -i "$input_file" -vframes 1 -q:v 2 "$temp_thumb" >/dev/null 2>&1
  
  # Re-mux with thumbnail as attached pic
  if [[ -f "$temp_thumb" ]]; then
    render_postprocess_stage "$input_file" "$file_number" "Attaching thumbnail"
    temp_output="${output_file%.mp4}_temp.mp4"
    "$ffmpeg_bin" -y -i "$output_file" -i "$temp_thumb" \
      -map 0 -map 1 \
      -c copy -tag:v:0 hvc1 -disposition:v:1 attached_pic \
      -movflags +faststart \
      "$temp_output" >/dev/null 2>&1
    
    if [[ -f "$temp_output" && -s "$temp_output" ]]; then
      mv "$temp_output" "$output_file"
    fi
    rm -f "$temp_thumb" "$temp_output"
  fi

  # Metadata/timestamps - must be done AFTER all file modifications
  render_postprocess_stage "$input_file" "$file_number" "Copying metadata and timestamps"
  fix_timestamps_and_metadata "$input_file" "$output_file"
  
  # Final timestamp sync - ensure filesystem timestamps match exactly
  touch -r "$input_file" "$output_file" 2>/dev/null || true

  # Verify
  if is_output_complete "$input_file" "$output_file"; then
    actual_output_size=$(wc -c < "$output_file")
    COMPLETED_INPUT_BYTES=$((COMPLETED_INPUT_BYTES + input_size))
    COMPLETED_OUTPUT_BYTES=$((COMPLETED_OUTPUT_BYTES + actual_output_size))
    COMPLETED_MEDIA_SECONDS=$((COMPLETED_MEDIA_SECONDS + duration))
    RUN_ENCODED_MEDIA_SECONDS=$((RUN_ENCODED_MEDIA_SECONDS + duration))
    PROCESSED_FILES=$((PROCESSED_FILES + 1))
    render_postprocess_stage "$input_file" "$file_number" \
      "Complete — $(fmt_bytes "$actual_output_size"), $(fmt_ratio "$actual_output_size" "$input_size")"
    if [[ "$DASHBOARD_TTY" == false ]]; then
      echo -e "${GREEN}✓ Completed:${NOCOLOR} $output_file\n"
    fi
  else
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo -e "${RED}⚠ WARNING:${NOCOLOR} $output_file failed validation.\n"
  fi
done

BATCH_WALL_SECONDS=$(($(date +%s) - BATCH_WALL_START))
FINAL_AVERAGE_SPEED_MILLI=0
if (( BATCH_WALL_SECONDS > 0 && RUN_ENCODED_MEDIA_SECONDS > 0 )); then
  FINAL_AVERAGE_SPEED_MILLI=$((RUN_ENCODED_MEDIA_SECONDS * 1000 / BATCH_WALL_SECONDS))
fi
if [[ "$DASHBOARD_TTY" == true ]]; then
  printf '\033[2J\033[H'
fi
echo -e "${GREEN}TRANSCODE BATCH COMPLETE${NOCOLOR}"
echo "Verified files: $PROCESSED_FILES / $NUM_FILES"
echo "Output size:    $(fmt_bytes "$COMPLETED_OUTPUT_BYTES")"
echo "Compression:    $(fmt_ratio "$COMPLETED_OUTPUT_BYTES" "$COMPLETED_INPUT_BYTES")"
echo "Elapsed:        $(fmt_hms "$BATCH_WALL_SECONDS")"
echo "Average speed:  $(fmt_speed_milli "$FINAL_AVERAGE_SPEED_MILLI")"
echo "Output folder:  $COMPLETED_ROOT"
if (( FAILED_COUNT > 0 )); then
  echo -e "${RED}Validation failures: $FAILED_COUNT${NOCOLOR}" >&2
  exit 1
fi
exit 0
