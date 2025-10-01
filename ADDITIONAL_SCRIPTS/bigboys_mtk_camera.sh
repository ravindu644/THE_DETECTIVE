#!/bin/bash

# List of suspected camera/raw names
SUSPECTED_CAMERA_NAMES=(w3c259 w3gc02 w3gc13 w3gc503 mtk000 w3gc50e w3hi5022 w3ov13b1 w3s5k w3sc13 w3sc20 w3sc520)

# Base directory to search in
SEARCH_LOCATION="/home/ravindu644/Desktop/Files/Android_Image_Tools_v3.5.2/EXTRACTED_IMAGES/extracted_vendor"

# Libraries to exclude (system libs)
EXCLUDE_LIBS="^(libc|libm|liblog|libdl|libcutils|libc\+\+)\.so$"

# Build find command dynamically for all suspected names
FILES=$(for name in "${SUSPECTED_CAMERA_NAMES[@]}"; do
    find "$SEARCH_LOCATION" -iname "*${name}*" ! -type l | sort
done)

# Process the files
objdump -p $FILES \
    | grep ".so" \
    | grep -v "libCamera_" \
    | awk '{for(i=1;i<=NF;i++) if ($i ~ /\.so$/) print $i}' \
    | xargs -n1 basename \
    | grep -v -E "$EXCLUDE_LIBS" \
    | sort -u
