#!/opt/homebrew/bin/bash -e

# =========================
# Date Correction Script
# - Fixes file modification dates and EXIF metadata
# - Maintains sequential ordering for proper sorting photos
# - Processes ANMR#### files in numerical order
# =========================

# ---- USER CONFIGURATION ----
# Reference file settings
REFERENCE_FILE_NUMBER=12            # The ANMR#### number that has the correct date (e.g., 12 for ANMR0012)
REFERENCE_FILE_EXT="mp4"            # Extension of the reference file to check

# Target date settings
CORRECT_DATE="2025-01-05"           # The correct date in YYYY-MM-DD format (only used if reference file not found)
TIMEZONE="+02:00"                   # Timezone offset

# Increment settings
SECONDS_INCREMENT=60                # Seconds to add between each file (default: 60)
START_FROM_NUMBER=13                # Which ANMR number to start from (files before this are assumed correct)

# File pattern
FILE_PREFIX="ANMR"                  # Prefix for files to process
FILE_EXTENSIONS=("mp4" "sec" "thm") # Extensions to process for each number

# Tool paths
EXIFTOOL_BIN="/opt/homebrew/bin/exiftool"

# ---- Resolve script directory ----
SOURCE=${BASH_SOURCE[0]}
while [ -L "$SOURCE" ]; do
  DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE=$DIR/$SOURCE
done
SCRIPT_DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NOCOLOR='\033[0m'

# ---- Helper Functions ----
get_file_date() {
  local file="$1"
  # Get modification date in YYYY-MM-DD format
  if [[ "$OSTYPE" == "darwin"* ]]; then
    stat -f "%Sm" -t "%Y-%m-%d" "$file" 2>/dev/null || echo ""
  else
    stat -c "%y" "$file" 2>/dev/null | cut -d' ' -f1 || echo ""
  fi
}

get_file_datetime() {
  local file="$1"
  # Get full modification datetime in YYYY-MM-DD HH:MM:SS format
  if [[ "$OSTYPE" == "darwin"* ]]; then
    stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file" 2>/dev/null || echo ""
  else
    stat -c "%y" "$file" 2>/dev/null | cut -d' ' -f1,2 | cut -d'.' -f1 || echo ""
  fi
}

format_timestamp() {
  local date="$1"
  local time="$2"
  local tz="$3"
  echo "${date} ${time}${tz}"
}

format_exif_timestamp() {
  local date="$1"
  local time="$2"
  # EXIF format: YYYY:MM:DD HH:MM:SS
  echo "${date//-/:} ${time}"
}

format_touch_timestamp() {
  local date="$1"
  local time="$2"
  # touch format: YYYYMMDDhhmm.ss
  local year="${date:0:4}"
  local month="${date:5:2}"
  local day="${date:8:2}"
  local hour="${time:0:2}"
  local minute="${time:3:2}"
  local second="${time:6:2}"
  echo "${year}${month}${day}${hour}${minute}.${second}"
}

add_seconds_to_time() {
  local date="$1"
  local time="$2"
  local seconds_to_add="$3"
  
  # Combine date and time
  local datetime="${date} ${time}"
  
  # Add seconds using date command
  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS date command - use Unix timestamp method
    local timestamp=$(date -j -f "%Y-%m-%d %H:%M:%S" "${datetime}" "+%s" 2>/dev/null)
    if [[ -n "$timestamp" ]]; then
      timestamp=$((timestamp + seconds_to_add))
      date -r "$timestamp" "+%Y-%m-%d %H:%M:%S"
    else
      echo "$datetime"
    fi
  else
    # Linux date command
    date -d "${datetime} +${seconds_to_add} seconds" "+%Y-%m-%d %H:%M:%S"
  fi
}

# ---- Scan and Plan ----
echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════╗${NOCOLOR}"
echo -e "${CYAN}║          Date Correction Script - Planning Phase          ║${NOCOLOR}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NOCOLOR}\n"

echo -e "${YELLOW}Configuration:${NOCOLOR}"
echo -e "  Reference File:     ${GREEN}${FILE_PREFIX}$(printf "%04d" ${REFERENCE_FILE_NUMBER}).${REFERENCE_FILE_EXT}${NOCOLOR}"
echo -e "  Correct Date:       ${GREEN}${CORRECT_DATE}${NOCOLOR} (fallback if reference not found)"
echo -e "  Timezone:           ${GREEN}${TIMEZONE}${NOCOLOR}"
echo -e "  Seconds Increment:  ${GREEN}${SECONDS_INCREMENT}${NOCOLOR}"
echo -e "  Start From:         ${GREEN}${FILE_PREFIX}$(printf "%04d" ${START_FROM_NUMBER})${NOCOLOR}"
echo -e "  Extensions:         ${GREEN}${FILE_EXTENSIONS[*]}${NOCOLOR}"
echo -e "  Working Directory:  ${GREEN}${SCRIPT_DIR}${NOCOLOR}\n"

