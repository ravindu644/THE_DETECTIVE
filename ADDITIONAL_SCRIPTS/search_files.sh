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

# Collect symlink path and its target (do NOT resolve to the target path only)
symlink_results=$("${symlink_cmd[@]}" 2>/dev/null | while IFS= read -r symlink; do
    # Apply same blacklist rules as for regular files: extension and patterns
    ext="${symlink##*.}"
    skip=0
    # Blacklist extensions
    for bl_ext in "${EXTENSIONS[@]}"; do
        if [[ "${ext,,}" == "${bl_ext,,}" ]]; then
            skip=1
            break
        fi
    done
    # Blacklist patterns (in symlink path)
    if [ $skip -eq 0 ] && [ "${#PATTERNS[@]}" -gt 0 ]; then
        for pat in "${PATTERNS[@]}"; do
            if [[ "$symlink" == *"$pat"* ]]; then
                skip=1
                break
            fi
        done
    fi
    [ $skip -eq 1 ] && continue

    # readlink returns the link target (may be relative). Keep the symlink path as-is.
    target=$(readlink "$symlink" 2>/dev/null || true)
    printf '%s -> %s\n' "$symlink" "${target:-(no target)}"
done | sort -u)

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

    # Save regular file results (unchanged behavior)
    if [ -n "$results" ]; then
        echo "$results" > "$FOLDER_PATH/search_results.txt"
        echo "Search results saved to $FOLDER_PATH/search_results.txt."
    fi

    # Save symlink info and copy symlinks into a dedicated subfolder preserving structure
    if [ -n "$symlink_results" ]; then
        echo "$symlink_results" > "$FOLDER_PATH/symlink_info.txt"
        echo "Symlink info saved to $FOLDER_PATH/symlink_info.txt."

        # Create symlink target folder
        symlink_dest="$FOLDER_PATH/symlinks"
        while IFS= read -r line; do
            # Extract original symlink path (before " -> ")
            symlink_path="${line%% -> *}"
            # Compute relative path to preserve directory structure
            rel="${symlink_path#$SEARCH_DIRECTORY/}"
            dest_path="$symlink_dest/$rel"
            mkdir -p "$(dirname "$dest_path")" && cp -a -- "$symlink_path" "$dest_path" || echo "Failed to copy symlink: $symlink_path"
        done <<< "$symlink_results"

        echo "Symlinks copied into $symlink_dest (preserving structure)."
    fi
else
    echo "Exiting without saving."
fi

exit 0
