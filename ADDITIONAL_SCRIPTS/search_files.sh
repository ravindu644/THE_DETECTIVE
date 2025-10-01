#!/bin/bash

# Prompt for search directory
read -p "Enter the directory to search in (leave empty for current directory): " SEARCH_DIRECTORY
SEARCH_DIRECTORY="${SEARCH_DIRECTORY:-.}"
SEARCH_DIRECTORY=$(echo "$SEARCH_DIRECTORY" | tr -d '"' | tr -d "'")

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

# Prompt for blacklist patterns
read -p "Enter blacklist patterns (comma-separated, e.g., backup,temp): " PATTERNS_INPUT
IFS=',' read -r -a PATTERNS <<< "$(echo "$PATTERNS_INPUT" | tr -d '[:space:]')"

# --- Find symlinks matching keywords ---
symlink_cmd=(find "$SEARCH_DIRECTORY" -type l)
if [ "${#KEYWORDS[@]}" -gt 0 ] && [ -n "${KEYWORDS[0]}" ]; then
    symlink_cmd+=('(')
    for i in "${!KEYWORDS[@]}"; do
        [ $i -gt 0 ] && symlink_cmd+=('-o')
        symlink_cmd+=('-iname' "*${KEYWORDS[$i]}*")
    done
    symlink_cmd+=(')')
fi

symlink_results=$("${symlink_cmd[@]}" 2>/dev/null | while read -r symlink; do
    realpath "$symlink"
done | sort | uniq)

# --- Find regular files matching keywords, ignoring symlinks ---
find_cmd=(find "$SEARCH_DIRECTORY" -type f ! -xtype l)
if [ "${#KEYWORDS[@]}" -gt 0 ] && [ -n "${KEYWORDS[0]}" ]; then
    find_cmd+=('(')
    for i in "${!KEYWORDS[@]}"; do
        [ $i -gt 0 ] && find_cmd+=('-o')
        find_cmd+=('-iname' "*${KEYWORDS[$i]}*")
    done
    find_cmd+=(')')
fi

results=$("${find_cmd[@]}" 2>/dev/null | while read -r file; do
    # Get last extension (after last dot)
    ext="${file##*.}"
    skip=0
    # Blacklist extensions
    for bl_ext in "${EXTENSIONS[@]}"; do
        if [[ "${ext,,}" == "${bl_ext,,}" ]]; then
            skip=1
            break
        fi
    done
    # Blacklist patterns
    if [ $skip -eq 0 ] && [ "${#PATTERNS[@]}" -gt 0 ]; then
        for pat in "${PATTERNS[@]}"; do
            if [[ "$file" == *"$pat"* ]]; then
                skip=1
                break
            fi
        done
    fi
    [ $skip -eq 0 ] && realpath "$file"
done | sort | uniq)

if [ -z "$results" ]; then
    echo "No matching files were found."
else
    echo ""
    echo "--- Search Results ---"
    echo "$results"
    echo "--------------------"
    echo ""
fi

if [ -z "$symlink_results" ]; then
    echo "No matching symlinks were found."
else
    echo ""
    echo "--- Symlink Info ---"
    echo "$symlink_results"
    echo "--------------------"
    echo ""
fi

# Ask the user if they want to save the results.
read -p "Do you want to save these results to a folder? (y/n): " SAVE_CHOICE
if [[ "$SAVE_CHOICE" =~ ^[yY]$ ]]; then
    read -p "Enter the folder path to save the results: " FOLDER_PATH
    # Remove quotes if any
    FOLDER_PATH=$(echo "$FOLDER_PATH" | tr -d '"')
    mkdir -p "$FOLDER_PATH"
    # Save results
    if [ -n "$results" ]; then
        echo "$results" > "$FOLDER_PATH/search_results.txt"
        echo "Search results saved to $FOLDER_PATH/search_results.txt."
    fi
    if [ -n "$symlink_results" ]; then
        echo "$symlink_results" > "$FOLDER_PATH/symlink_info.txt"
        echo "Symlink info saved to $FOLDER_PATH/symlink_info.txt."
    fi
else
    echo "Exiting without saving."
fi

exit 0
