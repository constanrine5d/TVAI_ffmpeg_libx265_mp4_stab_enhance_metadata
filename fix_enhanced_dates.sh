#!/opt/homebrew/bin/bash -e

# =========================
# Enhanced Files Date Correction Script
# - Fixes dates and filenames for *_enhanced.mp4 files
# - Uses the corresponding ANMR####.mp4 file as reference
# - Updates filesystem timestamps, EXIF metadata, and renames files
# =========================

# ---- USER CONFIGURATION ----
# File patterns
ENHANCED_PATTERN="*_ANMR*_enhanced.mp4"     # Pattern to match enhanced files
SOURCE_PREFIX="ANMR"                         # Prefix for source files
SOURCE_EXTENSION="mp4"                       # Extension of source reference files

# Tool paths
EXIFTOOL_BIN="/opt/homebrew/bin/exiftool"

# Options
DRY_RUN=false                               # Set to true to preview without making changes
TIMEZONE="+02:00"                           # Timezone offset

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
MAGENTA='\033[0;35m'
NOCOLOR='\033[0m'

# ---- Helper Functions ----
get_file_datetime() {
  local file="$1"
  # Get full modification datetime in YYYY-MM-DD HH:MM:SS format
  if [[ "$OSTYPE" == "darwin"* ]]; then
    stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$file" 2>/dev/null || echo ""
  else
    stat -c "%y" "$file" 2>/dev/null | cut -d' ' -f1,2 | cut -d'.' -f1 || echo ""
  fi
}

