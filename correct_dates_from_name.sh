#!/usr/bin/env bash

# Resolve script's current directory
SOURCE=${BASH_SOURCE[0]}
while [ -L "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE=$DIR/$SOURCE # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
CURRENT_DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )

cd $CURRENT_DIR


# Loop through each .mp4 file in the directory
for file in "."/*.mp4; do

    base=$(basename "$file")
    datetime="${base:0:15}"
    formatted_datetime="${datetime:0:8}${datetime:9:4}.${datetime:13:2}"

    

    "$exiftool" -ee -overwrite_original -api largefilesupport=1 "-alldates=filename" "$file"
    touch -t $formatted_datetime "$file"
    echo -e "\n${GREEN}Finished processing: ${file}${NOCOLOR}\n"

done

exit 0