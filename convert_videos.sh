#!/bin/bash -e

# Resolve script's current directory
SOURCE=${BASH_SOURCE[0]}
while [ -L "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE=$DIR/$SOURCE # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
CURRENT_DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NOCOLOR='\033[0m' # No Color

# --- Conversion speed estimates (relative to video duration) ---
# E.g., 0.25 means conversion is 4x slower than real time (1hr video = 4hr conv)
CONVERSION_SPEED_ESTIMATE=0.25
STAB_SPEED_ESTIMATE=1

# Progress bar settings
PROGRESS_BAR_WIDTH=40

# Introduction
echo -e "\n${YELLOW}This bash script will convert the videos in its current directory (and all subdirectories recursively) with Topaz Video AI stabilization and enhancement and libx265.${NOCOLOR}\n\n${GREEN}Please ALWAYS look at the settings before each run (ex. change 420 to 422).${NOCOLOR}\n\n${RED}Output files are automatically replaced without warning.${NOCOLOR}"
echo -e "\n${YELLOW}Please also change the locations of topaz_ffmpeg and homebrew_ffmpeg in the script.\n${NOCOLOR}"
echo -e "Press Enter to continue or Ctrl+Z to exit"
read

# Set FFMPEG locations
topaz_ffmpeg="/Applications/Topaz Video AI.app/Contents/MacOS/ffmpeg"
homebrew_ffmpeg="/opt/homebrew/bin/ffmpeg"
exiftool="/opt/homebrew/bin/exiftool"

export TVAI_MODEL_DIR="/Applications/Topaz Video AI.app/Contents/Resources/models"
export TVAI_MODEL_DATA_DIR="/Applications/Topaz Video AI.app/Contents/Resources/models"

echo -e "Topaz FFmpeg path: $topaz_ffmpeg"
echo -e "Homebrew FFmpeg path: $homebrew_ffmpeg\n\n"

# Initialize total video size variable
TOTAL_VIDEO_SIZE_ORIGINAL=0

# Initialize arrays to store video file paths and their sizes
VIDEO_FILES=()
VIDEO_SIZES=()

# Initialize arrays to store video file durations
VIDEO_DURATIONS=()

# Find all video files and collect their information
echo -e "${BLUE}Scanning video files...${NOCOLOR}\n"
while IFS= read -r FILE; do
    # Get the file size in bytes
    FILE_SIZE=$(wc -c < "$FILE")
    # Get video duration in seconds using ffprobe (more reliable than ffmpeg -i)
    DURATION_SEC=$(ffprobe -v quiet -show_entries format=duration -of csv="p=0" "$FILE" 2>/dev/null)
    if [[ -z "$DURATION_SEC" ]] || [[ "$DURATION_SEC" == "N/A" ]]; then
        # fallback: try with ffmpeg -i method
        DURATION=$($homebrew_ffmpeg -hide_banner -i "$FILE" 2>&1 | grep 'Duration:' | awk '{print $2}' | tr -d ,)
        if [[ -n "$DURATION" ]]; then
            # Convert HH:MM:SS.xx to seconds
            IFS=':' read -r H M S <<< "$DURATION"
            S=${S%%.*}
            DURATION_SEC=$((10#$H*3600 + 10#$M*60 + 10#$S))
        else
            DURATION_SEC=0
        fi
    else
        # Round to integer
        DURATION_SEC=$(printf "%.0f" "$DURATION_SEC")
    fi
    VIDEO_DURATIONS+=("$DURATION_SEC")
    
    # Add the file and its size to the arrays
    VIDEO_FILES+=("$FILE")
    VIDEO_SIZES+=("$FILE_SIZE")
    
    # Add the file size to the total size
    TOTAL_VIDEO_SIZE_ORIGINAL=$((TOTAL_VIDEO_SIZE_ORIGINAL + FILE_SIZE))
done < <(find "$CURRENT_DIR" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" -o -iname "*.MTS" \))


# Sort files by size (smaller to larger)
echo -e "${BLUE}Sorting files by size (smaller to larger)...${NOCOLOR}\n"


# Create an array of indices
INDICES=()
for i in "${!VIDEO_FILES[@]}"; do
    INDICES+=("$i")
done

# Sort indices based on file sizes (bubble sort for simplicity)
for ((i = 0; i < ${#INDICES[@]}; i++)); do
    for ((j = i + 1; j < ${#INDICES[@]}; j++)); do
        idx1=${INDICES[i]}
        idx2=${INDICES[j]}
        if [[ ${VIDEO_SIZES[idx1]} -gt ${VIDEO_SIZES[idx2]} ]]; then
            # Swap indices
            temp=${INDICES[i]}
            INDICES[i]=${INDICES[j]}
            INDICES[j]=$temp
        fi
    done
done

# Create sorted arrays
SORTED_VIDEO_FILES=()
SORTED_VIDEO_SIZES=()
SORTED_VIDEO_DURATIONS=()
for idx in "${INDICES[@]}"; do
    SORTED_VIDEO_FILES+=("${VIDEO_FILES[idx]}")
    SORTED_VIDEO_SIZES+=("${VIDEO_SIZES[idx]}")
    SORTED_VIDEO_DURATIONS+=("${VIDEO_DURATIONS[idx]}")
done


# Print sorted files with their sizes and durations
echo -e "${BLUE}Files sorted by size:${NOCOLOR}\n"
for i in "${!SORTED_VIDEO_FILES[@]}"; do
    FILE="${SORTED_VIDEO_FILES[i]}"
    FILE_SIZE="${SORTED_VIDEO_SIZES[i]}"
    FILE_DUR="${SORTED_VIDEO_DURATIONS[i]}"
    # Format duration as HH:MM:SS
    D_HH=$((FILE_DUR/3600))
    D_MM=$(((FILE_DUR%3600)/60))
    D_SS=$((FILE_DUR%60))
    printf "File: %s, Size: %s GB, Duration: %02d:%02d:%02d\n" \
        "$(basename "$FILE")" \
        "$(echo "scale=2; $FILE_SIZE / (1024^3)" | bc)" \
        $D_HH $D_MM $D_SS
done


# Update VIDEO_FILES and VIDEO_DURATIONS to use the sorted arrays
VIDEO_FILES=("${SORTED_VIDEO_FILES[@]}")
VIDEO_DURATIONS=("${SORTED_VIDEO_DURATIONS[@]}")


# Convert total size to gigabytes
TOTAL_VIDEO_SIZE_ORIGINAL_GB=$(echo "scale=2; $TOTAL_VIDEO_SIZE_ORIGINAL / (1024^3)" | bc)

# --- Estimate total processing time ---
TOTAL_ESTIMATED_SECONDS=0
for i in "${!VIDEO_DURATIONS[@]}"; do
    dur=${VIDEO_DURATIONS[i]}
    # Each file: stab + conversion
    est=$(echo "$dur / $STAB_SPEED_ESTIMATE + $dur / $CONVERSION_SPEED_ESTIMATE" | bc -l)
    TOTAL_ESTIMATED_SECONDS=$(echo "$TOTAL_ESTIMATED_SECONDS + $est" | bc -l)
done

# Format total estimate as HH:MM:SS
TOTAL_ESTIMATED_SECONDS=$(printf "%.0f" "$TOTAL_ESTIMATED_SECONDS")
EST_HH=$((TOTAL_ESTIMATED_SECONDS/3600))
EST_MM=$(((TOTAL_ESTIMATED_SECONDS%3600)/60))
EST_SS=$((TOTAL_ESTIMATED_SECONDS%60))

# Print the total size and ETA
echo -e "\n\n${BLUE}Total size of all video files: ${RED}$TOTAL_VIDEO_SIZE_ORIGINAL_GB GB${BLUE}.${NOCOLOR}"
printf "${YELLOW}Estimated total processing time: ${RED}%02d:%02d:%02d${NOCOLOR}\n\n" $EST_HH $EST_MM $EST_SS
echo -e "Press Enter to continue or Ctrl+Z to exit"
read


OUTPUT_VIDEO_FILES=()
TOTAL_VIDEO_SIZE_PROCESSED=0
START_TIME=$(date +%s)
NUM_FILES=${#VIDEO_FILES[@]}

# --- Progress bar function ---
draw_progress_bar() {
    local progress=$1
    local total=$2
    local width=$3
    local percent=$(( 100 * progress / total ))
    local filled=$(( width * progress / total ))
    local empty=$(( width - filled ))
    printf "["
    for ((i=0; i<filled; i++)); do printf "#"; done
    for ((i=0; i<empty; i++)); do printf "-"; done
    printf "] %3d%%" $percent
}

ELAPSED_SECONDS=0
PROCESSED_SECONDS=0

# Iterate over each video file and process it
for idx in "${!VIDEO_FILES[@]}"; do
    input_file="${VIDEO_FILES[idx]}"
    input_dur="${VIDEO_DURATIONS[idx]}"

    # Create output file names by adding the date as a prefix to the filename
    datestamp=$(date -r "$input_file" '+%Y%m%d_%H%M%S')
    output_stab_file="${CURRENT_DIR}/${datestamp}_$(basename "${input_file%.*}_stab.trf")"
    output_file="${CURRENT_DIR}/${datestamp}_$(basename "${input_file%.*}_enhanced.mp4")"

    echo -e "\n${YELLOW}Processing file: "$input_file" to "$output_file".${NOCOLOR}\n"

    # Show progress bar and ETA before processing
    draw_progress_bar $idx $NUM_FILES $PROGRESS_BAR_WIDTH
    # Estimate remaining time
    PROCESSED_SECONDS=0
    for j in $(seq 0 $((idx-1))); do
        if [[ $j -ge 0 ]]; then
            dur=${VIDEO_DURATIONS[j]}
            PROCESSED_SECONDS=$(echo "$PROCESSED_SECONDS + $dur / $STAB_SPEED_ESTIMATE + $dur / $CONVERSION_SPEED_ESTIMATE" | bc -l)
        fi
    done
    REMAINING_SECONDS=$(echo "$TOTAL_ESTIMATED_SECONDS - $PROCESSED_SECONDS" | bc -l)
    # Format remaining as HH:MM:SS
    REMAINING_SECONDS=$(printf "%.0f" "$REMAINING_SECONDS")
    R_HH=$((REMAINING_SECONDS/3600))
    R_MM=$(((REMAINING_SECONDS%3600)/60))
    R_SS=$((REMAINING_SECONDS%60))
    printf "  ETA: %02d:%02d:%02d\n" $R_HH $R_MM $R_SS

    # Stabilize the video using topaz video ai stabilization
    "$topaz_ffmpeg" "-i" "$input_file" "-flush_packets" "1" "-sws_flags" "spline+accurate_rnd+full_chroma_int" "-filter_complex" "tvai_cpe=model=cpe-2:filename=$output_stab_file:device=-2" "-f" "null" "-" && 

    # Enhance/denoise and compress the video using libx265 by piping raw video output from topaz ffmpeg to homebrew ffmpeg
    "$topaz_ffmpeg" "-nostdin" "-nostats" "-y" "-i" "$input_file" "-flush_packets" "1" "-sws_flags" "spline+accurate_rnd+full_chroma_int" "-filter_complex" "tvai_stb=model=ref-2:filename=$output_stab_file:smoothness=1.08:rst=0:wst=0:cache=128:dof=1111:ws=32:full=0:roll=1:reduce=0:device=-2:vram=1:instances=1,tvai_up=model=prob-4:scale=0:preblur=0:noise=0:details=0:halo=0:blur=0:compression=0:estimate=8:blend=0.2:device=-2:vram=1:instances=1" -c:v huffyuv -pix_fmt yuv422p -c:a copy -f nut - | "$homebrew_ffmpeg" -y -copyts -i - -c:v libx265 -preset slow -pix_fmt yuv420p -crf 28 "-metadata" "videoai=Stabilized auto-crop fixing rolling shutter and with smoothness 9. Enhanced using prob-4; mode: auto; revert compression at 0; recover details at 0; sharpen at 0; reduce noise at 0; dehalo at 0; anti-alias/deblur at 0; focus fix Off; and recover original detail at 20" "$output_file"
    
    rm -f "$output_stab_file"

    # Calculate final video size and total processed videos size
    OUTPUT_VIDEO_FILES+=("$output_file")
    FILE_SIZE=$(wc -c < "$output_file")
    echo "\n\n${BLUE}File: $(basename "$output_file"), Size: $(echo "scale=2; ${RED}$FILE_SIZE / (1024^3)" | bc) GB${BLUE}.${NOCOLOR}\n\n"
    TOTAL_VIDEO_SIZE_PROCESSED=$((TOTAL_VIDEO_SIZE_PROCESSED + FILE_SIZE))

    # Copy metadata from original file
    "$exiftool" -ee -overwrite_original -api largefilesupport=1 -tagsFromFile "$input_file" "$output_file"

    # Copy datestamps to filecreationdate, filemodifieddate and filebirthdate
    datestamp=$(date -r "$input_file" '+%Y%m%d%H%M.%S')
    "$exiftool" -ee -overwrite_original -api largefilesupport=1 "-alldates=$datestamp" "$output_file"
    touch -t $datestamp "$output_file"

    # Print finished message
    echo -e "\n${GREEN}Finished processing: ${output_file}${NOCOLOR}\n"

    # Update progress bar and ETA after each file
    draw_progress_bar $((idx+1)) $NUM_FILES $PROGRESS_BAR_WIDTH
    # Recompute processed seconds
    PROCESSED_SECONDS=0
    for j in $(seq 0 $idx); do
        dur=${VIDEO_DURATIONS[j]}
        PROCESSED_SECONDS=$(echo "$PROCESSED_SECONDS + $dur / $STAB_SPEED_ESTIMATE + $dur / $CONVERSION_SPEED_ESTIMATE" | bc -l)
    done
    REMAINING_SECONDS=$(echo "$TOTAL_ESTIMATED_SECONDS - $PROCESSED_SECONDS" | bc -l)
    REMAINING_SECONDS=$(printf "%.0f" "$REMAINING_SECONDS")
    R_HH=$((REMAINING_SECONDS/3600))
    R_MM=$(((REMAINING_SECONDS%3600)/60))
    R_SS=$((REMAINING_SECONDS%60))
    printf "  ETA: %02d:%02d:%02d\n" $R_HH $R_MM $R_SS
done

# Calculate percentage of original size
percentage=$(echo "scale=2; ($TOTAL_VIDEO_SIZE_PROCESSED / $TOTAL_VIDEO_SIZE_ORIGINAL) * 100" | bc)

# Convert total size to gigabytes
TOTAL_VIDEO_SIZE_PROCESSED_GB=$(echo "scale=2; $TOTAL_VIDEO_SIZE_PROCESSED / (1024^3)" | bc)

# Print the total size
echo -e "\n\n${BLUE}Total size of all processed video files: ${RED}$TOTAL_VIDEO_SIZE_PROCESSED_GB GB${BLUE}. Original filesize was ${RED}$TOTAL_VIDEO_SIZE_ORIGINAL_GB GB${BLUE}. That is ${RED}$percentage%${BLUE} the original size.${NOCOLOR}\n\n"

exit 0