#!/bin/bash

# Resolve script's current directory
SOURCE=${BASH_SOURCE[0]}
while [ -L "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE=$DIR/$SOURCE # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
CURRENT_DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )

cd $CURRENT_DIR

# Define the output CSV file
output_file="file_dates.csv"

# Write the header to the CSV file
echo "name,Date" > "$output_file"

# Loop through each file in the current directory
for file in *; do
  if [ -f "$file" ]; then
    # Get the modification date of the file
    datestamp=$(date -r "$file" '+%Y%m%d %H:%M:%S')
    # Write the file name and modification date to the CSV file
    echo "\"$file\",\"$datestamp\"" >> "$output_file"
  fi
done

echo "File dates have been exported to $output_file"
