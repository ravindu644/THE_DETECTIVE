#!/bin/bash

# Prompt for search directory
read -p "Enter the directory to search in (leave empty for current directory): " SEARCH_DIRECTORY
SEARCH_DIRECTORY="${SEARCH_DIRECTORY:-.}"

if [ ! -d "$SEARCH_DIRECTORY" ]; then
    echo "Error: Directory '$SEARCH_DIRECTORY' not found."
    exit 1
fi

# Prompt for keywords
read -p "Enter search keywords (comma-separated): " KEYWORDS_INPUT
IFS=',' read -r -a KEYWORDS <<< "$(echo "$KEYWORDS_INPUT" | tr -d '[:space:]')"

# Prompt for blacklist extensions
read -p "Enter extensions to blacklist (e.g., txt,log,tmp): " EXTENSIONS_INPUT
IFS=',' read -r -a EXTENSIONS <<< "$(echo "$EXTENSIONS_INPUT" | tr -d '[:space:]')"

# Build find command for keywords
find_cmd=(find "$SEARCH_DIRECTORY" -type f)
if [ "${#KEYWORDS[@]}" -gt 0 ] && [ -n "${KEYWORDS[0]}" ]; then
    find_cmd+=('(')
    for i in "${!KEYWORDS[@]}"; do
        [ $i -gt 0 ] && find_cmd+=('-o')
        find_cmd+=('-iname' "*${KEYWORDS[$i]}*")
    done
    find_cmd+=(')')
fi

# Run find and filter by blacklist extensions
results=$("${find_cmd[@]}" 2>/dev/null | while read -r file; do
    # Get last extension (after last dot)
    ext="${file##*.}"
    skip=0
    for bl_ext in "${EXTENSIONS[@]}"; do
        if [[ "${ext,,}" == "${bl_ext,,}" ]]; then
            skip=1
            break
        fi
    done
    [ $skip -eq 0 ] && realpath "$file"
done | sort | uniq)

if [ -z "$results" ]; then
    echo "No matching files were found."
    exit 0
fi

echo ""
echo "--- Search Results ---"
echo "$results"
echo "--------------------"
echo ""

read -p "Do you want to save these results to a file? (y/n): " SAVE_CHOICE
if [[ "$SAVE_CHOICE" =~ ^[yY]$ ]]; then
    read -p "Enter the filename to save the results: " FILENAME
    echo "$results" > "$FILENAME"
    echo "Results have been saved to $FILENAME."
else
    echo "Exiting without saving."
fi

exit 0
# Convert to absolute paths, then sort and remove duplicates.
final_results=$(while IFS= read -r file; do
    # Ensure the file path is not empty before processing.
    if [ -n "$file" ]; then
        realpath "$file"
    fi
done <<< "$filtered_files" | sort | uniq)

# --- Output and Saving ---

# Re-check if after processing there are any results left.
if [ -z "$final_results" ]; then
    echo "No matching files were found."
    exit 0
fi

# Print the final, sorted, and unique results to the console.
echo ""
echo "--- Search Results ---"
echo "$final_results"
echo "--------------------"
echo ""

# Ask the user if they want to save the results.
read -p "Do you want to save these results to a file? (y/n): " SAVE_CHOICE

if [[ "$SAVE_CHOICE" == "y" || "$SAVE_CHOICE" == "Y" ]]; then
    # Get the desired filename from the user.
    read -p "Enter the filename to save the results: " FILENAME

    # Save the final results to the specified file.
    echo "$final_results" > "$FILENAME"

    echo "Results have been saved to $FILENAME."
else
    echo "Exiting without saving."
fi

exit 0