format_filename_timestamp() {
  local datetime="$1"
  # Convert "YYYY-MM-DD HH:MM:SS" to "YYYYMMDD_HHMMSS"
  local date="${datetime:0:10}"
  local time="${datetime:11:8}"
  echo "${date//-/}_${time//:}"
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

format_exif_timestamp() {
  local date="$1"
  local time="$2"
  # EXIF format: YYYY:MM:DD HH:MM:SS
  echo "${date//-/:} ${time}"
}

format_full_timestamp() {
  local date="$1"
  local time="$2"
  local tz="$3"
  echo "${date} ${time}${tz}"
}

extract_anmr_number() {
  local filename="$1"
  # Extract ANMR number from filename like "20221231_231204_ANMR0013_enhanced.mp4"
  if [[ "$filename" =~ _ANMR([0-9]+)_ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# ---- Main Script ----
echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════╗${NOCOLOR}"
echo -e "${CYAN}║        Enhanced Files Date Correction - Planning          ║${NOCOLOR}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NOCOLOR}\n"

echo -e "${YELLOW}Configuration:${NOCOLOR}"
echo -e "  Pattern:            ${GREEN}${ENHANCED_PATTERN}${NOCOLOR}"
echo -e "  Source Reference:   ${GREEN}${SOURCE_PREFIX}####.${SOURCE_EXTENSION}${NOCOLOR}"
echo -e "  Timezone:           ${GREEN}${TIMEZONE}${NOCOLOR}"
echo -e "  Working Directory:  ${GREEN}${SCRIPT_DIR}${NOCOLOR}"
[[ "$DRY_RUN" == true ]] && echo -e "  ${MAGENTA}DRY RUN MODE - No changes will be made${NOCOLOR}"
echo ""

# Scan for enhanced files
echo -e "${BLUE}Scanning for enhanced files...${NOCOLOR}\n"

declare -A FILES_TO_PROCESS
TOTAL_FILES=0
SKIPPED_FILES=0
ERROR_FILES=0

for enhanced_file in "${SCRIPT_DIR}"/${ENHANCED_PATTERN}; do
  [[ -f "$enhanced_file" ]] || continue
  
  filename=$(basename "$enhanced_file")
  anmr_num=$(extract_anmr_number "$filename")
  
  if [[ -z "$anmr_num" ]]; then
    echo -e "${RED}✗ Could not extract ANMR number from: ${filename}${NOCOLOR}"
    ERROR_FILES=$((ERROR_FILES + 1))
    continue
  fi
  
  # Remove leading zeros for lookup but keep them for the padded version
  anmr_num_int=$((10#$anmr_num))
  anmr_padded=$(printf "%04d" $anmr_num_int)
  
  # Find the source ANMR file
  source_file="${SCRIPT_DIR}/${SOURCE_PREFIX}${anmr_padded}.${SOURCE_EXTENSION}"
  
  if [[ ! -f "$source_file" ]]; then
    echo -e "${RED}✗ Source file not found: ${SOURCE_PREFIX}${anmr_padded}.${SOURCE_EXTENSION}${NOCOLOR}"
    echo -e "  For enhanced file: ${filename}"
    ERROR_FILES=$((ERROR_FILES + 1))
    continue
  fi
  
  # Get the datetime from the source file
  source_datetime=$(get_file_datetime "$source_file")
  
  if [[ -z "$source_datetime" ]]; then
    echo -e "${RED}✗ Could not read datetime from: ${source_file}${NOCOLOR}"
    ERROR_FILES=$((ERROR_FILES + 1))
    continue
  fi
  
  # Check current datetime of enhanced file
  current_datetime=$(get_file_datetime "$enhanced_file")
  current_date="${current_datetime:0:10}"
  source_date="${source_datetime:0:10}"
  
  # Skip if already correct
  if [[ "$current_date" == "$source_date" ]]; then
    # Check if filename also matches
    new_filename_prefix=$(format_filename_timestamp "$source_datetime")
    expected_filename="${new_filename_prefix}_${SOURCE_PREFIX}${anmr_padded}_enhanced.mp4"
    
    if [[ "$filename" == "$expected_filename" ]]; then
      echo -e "${GREEN}✓ Already correct: ${filename}${NOCOLOR}"
      SKIPPED_FILES=$((SKIPPED_FILES + 1))
      continue
    fi
  fi
  
  # Add to processing queue
  FILES_TO_PROCESS["$enhanced_file"]="$source_datetime"
  
  # Show what will be changed
  new_filename_prefix=$(format_filename_timestamp "$source_datetime")
  new_filename="${new_filename_prefix}_${SOURCE_PREFIX}${anmr_padded}_enhanced.mp4"
  
  echo -e "${YELLOW}${filename}${NOCOLOR}"
  echo -e "  ${CYAN}Reference:${NOCOLOR} ${SOURCE_PREFIX}${anmr_padded}.${SOURCE_EXTENSION} → ${source_datetime}"
  echo -e "  ${RED}Current Date:${NOCOLOR}  ${current_datetime}"
  echo -e "  ${GREEN}New Date:${NOCOLOR}      ${source_datetime}"
  if [[ "$filename" != "$new_filename" ]]; then
    echo -e "  ${MAGENTA}New Filename:${NOCOLOR}  ${new_filename}"
  fi
  echo ""
  
  TOTAL_FILES=$((TOTAL_FILES + 1))
done

# ---- Summary ----
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NOCOLOR}"
echo -e "${CYAN}║                         Summary                            ║${NOCOLOR}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NOCOLOR}\n"

if [[ $TOTAL_FILES -eq 0 ]]; then
  if [[ $SKIPPED_FILES -gt 0 ]]; then
    echo -e "${GREEN}✓ All ${SKIPPED_FILES} enhanced files already have correct dates!${NOCOLOR}\n"
  else
    echo -e "${YELLOW}No enhanced files found to process.${NOCOLOR}\n"
  fi
  [[ $ERROR_FILES -gt 0 ]] && echo -e "${RED}Errors encountered: ${ERROR_FILES}${NOCOLOR}\n"
  exit 0
fi

echo -e "${YELLOW}Files to update:${NOCOLOR}     ${RED}${TOTAL_FILES}${NOCOLOR}"
echo -e "${YELLOW}Already correct:${NOCOLOR}     ${GREEN}${SKIPPED_FILES}${NOCOLOR}"
[[ $ERROR_FILES -gt 0 ]] && echo -e "${YELLOW}Errors/Skipped:${NOCOLOR}      ${RED}${ERROR_FILES}${NOCOLOR}"
echo ""

echo -e "${YELLOW}Actions that will be performed for each file:${NOCOLOR}"
echo -e "  1. ${MAGENTA}Rename file${NOCOLOR} with correct timestamp prefix"
echo -e "  2. Update file ${GREEN}modification date${NOCOLOR} with touch"
echo -e "  3. Update file ${GREEN}creation date${NOCOLOR} with touch"
echo -e "  4. Update all ${GREEN}EXIF date fields${NOCOLOR} with exiftool"
echo ""

if [[ "$DRY_RUN" == true ]]; then
  echo -e "${MAGENTA}DRY RUN MODE - No changes will be made${NOCOLOR}\n"
  exit 0
fi

echo -e "${RED}⚠  WARNING: This will modify and rename ${TOTAL_FILES} files!${NOCOLOR}\n"
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
RENAME_COUNT=0
FAILED_COUNT=0

for enhanced_file in "${!FILES_TO_PROCESS[@]}"; do
  source_datetime="${FILES_TO_PROCESS[$enhanced_file]}"
  source_date="${source_datetime:0:10}"
  source_time="${source_datetime:11:8}"
  
  filename=$(basename "$enhanced_file")
  anmr_num=$(extract_anmr_number "$filename")
  anmr_num_int=$((10#$anmr_num))
  anmr_padded=$(printf "%04d" $anmr_num_int)
  
  echo -e "${YELLOW}Processing: ${filename}${NOCOLOR}"
  
  # Format timestamps
  touch_ts=$(format_touch_timestamp "$source_date" "$source_time")
  exif_ts=$(format_exif_timestamp "$source_date" "$source_time")
  full_ts=$(format_full_timestamp "$source_date" "$source_time" "$TIMEZONE")
  
  # Update filesystem timestamps
  if touch -t "$touch_ts" "$enhanced_file" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NOCOLOR} Updated filesystem dates"
  else
    echo -e "  ${RED}✗${NOCOLOR} Failed to update filesystem dates"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    continue
  fi
  
  # Update EXIF metadata
  if "$EXIFTOOL_BIN" -overwrite_original \
    -AllDates="$exif_ts" \
    -CreateDate="$exif_ts" \
    -ModifyDate="$exif_ts" \
    -DateTimeOriginal="$exif_ts" \
    -TrackCreateDate="$exif_ts" \
    -TrackModifyDate="$exif_ts" \
    -MediaCreateDate="$exif_ts" \
    -MediaModifyDate="$exif_ts" \
    -FileCreateDate="$full_ts" \
    -FileModifyDate="$full_ts" \
    "$enhanced_file" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NOCOLOR} Updated EXIF metadata"
  else
    echo -e "  ${YELLOW}⚠${NOCOLOR} Could not update some EXIF fields"
  fi
  
  # Rename file if needed
  new_filename_prefix=$(format_filename_timestamp "$source_datetime")
  new_filename="${new_filename_prefix}_${SOURCE_PREFIX}${anmr_padded}_enhanced.mp4"
  new_filepath="${SCRIPT_DIR}/${new_filename}"
  
  if [[ "$filename" != "$new_filename" ]]; then
    if mv "$enhanced_file" "$new_filepath" 2>/dev/null; then
      echo -e "  ${MAGENTA}✓${NOCOLOR} Renamed to: ${new_filename}"
      RENAME_COUNT=$((RENAME_COUNT + 1))
      
      # Re-apply touch to renamed file to ensure timestamps stick
      touch -t "$touch_ts" "$new_filepath" 2>/dev/null || true
    else
      echo -e "  ${RED}✗${NOCOLOR} Failed to rename file"
      FAILED_COUNT=$((FAILED_COUNT + 1))
      continue
    fi
  fi
  
  SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  echo ""
done

# ---- Final Summary ----
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NOCOLOR}"
echo -e "${CYAN}║                      Completion Report                     ║${NOCOLOR}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NOCOLOR}\n"

if [[ $FAILED_COUNT -eq 0 ]]; then
  echo -e "${GREEN}✓ Successfully processed ${SUCCESS_COUNT} files!${NOCOLOR}"
  [[ $RENAME_COUNT -gt 0 ]] && echo -e "${GREEN}✓ Renamed ${RENAME_COUNT} files${NOCOLOR}"
  echo -e "${GREEN}✓ All enhanced files have been corrected.${NOCOLOR}\n"
else
  echo -e "${YELLOW}⚠ Processed ${SUCCESS_COUNT} files with ${FAILED_COUNT} failures.${NOCOLOR}\n"
fi

echo -e "${BLUE}Enhanced files should now be properly sorted in Synology Photos.${NOCOLOR}\n"

exit 0