# Get reference datetime from the reference file
REFERENCE_FILE="${SCRIPT_DIR}/${FILE_PREFIX}$(printf "%04d" ${REFERENCE_FILE_NUMBER}).${REFERENCE_FILE_EXT}"
if [[ -f "$REFERENCE_FILE" ]]; then
  REFERENCE_DATETIME=$(get_file_datetime "$REFERENCE_FILE")
  if [[ -n "$REFERENCE_DATETIME" ]]; then
    CURRENT_DATE="${REFERENCE_DATETIME:0:10}"
    CURRENT_TIME="${REFERENCE_DATETIME:11:8}"
    echo -e "${GREEN}✓ Found reference file with datetime: ${REFERENCE_DATETIME}${NOCOLOR}"
    echo -e "${GREEN}  Starting from this timestamp and adding ${SECONDS_INCREMENT}s increments${NOCOLOR}\n"
  else
    echo -e "${YELLOW}⚠ Could not read datetime from reference file${NOCOLOR}"
    echo -e "${YELLOW}  Using fallback: ${CORRECT_DATE} 09:00:00${NOCOLOR}\n"
    CURRENT_DATE="$CORRECT_DATE"
    CURRENT_TIME="09:00:00"
  fi
else
  echo -e "${RED}⚠ Reference file not found: $REFERENCE_FILE${NOCOLOR}"
  echo -e "${YELLOW}  Using fallback: ${CORRECT_DATE} 09:00:00${NOCOLOR}\n"
  CURRENT_DATE="$CORRECT_DATE"
  CURRENT_TIME="09:00:00"
fi

# Build list of files to process
declare -A FILES_TO_PROCESS
TOTAL_FILES=0

echo -e "${BLUE}Scanning for files that need correction...${NOCOLOR}\n"

