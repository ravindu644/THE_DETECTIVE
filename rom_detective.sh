#!/bin/bash

# ==============================================================================
# The Detective - A Forensic Android ROM Comparison Tool
# Version: 2.3 (REPLACEMENT DETECTION)
# Author: ravindu644
#
# This script performs a deep, forensic comparison between two or three
# unpacked Android ROM directories to identify all modifications.
#
# CHANGE LOG (v2.3):
# - Added new category: "Replaced with Stock" for files nuked from base and replaced with target stock's version.
# - More reliable hash-based file comparison logic.
# - Better progress reporting and error handling.
# ==============================================================================

# --- Configuration and Style ---
CONFIG_FILE="detective.conf"
BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# --- Functions ---

# Banner function
print_banner() {
    echo -e "${BOLD}${GREEN}"
    echo "┌───────────────────────────────────────────┐"
    echo "│     The Detective - ROM Analysis Tool     │"
    echo "│        v2.3 - REPLACEMENT DETECTION       │"
    echo "└───────────────────────────────────────────┘"
    echo -e "${RESET}"
}

# Function to check for root privileges
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Error: This script requires root privileges to read all file permissions and install dependencies."
        echo "Please run again with 'sudo'."
        exit 1
    fi
}

# Function to check for and install required packages
check_and_install_deps() {
    echo -e "--- Phase 0: Verifying Dependencies ---\n"
    
    declare -A deps=(
        ["diffutils"]="diff"
        ["binutils"]="readelf strings"
        ["default-jre-headless"]="java"
        ["wget"]="wget"
        ["findutils"]="find"
        ["sed"]="sed"
        ["coreutils"]="sha256sum"
        ["util-linux"]="hexdump"
        ["file"]="file"
        ["gawk"]="awk"
        ["unzip"]="unzip"
    )
    
    packages_to_install=()
    all_deps_met=true

    for pkg in "${!deps[@]}"; do
        for cmd in ${deps[$pkg]}; do
            if ! command -v "$cmd" &> /dev/null; then
                echo "Dependency missing: '$cmd' (from package '$pkg')"
                packages_to_install+=("$pkg")
                all_deps_met=false
                break
            fi
        done
    done

    if [ "$all_deps_met" = false ]; then
        echo "Attempting to install missing system packages..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y "${packages_to_install[@]}"
        echo "System dependencies installed."
    else
        echo "All system dependencies are met."
    fi
}

# Function to check for and install Apktool
check_and_install_apktool() {
    if ! command -v "apktool" &> /dev/null; then
        echo "Apktool not found. Attempting to install it system-wide..."
        
        local wrapper_url="https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/linux/apktool"
        local jar_url="https://bitbucket.org/iBotPeaches/apktool/downloads/apktool_2.9.3.jar"

        echo " -> Downloading Apktool wrapper script..."
        wget -q -O "/tmp/apktool" "$wrapper_url"
        
        echo " -> Downloading Apktool JAR file (this may take a moment)..."
        wget -q -O "/tmp/apktool.jar" "$jar_url"

        if [[ ! -f "/tmp/apktool" || ! -f "/tmp/apktool.jar" ]]; then
            echo "Error: Failed to download Apktool. Please check your internet connection and try again."
            exit 1
        fi
        
        echo " -> Installing..."
        mv "/tmp/apktool" "/usr/local/bin/apktool"
        mv "/tmp/apktool.jar" "/usr/local/bin/apktool.jar"
        chmod +x "/usr/local/bin/apktool"
        chmod +x "/usr/local/bin/apktool.jar"
        
        echo "Apktool has been installed successfully."
    else
        echo "Apktool is already installed."
    fi
    echo
}

# Function to create a default config file if it doesn't exist
check_and_create_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Configuration file '$CONFIG_FILE' not found. Creating a default one."
        
        cat << 'EOF' > "$CONFIG_FILE"
# --- Detective Tool Configuration ---
# This file controls the behavior of the ROM analysis script.

# --- General Settings ---

# Set to "true" to automatically delete temporary folders (like decompiled APKs).
# Set to "false" to keep them for manual inspection.
CLEANUP_TEMP_FILES="true"

# Command for decompiling APKs/JARs.
APKTOOL_COMMAND="apktool"

# List of directories and files to completely ignore during the comparison.
# Use spaces to separate multiple entries. (e.g., IGNORE_LIST=".git .DS_Store")
IGNORE_LIST=".repack_info"

# --- Binary File Analysis ---

