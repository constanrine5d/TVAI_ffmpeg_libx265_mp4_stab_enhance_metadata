#!/usr/bin/env bash

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

# Introduction
echo -e "\n${YELLOW}This bash script will convert the videos in its current directory (and all subdirectories recursively) with Topaz Video AI stabilization and enhancement and libx265.${NOCOLOR}\n\n${GREEN}Please ALWAYS look at the settings before each run (ex. change 420 to 422).${NOCOLOR}\n\n${RED}Output files are automatically replaced without warning.${NOCOLOR}"
echo -e "\n${YELLOW}Please also change the locations of topaz_ffmpeg and homebrew_ffmpeg in the script.\n${NOCOLOR}"
echo -e "Press Enter to continue or Ctrl+Z to exit"
read

# Set FFMPEG locations
topaz_ffmpeg="/Applications/Topaz Video AI.app/Contents/MacOS/ffmpeg"
homebrew_ffmpeg="/usr/local/bin/ffmpeg"
exiftool="/usr/local/bin/exiftool"

export TVAI_MODEL_DIR="/Applications/Topaz Video AI.app/Contents/Resources/models"
export TVAI_MODEL_DATA_DIR="/Applications/Topaz Video AI.app/Contents/Resources/models"

echo -e "Topaz FFmpeg path: $topaz_ffmpeg"
echo -e "Homebrew FFmpeg path: $homebrew_ffmpeg\n\n"

# Initialize total video size variable
TOTAL_VIDEO_SIZE_ORIGINAL=0

# Initialize an array to store video file paths
VIDEO_FILES=()

# Find all video files and process each one
while IFS= read -r FILE; do
    # Add the file to the array
    VIDEO_FILES+=("$FILE")

    # Get the file size in bytes
    FILE_SIZE=$(wc -c < "$FILE")

    # Print the file size
    echo "File: $(basename "$FILE"), Size: $(echo "scale=2; $FILE_SIZE / (1024^3)" | bc) GB"

    # Add the file size to the total size
    TOTAL_VIDEO_SIZE_ORIGINAL=$((TOTAL_VIDEO_SIZE_ORIGINAL + FILE_SIZE))
done < <(find "$CURRENT_DIR" -maxdepth 1 -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" \))

# Convert total size to gigabytes
TOTAL_VIDEO_SIZE_ORIGINAL_GB=$(echo "scale=2; $TOTAL_VIDEO_SIZE_ORIGINAL / (1024^3)" | bc)

# Print the total size
echo -e "\n\n${BLUE}Total size of all video files: ${RED}$TOTAL_VIDEO_SIZE_ORIGINAL_GB GB${BLUE}.${NOCOLOR}\n\n"
echo -e "Press Enter to continue or Ctrl+Z to exit"
read

OUTPUT_VIDEO_FILES=()
TOTAL_VIDEO_SIZE_PROCESSED=0
# Iterate over each video file and process it
for input_file in "${VIDEO_FILES[@]}"; do

    # Create output file names by adding the date as a prefix to the filename

    datestamp=$(date -r "$input_file" '+%Y%m%d_%H%M%S')

    output_stab_file="${CURRENT_DIR}/${datestamp}_$(basename "${input_file%.*}_stab.trf")"
    output_file="${CURRENT_DIR}/${datestamp}_$(basename "${input_file%.*}_enhanced.mp4")"

    echo -e "\n${YELLOW}Processing file: "$input_file" to "$output_file".${NOCOLOR}\n"

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
done

# Calculate percentage of original size
percentage=$(echo "scale=2; ($TOTAL_VIDEO_SIZE_PROCESSED / $TOTAL_VIDEO_SIZE_ORIGINAL) * 100" | bc)

# Convert total size to gigabytes
TOTAL_VIDEO_SIZE_PROCESSED_GB=$(echo "scale=2; $TOTAL_VIDEO_SIZE_PROCESSED / (1024^3)" | bc)

# Print the total size
echo -e "\n\n${BLUE}Total size of all processed video files: ${RED}$TOTAL_VIDEO_SIZE_PROCESSED_GB GB${BLUE}. Original filesize was ${RED}$TOTAL_VIDEO_SIZE_ORIGINAL_GB GB${BLUE}. That is ${RED}$percentage%${BLUE} the original size.${NOCOLOR}\n\n"

exit 0