# Find the highest ANMR number
MAX_NUM=0
for ext in "${FILE_EXTENSIONS[@]}"; do
  for file in "${SCRIPT_DIR}/${FILE_PREFIX}"*."${ext}"; do
    [[ -f "$file" ]] || continue
    basename=$(basename "$file" ".${ext}")
    num="${basename#${FILE_PREFIX}}"
    # Remove leading zeros to avoid octal interpretation
    num=$((10#$num))
    if [[ "$num" =~ ^[0-9]+$ ]] && (( num > MAX_NUM )); then
      MAX_NUM=$num
    fi
  done
done

# Process files in order
for (( num=START_FROM_NUMBER; num<=MAX_NUM; num++ )); do
  file_num=$(printf "%04d" $num)
  file_group="${FILE_PREFIX}${file_num}"
  
  # Check all extensions for this number
  group_needs_update=false
  group_files=()
  
  for ext in "${FILE_EXTENSIONS[@]}"; do
    file="${SCRIPT_DIR}/${file_group}.${ext}"
    if [[ -f "$file" ]]; then
      group_files+=("$file")
      file_date=$(get_file_date "$file")
      if [[ "$file_date" != "$CORRECT_DATE" ]]; then
        group_needs_update=true
      fi
    fi
  done
  
  # If any file in the group needs updating, update all
  if [[ "$group_needs_update" == true ]] && [[ ${#group_files[@]} -gt 0 ]]; then
    # Calculate new timestamp for this group (add increment to previous timestamp)
    new_datetime=$(add_seconds_to_time "$CURRENT_DATE" "$CURRENT_TIME" "$SECONDS_INCREMENT")
    new_date="${new_datetime:0:10}"
    new_time="${new_datetime:11:8}"
    
    FILES_TO_PROCESS["$file_group"]="${new_date}|${new_time}"
    
    # Show what will be changed
    echo -e "${YELLOW}${file_group}${NOCOLOR} (${#group_files[@]} files)"
    for file in "${group_files[@]}"; do
      old_date=$(get_file_date "$file")
      echo -e "  ${CYAN}$(basename "$file")${NOCOLOR}"
      echo -e "    Current: ${RED}${old_date}${NOCOLOR}"
      echo -e "    New:     ${GREEN}${new_date} ${new_time}${NOCOLOR}"
    done
    echo ""
    
    TOTAL_FILES=$((TOTAL_FILES + ${#group_files[@]}))
    
    # Update current timestamp for next iteration
    CURRENT_DATE="$new_date"
    CURRENT_TIME="$new_time"
  fi
done

# ---- Summary and Confirmation ----
if [[ ${#FILES_TO_PROCESS[@]} -eq 0 ]]; then
  echo -e "${GREEN}✓ All files already have the correct date (${CORRECT_DATE})!${NOCOLOR}\n"
  exit 0
fi

echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NOCOLOR}"
echo -e "${CYAN}║                         Summary                            ║${NOCOLOR}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NOCOLOR}\n"
echo -e "${YELLOW}File groups to update:${NOCOLOR} ${RED}${#FILES_TO_PROCESS[@]}${NOCOLOR}"
echo -e "${YELLOW}Total files to update:${NOCOLOR} ${RED}${TOTAL_FILES}${NOCOLOR}"
echo -e "${YELLOW}Date range:${NOCOLOR} ${GREEN}${CORRECT_DATE} ${START_TIME}${NOCOLOR} to ${GREEN}${CURRENT_DATE} ${CURRENT_TIME}${NOCOLOR}\n"

echo -e "${YELLOW}Actions that will be performed for each file:${NOCOLOR}"
echo -e "  1. Update file modification date with ${GREEN}touch${NOCOLOR}"
echo -e "  2. Update file creation date with ${GREEN}touch${NOCOLOR}"
echo -e "  3. Update all EXIF date fields with ${GREEN}exiftool${NOCOLOR}"
echo -e "     - CreateDate, ModifyDate, TrackCreateDate, TrackModifyDate"
echo -e "     - MediaCreateDate, MediaModifyDate, FileCreateDate, FileModifyDate\n"

echo -e "${RED}⚠  WARNING: This will modify ${TOTAL_FILES} files!${NOCOLOR}\n"
read -p "$(echo -e ${YELLOW}Do you want to proceed? [y/N]:${NOCOLOR} )" -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo -e "\n${RED}Operation cancelled by user.${NOCOLOR}\n"
  exit 0
fi

# ---- Execute Changes ----
echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════╗${NOCOLOR}"
echo -e "${CYAN}║                   Applying Changes                         ║${NOCOLOR}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NOCOLOR}\n"

SUCCESS_COUNT=0
ERROR_COUNT=0

for file_group in $(echo "${!FILES_TO_PROCESS[@]}" | tr ' ' '\n' | sort); do
  datetime="${FILES_TO_PROCESS[$file_group]}"
  new_date="${datetime%%|*}"
  new_time="${datetime##*|}"
  
  echo -e "${YELLOW}Processing ${file_group}...${NOCOLOR}"
  
  for ext in "${FILE_EXTENSIONS[@]}"; do
    file="${SCRIPT_DIR}/${file_group}.${ext}"
    [[ -f "$file" ]] || continue
    
    # Format timestamps
    touch_ts=$(format_touch_timestamp "$new_date" "$new_time")
    exif_ts=$(format_exif_timestamp "$new_date" "$new_time")
    full_ts=$(format_timestamp "$new_date" "$new_time" "$TIMEZONE")
    
    echo -e "  ${CYAN}$(basename "$file")${NOCOLOR}"
    
    # Update filesystem timestamps with touch
    if touch -t "$touch_ts" "$file" 2>/dev/null; then
      echo -e "    ${GREEN}✓${NOCOLOR} Updated filesystem dates"
    else
      echo -e "    ${RED}✗${NOCOLOR} Failed to update filesystem dates"
      ERROR_COUNT=$((ERROR_COUNT + 1))
      continue
    fi
    
    # Update EXIF metadata
    if "$EXIFTOOL_BIN" -overwrite_original \
      -AllDates="$exif_ts" \
      -CreateDate="$exif_ts" \
      -ModifyDate="$exif_ts" \
      -TrackCreateDate="$exif_ts" \
      -TrackModifyDate="$exif_ts" \
      -MediaCreateDate="$exif_ts" \
      -MediaModifyDate="$exif_ts" \
      -FileCreateDate="$full_ts" \
      -FileModifyDate="$full_ts" \
      "$file" >/dev/null 2>&1; then
      echo -e "    ${GREEN}✓${NOCOLOR} Updated EXIF metadata"
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
      echo -e "    ${YELLOW}⚠${NOCOLOR} Could not update EXIF metadata (may not be supported for this file type)"
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    fi
  done
  echo ""
done

# ---- Final Summary ----
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NOCOLOR}"
echo -e "${CYAN}║                      Completion Report                     ║${NOCOLOR}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NOCOLOR}\n"

if [[ $ERROR_COUNT -eq 0 ]]; then
  echo -e "${GREEN}✓ Successfully processed ${SUCCESS_COUNT} files!${NOCOLOR}"
  echo -e "${GREEN}✓ All dates have been corrected.${NOCOLOR}\n"
else
  echo -e "${YELLOW}⚠ Processed ${SUCCESS_COUNT} files with ${ERROR_COUNT} errors.${NOCOLOR}\n"
fi

exit 0