# Space-separated list of file extensions to IGNORE during binary analysis.
# These files will be listed as "changed" but no patch will be generated.
SKIP_BINARY_ANALYSIS_EXTENSIONS="png jpg mp3 ogg zip dat"

# The analysis methods to run on all other binary files.
# - hexdump: Full hexadecimal diff. Very thorough.
# - strings: Diffs human-readable text. Great for finding config changes.
# - readelf: Diffs library dependencies. Finds structural linking changes.
BINARY_ANALYSIS_METHODS="hexdump strings readelf"

# --- File Type Overrides ---
# A space-separated list of extensions to ALWAYS treat as text files,
# overriding the automatic detection. Useful for files like .rc or .bp
# that might be misidentified as binary.
FORCE_TEXT_EXTENSIONS="rc prop xml sh bp"

# --- Archive Analysis ---
# Enable/disable deep analysis of archive contents (.zip, .apex, etc.)
ANALYZE_ARCHIVES="true"
# Space-separated list of extensions to treat as archives.
# NOTE: .apk and .jar are handled separately by the APKTOOL_COMMAND.
ARCHIVE_EXTENSIONS="apex zip"

# --- Signature Filtering ---
# Enable filtering of files with only signature/metadata changes
FILTER_SIGNATURE_ONLY_CHANGES="true"
# Patterns to ignore (one per line, supports basic regex)
# Useful to ignore files with no changes, but only the watermak of a developer
IGNORE_SIGNATURE_PATTERNS="lj4nt8
build_id_[0-9]+
__build__
_CI_BUILD_
_metadata_"
EOF
        echo "Configuration has been created."
        read -p "Please review/edit '$CONFIG_FILE' to your liking now, then press [Enter] to begin the analysis."
    fi
}

# Function to check if a file has only signature changes
check_signature_only_changes() {
    local file_path="$1"
    local base_file="$BASE_ROM_PATH/$file_path"
    local ported_file="$PORTED_ROM_PATH/$file_path"
    
    # Only process if signature filtering is enabled
    if [[ "$FILTER_SIGNATURE_ONLY_CHANGES" != "true" ]]; then
        return 1  # Not signature-only, continue normal processing
    fi
    
    # Skip if either file doesn't exist
    if [[ ! -f "$base_file" || ! -f "$ported_file" ]]; then
        return 1
    fi
    
    # Get file sizes
    local base_size=$(wc -c < "$base_file" 2>/dev/null || echo 0)
    local ported_size=$(wc -c < "$ported_file" 2>/dev/null || echo 0)
    
    # If ported is smaller than base, definitely not signature-only addition
    if [[ $ported_size -le $base_size ]]; then
        return 1
    fi
    
    # Calculate size difference
    local size_diff=$((ported_size - base_size))
    
    # If difference is too large, unlikely to be just signature
    if [[ $size_diff -gt 100 ]]; then
        return 1
    fi
    
    # Extract the potential signature (last N bytes of ported file)
    local signature_candidate
    signature_candidate=$(tail -c "$size_diff" "$ported_file" 2>/dev/null | tr -d '\0\n\r' | strings -a | head -1)
    
    # Check if this signature matches any ignore patterns
    if [[ -n "$signature_candidate" ]]; then
        while IFS= read -r pattern; do
            # Skip empty lines and comments
            [[ -z "$pattern" || "$pattern" =~ ^[[:space:]]*# ]] && continue
            
            # Check if signature matches pattern (basic regex support)
            if echo "$signature_candidate" | grep -qE "$pattern"; then
                # Verify the base file + signature = ported file
                if head -c "$base_size" "$ported_file" | cmp -s - "$base_file"; then
                    return 0  # This is signature-only
                fi
            fi
        done <<< "$IGNORE_SIGNATURE_PATTERNS"
    fi
    
    return 1  # Not signature-only
}

# New function to compare files using pure awk
compare_hash_files() {
    local base_hashes="$1"
    local ported_hashes="$2"
    local deleted_output="$3"
    local new_output="$4"
    local changed_output="$5"
    local unchanged_output="$6"
    
    echo "Analyzing file differences using AWK-based comparison..." >&2
    
    # Use a single AWK script to process both files and generate all outputs
    awk '
    BEGIN {
        print "Processing hash files..." > "/dev/stderr"
    }
    
    # Process base ROM hashes (first file)
    FNR==NR {
        # Store base file info: base_files[filepath] = hash
        base_files[$2] = $1
        base_count++
        next
    }
    
    # Process ported ROM hashes (second file)  
    {
        filepath = $2
        ported_hash = $1
        
        if (filepath in base_files) {
            # File exists in both - check if changed
            if (base_files[filepath] != ported_hash) {
                print filepath > changed_file
            } else {
                print filepath > unchanged_file
            }
            # Mark as processed
            delete base_files[filepath]
        } else {
            # File is new in ported ROM
            print filepath > new_file
        }
        ported_count++
    }
    
    END {
        # Remaining files in base_files array are deleted files
        for (filepath in base_files) {
            print filepath > deleted_file
        }
        
        printf "Processed %d base files and %d ported files\n", base_count, ported_count > "/dev/stderr"
    }
    ' changed_file="$changed_output" deleted_file="$deleted_output" new_file="$new_output" unchanged_file="$unchanged_output" \
      "$base_hashes" "$ported_hashes"
    
    # Post-process changed files for signature filtering
    if [[ "$FILTER_SIGNATURE_ONLY_CHANGES" == "true" && -f "$changed_output" ]]; then
        echo -e "\nFiltering signature-only changes..." >&2
        
        local temp_changed="$TEMP_DIR/filtered_changed.tmp"
        local temp_signature_only="$TEMP_DIR/signature_only.tmp"
        
        > "$temp_changed"
        > "$temp_signature_only"
        
        local total_changed=$(wc -l < "$changed_output")
        local current=0
        
        while IFS= read -r filepath; do
            ((current++))
            printf "\r -> Filtering file %d of %d: %-50s" "$current" "$total_changed" "$(basename "$filepath")" >&2
            
            if check_signature_only_changes "$filepath"; then
                echo "$filepath" >> "$temp_signature_only"
            else
                echo "$filepath" >> "$temp_changed"
            fi
        done < "$changed_output" 
        printf "\r\033[K" >&2 # Clear the progress line before printing the summary
        
        # Replace the changed file list with filtered results
        mv "$temp_changed" "$changed_output"
        local signature_count=$(wc -l < "$temp_signature_only" 2>/dev/null || echo 0)
        local real_changed_count=$(wc -l < "$changed_output" 2>/dev/null || echo 0)

        # Append signature-only files to the main unchanged list
        if [[ $signature_count -gt 0 ]]; then
            cat "$temp_signature_only" >> "$unchanged_output"
        fi

        echo -e "\n${BOLD}Filtered out $signature_count signature-only changes, $real_changed_count real changes remain${RESET}" >&2
        echo "$signature_count" # Output the count for the main script
    fi
}

# New function to analyze modification patterns and generate an intelligence report
analyze_modification_patterns() {
    local changed_files="$1"
    local patches_dir="$2"
    local output_file="$3"
    
    echo "Analyzing modification patterns..."
    
    local temp_analysis="$TEMP_DIR/pattern_analysis.tmp"
    local temp_dirs="$TEMP_DIR/directory_analysis.tmp"
    local temp_types="$TEMP_DIR/filetype_analysis.tmp"
    
    if [[ -f "$changed_files" && -s "$changed_files" ]]; then
        while IFS= read -r filepath; do
            extension="${filepath##*.}"
            if [[ "$extension" == "$filepath" ]]; then
                extension="(no_extension)"
            fi
            echo "$extension" >> "$temp_types"
            
            directory=$(dirname "$filepath")
            echo "$directory" >> "$temp_dirs"
            
            patch_file="$patches_dir/$filepath.patch"
            hexdump_patch="$patches_dir/$filepath.hexdump.patch"
            strings_patch="$patches_dir/$filepath.strings.patch"
            
            patch_size=0
            if [[ -f "$patch_file" ]]; then
                patch_size=$(wc -l < "$patch_file" 2>/dev/null || echo 0)
            elif [[ -f "$hexdump_patch" ]]; then
                patch_size=$(wc -l < "$hexdump_patch" 2>/dev/null || echo 0)
            elif [[ -f "$strings_patch" ]]; then
                patch_size=$(wc -l < "$strings_patch" 2>/dev/null || echo 0)
            fi
            
            echo "$filepath:$patch_size" >> "$temp_analysis"
            
        done < "$changed_files"
    fi
    
    {
        echo "================================================================"
        echo " PORTING INTELLIGENCE REPORT - Modification Patterns Analysis"
        echo "================================================================"
        echo "Generated on: $(date)"
        echo
        
        total_changed=$(wc -l < "$changed_files" 2>/dev/null || echo 0)
        total_new=$(wc -l < "$RAW_LISTS_DIR/03_NEW_FILES.txt" 2>/dev/null || echo 0)
        total_deleted=$(wc -l < "$RAW_LISTS_DIR/01_DELETED_FILES.txt" 2>/dev/null || echo 0)
        total_unchanged=$(wc -l < "$RAW_LISTS_DIR/05_UNCHANGED_FILES.txt" 2>/dev/null || echo 0)
        total_files=$((total_changed + total_unchanged))
        
        if [[ $total_files -gt 0 ]]; then
            change_percentage=$(( (total_changed * 100) / total_files ))
        else
            change_percentage=0
        fi
        
        echo "=== OVERALL MODIFICATION STATISTICS ==="
        echo "Total files analyzed: $total_files"
        echo "Files with real changes: $total_changed ($change_percentage%)"
        echo "Files added: $total_new"
        echo "Files deleted: $total_deleted"
        echo "Files unchanged: $total_unchanged (includes functionally identical watermarked files)"
        echo
        
        echo "=== FILE TYPE DISTRIBUTION (Real Changes Only) ==="
        if [[ -f "$temp_types" ]]; then
            sort "$temp_types" | uniq -c | sort -nr | head -10 | while read count ext; do
                printf "%-15s: %d files\n" "$ext" "$count"
            done
        else
            echo "No file type data available"
        fi
        echo
        
        echo "=== DIRECTORY HOTSPOTS (Most Modified) ==="
        if [[ -f "$temp_dirs" ]]; then
            sort "$temp_dirs" | uniq -c | sort -nr | head -15 | while read count dir; do
                printf "%-40s: %d changes\n" "$dir" "$count"
            done
        else
            echo "No directory data available"
        fi
        echo
        
        echo "=== CHANGE INTENSITY ANALYSIS ==="
        if [[ -f "$temp_analysis" ]]; then
            small_changes=0
            medium_changes=0
            large_changes=0
            
            while IFS=':' read -r filepath patch_size; do
                if [[ $patch_size -eq 0 ]]; then
                    continue
                elif [[ $patch_size -le 20 ]]; then
                    ((small_changes++))
                elif [[ $patch_size -le 100 ]]; then
                    ((medium_changes++))
                else
                    ((large_changes++))
                fi
            done < "$temp_analysis"
            
            echo "Small changes (1-20 lines): $small_changes files"
            echo "Medium changes (21-100 lines): $medium_changes files"  
            echo "Large changes (100+ lines): $large_changes files"
            echo
            
            echo "=== MOST HEAVILY MODIFIED FILES ==="
            sort -t':' -k2 -nr "$temp_analysis" | head -10 | while IFS=':' read -r filepath patch_size; do
                if [[ $patch_size -gt 0 ]]; then
                    printf "%-50s: %d lines changed\n" "$(basename "$filepath")" "$patch_size"
                fi
            done
        else
            echo "No change intensity data available"
        fi
        echo
        
    } > "$output_file"
    
    rm -f "$temp_analysis" "$temp_dirs" "$temp_types"
}

# File classification and analysis function
analyze_file() {
    local relative_path="$1"
    local stock_file="$BASE_ROM_PATH/$relative_path"
    local ported_file="$PORTED_ROM_PATH/$relative_path"
    local patch_output_dir
    patch_output_dir=$(dirname "$PATCHES_DIR/$relative_path")
    mkdir -p "$patch_output_dir"

    local extension="${relative_path##*.}"

    # 1. APK/JAR Handler
    if [[ "$extension" == "apk" || "$extension" == "jar" ]]; then
        local stock_src="$TEMP_DIR/stock_src"
        local ported_src="$TEMP_DIR/ported_src"
        rm -rf "$stock_src" "$ported_src"

        $APKTOOL_COMMAND d -f "$stock_file" -o "$stock_src" &> /dev/null
        $APKTOOL_COMMAND d -f "$ported_file" -o "$ported_src" &> /dev/null

        find "$stock_src" "$ported_src" -name "*.smali" -type f -exec sed -i '/^\s*\.line\s\+[0-9]\+/d' {} + 2>/dev/null
        
        diff -urN "$stock_src" "$ported_src" > "$patch_output_dir/$(basename "$relative_path").patch" 2>/dev/null
        return
    fi

    # 2. Archive Handler (e.g., .zip, .apex)
    if [[ "$ANALYZE_ARCHIVES" == "true" ]]; then
        for archive_ext in $ARCHIVE_EXTENSIONS; do
            if [[ "$extension" == "$archive_ext" ]]; then
                local stock_src="$TEMP_DIR/stock_archive_src"
                local ported_src="$TEMP_DIR/ported_archive_src"
                rm -rf "$stock_src" "$ported_src"

                # Unzip both archives quietly
                unzip -q -o "$stock_file" -d "$stock_src" &> /dev/null
                unzip -q -o "$ported_file" -d "$ported_src" &> /dev/null

                # Diff the extracted contents
                diff -urN "$stock_src" "$ported_src" > "$patch_output_dir/$(basename "$relative_path").contents.patch" 2>/dev/null
                return
            fi
        done
    fi    
    
    # 3. Skippable Binary Check
    for skip_ext in $SKIP_BINARY_ANALYSIS_EXTENSIONS; do
        if [[ "$extension" == "$skip_ext" ]]; then
            return
        fi
    done

    # 4. Force Text Check (Whitelist)
    # This overrides automatic detection for specific file types.
    for force_text_ext in $FORCE_TEXT_EXTENSIONS; do
        if [[ "$extension" == "$force_text_ext" ]]; then
            diff -u "$stock_file" "$ported_file" > "$patch_output_dir/$(basename "$relative_path").patch" 2>/dev/null
            return
        fi
    done
    
    # 5. Use 'file' command for robust file type detection
    local mime_type
    mime_type=$(file -b --mime-type "$ported_file" 2>/dev/null || echo "unknown")

    if [[ "$mime_type" == text/* ]]; then
        # It's a text file
        diff -u "$stock_file" "$ported_file" > "$patch_output_dir/$(basename "$relative_path").patch" 2>/dev/null
    else
        # It's a binary file
        for method in $BINARY_ANALYSIS_METHODS; do
            case "$method" in
                hexdump)
                    hexdump -C "$stock_file" > "$TEMP_DIR/stock.hex" 2>/dev/null
                    hexdump -C "$ported_file" > "$TEMP_DIR/ported.hex" 2>/dev/null
                    diff -u --label "$stock_file" --label "$ported_file" "$TEMP_DIR/stock.hex" "$TEMP_DIR/ported.hex" > "$patch_output_dir/$(basename "$relative_path").hexdump.patch" 2>/dev/null


                    ;;
                strings)
                    strings "$stock_file" > "$TEMP_DIR/stock.strings" 2>/dev/null
                    strings "$ported_file" > "$TEMP_DIR/ported.strings" 2>/dev/null
                    diff -u --label "$stock_file" --label "$ported_file" "$TEMP_DIR/stock.strings" "$TEMP_DIR/ported.strings" > "$patch_output_dir/$(basename "$relative_path").strings.patch" 2>/dev/null
                    diff -u --label "$stock_file" --label "$ported_file" "$TEMP_DIR/stock.elf" "$TEMP_DIR/ported.elf" > "$patch_output_dir/$(basename "$relative_path").dependencies.patch" 2>/dev/null


                    ;;
                readelf)
                    if [[ "$mime_type" == "application/x-elf" || "$mime_type" == "application/x-sharedlib" || "$mime_type" == "application/x-executable" ]]; then
                        readelf -d "$stock_file" > "$TEMP_DIR/stock.elf" 2>/dev/null
                        readelf -d "$ported_file" > "$TEMP_DIR/ported.elf" 2>/dev/null


                    fi
                    ;;
            esac
        done
    fi
}

# --- Main Script Execution ---

print_banner
check_root
check_and_install_deps
check_and_install_apktool
check_and_create_config

source "./$CONFIG_FILE"

# --- Phase 1: Initialization ---
echo -e "--- Phase 1: Initialization ---\n"
# Get user input for directories
read -e -p "[1/3] Enter the path to the Ported/Modified ROM directory: " PORTED_ROM_PATH
PORTED_ROM_PATH="${PORTED_ROM_PATH%\'}"; PORTED_ROM_PATH="${PORTED_ROM_PATH#\'}"
PORTED_ROM_PATH="${PORTED_ROM_PATH%\"}"; PORTED_ROM_PATH="${PORTED_ROM_PATH#\"}"
if [[ ! -d "$PORTED_ROM_PATH" ]]; then echo "Error: Path not found for Ported ROM -> '$PORTED_ROM_PATH'"; exit 1; fi

read -e -p "[2/3] Enter the path to the original Base ROM directory: " BASE_ROM_PATH
BASE_ROM_PATH="${BASE_ROM_PATH%\'}"; BASE_ROM_PATH="${BASE_ROM_PATH#\'}"
BASE_ROM_PATH="${BASE_ROM_PATH%\"}"; BASE_ROM_PATH="${BASE_ROM_PATH#\"}"
if [[ ! -d "$BASE_ROM_PATH" ]]; then echo "Error: Path not found for Base ROM -> '$BASE_ROM_PATH'"; exit 1; fi

read -e -p "[3/3] OPTIONAL: Enter path to the Target Device's Stock ROM [Press Enter to skip]: " TARGET_STOCK_PATH
if [[ -n "$TARGET_STOCK_PATH" ]]; then
    TARGET_STOCK_PATH="${TARGET_STOCK_PATH%\'}"; TARGET_STOCK_PATH="${TARGET_STOCK_PATH#\'}"
    TARGET_STOCK_PATH="${TARGET_STOCK_PATH%\"}"; TARGET_STOCK_PATH="${TARGET_STOCK_PATH#\"}"
fi

# Determine mode and validate third path if provided
ANALYSIS_MODE="DUAL"
if [[ -n "$TARGET_STOCK_PATH" ]]; then
    if [[ ! -d "$TARGET_STOCK_PATH" ]]; then
        echo "Error: Target Stock ROM path not found -> '$TARGET_STOCK_PATH'"
        exit 1
    fi
    ANALYSIS_MODE="TRIPLE"
    echo -e "\nMode: Triple-Compare"
else
    echo -e "\nMode: Dual-Compare"
fi

# Setup output environment
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
SCRIPT_DIR=$(pwd)
OUTPUT_DIR="$SCRIPT_DIR/final_detective_folder_$TIMESTAMP"
PATCHES_DIR="$OUTPUT_DIR/patches"
RAW_LISTS_DIR="$OUTPUT_DIR/raw_file_lists"
TEMP_DIR="$OUTPUT_DIR/temp"

mkdir -p "$OUTPUT_DIR" "$PATCHES_DIR" "$RAW_LISTS_DIR" "$TEMP_DIR"
echo "Results will be saved in: $OUTPUT_DIR"

# --- Timer Start ---
start_time=$SECONDS

# --- Phase 2: Hash Generation and Comparison ---
echo
echo -e "--- Phase 2: Generating File Hashes (This may take a while...) ---\n"

# Create ignore options for the find command
ignore_opts=()
for item in $IGNORE_LIST; do
    ignore_opts+=(-not -path "*/$item/*")
done

# Hash generation function
hash_directory() {
    local dir_path="$1"
    local output_file="$2"
    local dir_name="$3"
    echo "Hashing $dir_name directory..."
    (cd "$dir_path" && find . -type f "${ignore_opts[@]}" -exec sha256sum {} + > "$output_file")
}

# Hash all provided directories
hash_directory "$PORTED_ROM_PATH" "$TEMP_DIR/ported.hashes" "Ported ROM"
hash_directory "$BASE_ROM_PATH" "$TEMP_DIR/base.hashes" "Base ROM"
if [[ "$ANALYSIS_MODE" == "TRIPLE" ]]; then
    hash_directory "$TARGET_STOCK_PATH" "$TEMP_DIR/target.hashes" "Target Stock ROM"
fi

echo -e "Hash generation complete. Comparing files...\n"

# Capture the count of filtered files from the function's output
SIGNATURE_COUNT=$(compare_hash_files \
    "$TEMP_DIR/base.hashes" \
    "$TEMP_DIR/ported.hashes" \
    "$RAW_LISTS_DIR/01_DELETED_FILES.txt" \
    "$RAW_LISTS_DIR/03_NEW_FILES.txt" \
    "$RAW_LISTS_DIR/02_CHANGED_FILES.txt" \
    "$RAW_LISTS_DIR/05_UNCHANGED_FILES.txt"
)

# Handle triple-compare mode for transplanted files
if [[ "$ANALYSIS_MODE" == "TRIPLE" ]]; then
    echo -e "\nPerforming Triple-Compare post-analysis for replacements..."

    
    # 1. Find all files that are identical between ported and target (transplanted master list)
    awk '
    FNR==NR {
        # Store ported ROM hashes
        ported_files[$2] = $1
        next
    }
    {
        filepath = $2
        target_hash = $1
        
        if (filepath in ported_files && ported_files[filepath] == target_hash) {
            print filepath
        }
    }

    ' "$TEMP_DIR/ported.hashes" "$TEMP_DIR/target.hashes" > "$TEMP_DIR/transplanted_master.list"

    # 2. Identify files that were REPLACED (exist in CHANGED and TRANSPLANTED lists)
    grep -xF -f "$RAW_LISTS_DIR/02_CHANGED_FILES.txt" "$TEMP_DIR/transplanted_master.list" > "$RAW_LISTS_DIR/07_REPLACED_WITH_STOCK.txt"

    # 3. Identify files that were truly ADDED from stock (exist in NEW and TRANSPLANTED lists)
    grep -xF -f "$RAW_LISTS_DIR/03_NEW_FILES.txt" "$TEMP_DIR/transplanted_master.list" > "$RAW_LISTS_DIR/04_ADDED_FROM_STOCK.txt"

    # 4. Clean up the original CHANGED list by removing the files we just categorized as REPLACED
    if [[ -f "$RAW_LISTS_DIR/07_REPLACED_WITH_STOCK.txt" && -s "$RAW_LISTS_DIR/07_REPLACED_WITH_STOCK.txt" ]]; then
        grep -vxF -f "$RAW_LISTS_DIR/07_REPLACED_WITH_STOCK.txt" "$RAW_LISTS_DIR/02_CHANGED_FILES.txt" > "$TEMP_DIR/changed.tmp" && \
        mv "$TEMP_DIR/changed.tmp" "$RAW_LISTS_DIR/02_CHANGED_FILES.txt"
    fi

    # 5. Clean up the original NEW list by removing the files we just categorized as ADDED from stock
    if [[ -f "$RAW_LISTS_DIR/04_ADDED_FROM_STOCK.txt" && -s "$RAW_LISTS_DIR/04_ADDED_FROM_STOCK.txt" ]]; then
        grep -vxF -f "$RAW_LISTS_DIR/04_ADDED_FROM_STOCK.txt" "$RAW_LISTS_DIR/03_NEW_FILES.txt" > "$TEMP_DIR/new.tmp" && \
        mv "$TEMP_DIR/new.tmp" "$RAW_LISTS_DIR/03_NEW_FILES.txt"
    fi
fi

echo "File comparison complete."

# Print summary of findings
echo
echo -e "${YELLOW}--- Comparison Summary ---${RESET}"
echo "Changed files: $(wc -l < "$RAW_LISTS_DIR/02_CHANGED_FILES.txt" 2>/dev/null || echo 0)"
if [[ "$FILTER_SIGNATURE_ONLY_CHANGES" == "true" && -n "$SIGNATURE_COUNT" && "$SIGNATURE_COUNT" -gt 0 ]]; then
    echo -e "${BOLD}Ignored Watermarked files:${RESET} $SIGNATURE_COUNT (moved to unchanged list)"
fi
if [[ "$ANALYSIS_MODE" == "TRIPLE" ]]; then
    echo "Replaced with stock files: $(wc -l < "$RAW_LISTS_DIR/07_REPLACED_WITH_STOCK.txt" 2>/dev/null || echo 0)"
    echo "Added from stock files: $(wc -l < "$RAW_LISTS_DIR/04_ADDED_FROM_STOCK.txt" 2>/dev/null || echo 0)"
fi
echo "New files: $(wc -l < "$RAW_LISTS_DIR/03_NEW_FILES.txt" 2>/dev/null || echo 0)"
echo "Deleted files: $(wc -l < "$RAW_LISTS_DIR/01_DELETED_FILES.txt" 2>/dev/null || echo 0)"
echo "Unchanged files: $(wc -l < "$RAW_LISTS_DIR/05_UNCHANGED_FILES.txt" 2>/dev/null || echo 0)"

# --- Phase 3: Deep Analysis ---
echo
echo "--- Phase 3: Performing Deep Analysis on Changed Files ---"

# Progress bar with proper error handling
if [[ -f "$RAW_LISTS_DIR/02_CHANGED_FILES.txt" && -s "$RAW_LISTS_DIR/02_CHANGED_FILES.txt" ]]; then
    total_files=$(wc -l < "$RAW_LISTS_DIR/02_CHANGED_FILES.txt")
    current_file=0

    while IFS= read -r file; do
        ((current_file++))
        clean_file_path="${file#./}"
        printf "\r -> Processing file %d of %d: %-60s" "$current_file" "$total_files" "$(basename "$clean_file_path")"
        analyze_file "$clean_file_path" 2>/dev/null
    done < "$RAW_LISTS_DIR/02_CHANGED_FILES.txt"
    echo
else
    echo "No changed files found to analyze."
fi

echo "Generating modification patterns analysis..."
analyze_modification_patterns "$RAW_LISTS_DIR/02_CHANGED_FILES.txt" "$PATCHES_DIR" "$OUTPUT_DIR/Porting_Intelligence_Report.txt"

# --- Phase 4: Final Report & Cleanup ---
echo
echo "--- Phase 4: Generating Final Report ---"

# Detect the original user (the one who called sudo)
ORIGINAL_USER="${SUDO_USER:-$(logname 2>/dev/null)}"
if [[ -n "$ORIGINAL_USER" && "$ORIGINAL_USER" != "root" ]]; then
    ORIGINAL_UID=$(id -u "$ORIGINAL_USER" 2>/dev/null)
    ORIGINAL_GID=$(id -g "$ORIGINAL_USER" 2>/dev/null)
    echo "Detected original user: $ORIGINAL_USER (UID: $ORIGINAL_UID, GID: $ORIGINAL_GID)"
else
    ORIGINAL_USER=""
    echo "Warning: Could not detect original user. Output will remain owned by root."
fi

SUMMARY_FILE="$OUTPUT_DIR/Analysis_Summary.txt"

{
    echo "======================================================="
    echo " Forensic Analysis Report - Generated by The Detective"
    echo "======================================================="
    echo "Generated on: $(date)"
    echo
    echo "Ported ROM: $PORTED_ROM_PATH"
    echo "Base ROM:   $BASE_ROM_PATH"
    [[ "$ANALYSIS_MODE" == "TRIPLE" ]] && echo "Stock ROM: $TARGET_STOCK_PATH"
    echo "-------------------------------------------------------"
    echo

    if [[ "$ANALYSIS_MODE" == "TRIPLE" ]]; then
        echo "--- [REPLACED] Base ROM Files with Target Stock Versions ---"
        if [[ -f "$RAW_LISTS_DIR/07_REPLACED_WITH_STOCK.txt" ]]; then
            cat "$RAW_LISTS_DIR/07_REPLACED_WITH_STOCK.txt"
        fi
        echo
    fi

        echo "--- [ADDED] New Files from Target Stock ROM ---"
        if [[ -f "$RAW_LISTS_DIR/04_ADDED_FROM_STOCK.txt" ]]; then
            cat "$RAW_LISTS_DIR/04_ADDED_FROM_STOCK.txt"
        fi
        echo    

    echo "--- [UNCHANGED] Files (Identical in both ROMs, including watermarked) ---"
    if [[ -f "$RAW_LISTS_DIR/05_UNCHANGED_FILES.txt" ]]; then
        cat "$RAW_LISTS_DIR/05_UNCHANGED_FILES.txt"
    fi
    echo

    echo "--- [CHANGED] Files (Content differs from Base ROM) ---"
    if [[ -f "$RAW_LISTS_DIR/02_CHANGED_FILES.txt" ]]; then
        cat "$RAW_LISTS_DIR/02_CHANGED_FILES.txt"
    fi
    echo

    echo "--- [NEW] Files (Present in Ported, missing in Base) ---"
    if [[ -f "$RAW_LISTS_DIR/03_NEW_FILES.txt" ]]; then
        cat "$RAW_LISTS_DIR/03_NEW_FILES.txt"
    fi
    echo

    echo "--- [DELETED] Files (Present in Base, missing in Ported) ---"
    if [[ -f "$RAW_LISTS_DIR/01_DELETED_FILES.txt" ]]; then
        cat "$RAW_LISTS_DIR/01_DELETED_FILES.txt"
    fi
    echo
    
} > "$SUMMARY_FILE"

if [[ "$CLEANUP_TEMP_FILES" == "true" ]]; then
    echo "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
fi

# Change ownership of output directory to original user
if [[ -n "$ORIGINAL_USER" && -n "$ORIGINAL_UID" && -n "$ORIGINAL_GID" ]]; then
    echo "Changing ownership of output directory to $ORIGINAL_USER..."
    chown -R "$ORIGINAL_UID:$ORIGINAL_GID" "$OUTPUT_DIR"
    echo "Output directory ownership transferred successfully."
fi

# --- Timer End and Calculation ---
end_time=$SECONDS
duration=$((end_time - start_time))
minutes=$((duration / 60))
seconds=$((duration % 60))

echo
echo -e "${BOLD}${GREEN}"
echo "=========================================="
echo "         ANALYSIS COMPLETE"
echo "=========================================="
echo -e "${RESET}"
echo -e "All results have been saved to: ${BOLD}$OUTPUT_DIR${RESET}"
if [[ -n "$ORIGINAL_USER" ]]; then
    echo -e "Directory ownership: ${BOLD}$ORIGINAL_USER${RESET}"
fi
echo -e "${YELLOW}Elapsed Time: ${minutes} minutes and ${seconds} seconds.${RESET}"
echo
