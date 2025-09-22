#!/bin/bash

# ==============================================================================
# The Detective - A Forensic Android ROM Comparison Tool
# Version: 2.6
# Author: ravindu644
#
# This script performs a deep, forensic comparison between two or three
# unpacked Android ROM directories to identify all modifications.
#
# CHANGE LOG (v2.6):
# - Implemented blacklisting for files and extensions (e.g., odex, vdex) to
#   separate useless changes from the main analysis.
# - Fixed config file permissions to ensure it's always editable by the
#   original user who invoked sudo.
# - Re-organized and cleaned up the final Analysis_Summary.txt for better
#   readability and a more logical flow of information.
# - Fixed a bug where report files were being written to an undeclared directory.
# ==============================================================================

# --- Configuration and Style ---
CONFIG_FILE="detective.conf"
BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
RESET="\033[0m"

# Store original user for config file ownership. This is crucial for allowing
# non-root users to edit the config file after it's created.
ORIGINAL_USER="${SUDO_USER:-$USER}"

# --- Functions ---

# Banner function
print_banner() {
    echo -e "${BOLD}${GREEN}"
    echo "┌───────────────────────────────────────────┐"
    echo "│     The Detective - ROM Analysis Tool     │"
    echo "│              v2.6                         │"
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
        ["openjdk-17-jdk"]="java"
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
}

# Function to fix config file permissions, ensuring the original user can edit it.
# This is called immediately after the config file is created.
fix_config_permissions() {
    if [[ -f "$CONFIG_FILE" && -n "$ORIGINAL_USER" ]]; then
        chown "$ORIGINAL_USER" "$CONFIG_FILE"
        echo "Configuration file ownership assigned to '$ORIGINAL_USER' for easy editing."
    fi
}

# Function to check for and install apksigner
check_and_install_apksigner() {
    if ! command -v "apksigner" &> /dev/null; then
        echo "apksigner not found. Attempting to install it system-wide..."
        export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
        
        echo " -> Downloading Android SDK command-line tools..."
        wget https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -O /tmp/cmdline-tools.zip
        
        echo " -> Unzipping and placing tools..."
        unzip -q /tmp/cmdline-tools.zip -d /tmp/
        mkdir -p /usr/lib/android-sdk/cmdline-tools/
        mv /tmp/cmdline-tools /usr/lib/android-sdk/cmdline-tools/latest

        echo " -> Installing Android SDK Build-Tools (this may take a moment)..."
        yes | /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager --licenses > /dev/null
        /usr/lib/android-sdk/cmdline-tools/latest/bin/sdkmanager "build-tools;34.0.0" > /dev/null

        echo " -> Creating symlink for easy access..."
        ln -s /usr/lib/android-sdk/build-tools/34.0.0/apksigner /usr/local/bin/apksigner

        if ! command -v "apksigner" &> /dev/null; then
             echo "Error: apksigner installation failed. Please try installing the Android SDK Build-Tools manually."
             exit 1
        fi
        echo "apksigner has been installed successfully."
    else
        echo "apksigner is already installed."
    fi
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
FORCE_TEXT_EXTENSIONS="rc prop xml sh bp json"

# --- Blacklisting ---
# A space-separated list of file extensions to move from the "changed" list
# to a separate "blacklisted" report. This is for files that change but
# provide no useful diff information (e.g., compiled odex/vdex files).
BLACKLIST_EXTENSIONS="odex vdex oat art prof art"

# A space-separated list of exact filenames/paths to blacklist.
# eg: BLACKLIST_FILES="./system/priv-app/SamsungCoreServices/SamsungCoreServices.apk.gz"
BLACKLIST_FILES=""

# --- Deep Dive Analysis ---
# A space-separated list of critical directories you want a detailed,
# categorized report for. Use this to focus on the most important areas.
# Paths must start with './' (e.g., ./system/bin).
CRITICAL_DIRECTORIES="./system/apex ./system/bin ./system/etc ./system/framework ./system/lib ./system/lib64"

# --- Archive Analysis ---
# Enable/disable deep analysis of archive contents (.zip, .apex, etc.)
ANALYZE_ARCHIVES="true"
# Space-separated list of extensions to treat as archives.
# NOTE: .apk and .jar are handled separately by the APKTOOL_COMMAND.
ARCHIVE_EXTENSIONS="apex zip"

# --- APK Signature Analysis ---
# When enabled, the script will use 'apksigner' to check if a changed APK
# was re-signed by the porter (suspicious) or just officially updated by the OEM.
# This can save hours by skipping apktool analysis on hundreds of official updates.
ENABLE_APK_SIGNATURE_FILTER="true"

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
        echo "Default configuration has been created."
        # This is where we ensure the new config file is owned by the user.
        fix_config_permissions
        read -p "Please review/edit '$CONFIG_FILE' to your liking now, then press [Enter] to begin the analysis."
    fi
}

# Function to check if a file is blacklisted based on the config settings.
# Returns 0 (true) if the file matches a name or extension in the blacklist.
is_blacklisted_file() {
    local file_path="$1"
    
    # Check if the exact file path is blacklisted
    for blacklist_file in $BLACKLIST_FILES; do
        if [[ "$file_path" == "$blacklist_file" ]]; then
            return 0
        fi
    done
    
    # Check if the file's extension is blacklisted
    local ext="${file_path##*.}"
    for blacklist_ext in $BLACKLIST_EXTENSIONS; do
        if [[ "$ext" == "$blacklist_ext" ]]; then
            return 0
        fi
    done
    
    # Not blacklisted
    return 1
}

# Function to check if a file has only signature changes
check_signature_only_changes() {
    local file_path="$1"
    local base_file="$BASE_ROM_PATH/$file_path"
    local ported_file="$PORTED_ROM_PATH/$file_path"
    
    if [[ "$FILTER_SIGNATURE_ONLY_CHANGES" != "true" ]]; then
        return 1
    fi
    
    if [[ ! -f "$base_file" || ! -f "$ported_file" ]]; then
        return 1
    fi
    
    local base_size=$(wc -c < "$base_file" 2>/dev/null || echo 0)
    local ported_size=$(wc -c < "$ported_file" 2>/dev/null || echo 0)
    
    if [[ $ported_size -le $base_size ]]; then
        return 1
    fi
    
    local size_diff=$((ported_size - base_size))
    
    if [[ $size_diff -gt 100 ]]; then
        return 1
    fi
    
    local signature_candidate
    signature_candidate=$(tail -c "$size_diff" "$ported_file" 2>/dev/null | tr -d '\0\n\r' | strings -a | head -1)
    
    if [[ -n "$signature_candidate" ]]; then
        while IFS= read -r pattern; do
            [[ -z "$pattern" || "$pattern" =~ ^[[:space:]]*# ]] && continue
            
            if echo "$signature_candidate" | grep -qE "$pattern"; then
                if head -c "$base_size" "$ported_file" | cmp -s - "$base_file"; then
                    return 0
                fi
            fi
        done <<< "$IGNORE_SIGNATURE_PATTERNS"
    fi
    
    return 1
}

# New function to check if APK signatures are different
check_apk_signatures_differ() {
    local base_apk="$1"
    local ported_apk="$2"

    local base_sig
    base_sig=$(apksigner verify --print-certs "$base_apk" 2>/dev/null | grep "SHA-256 digest" | awk '{print $NF}')
    local ported_sig
    ported_sig=$(apksigner verify --print-certs "$ported_apk" 2>/dev/null | grep "SHA-256 digest" | awk '{print $NF}')

    if [[ -z "$base_sig" || -z "$ported_sig" ]]; then
        # If we can't get a signature from either, assume it's a real change.
        return 0
    fi

    if [[ "$base_sig" != "$ported_sig" ]]; then
        # Signatures are different, this is a porter modification.
        return 0
    else
        # Signatures are the same, this is an official update.
        return 1
    fi
}


# Function to compare hash lists and categorize files into deleted, new, changed, and unchanged.
# This now includes logic to filter out blacklisted files from the main "changed" list.
compare_hash_files() {
    local base_hashes="$1"
    local ported_hashes="$2"
    local deleted_output="$3"
    local new_output="$4"
    local changed_output="$5"
    local unchanged_output="$6"
    
    echo "Analyzing file differences using AWK-based comparison..." >&2
    
    # AWK script to perform the main file comparison based on hashes
    awk '
    FNR==NR {
        base_files[$2] = $1
        base_count++
        next
    }
    {
        filepath = $2
        ported_hash = $1
        
        if (filepath in base_files) {
            if (base_files[filepath] != ported_hash) {
                print filepath > changed_file
            } else {
                print filepath > unchanged_file
            }
            delete base_files[filepath]
        } else {
            print filepath > new_file
        }
        ported_count++
    }
    END {
        for (filepath in base_files) {
            print filepath > deleted_file
        }
    }
    ' changed_file="$changed_output" deleted_file="$deleted_output" new_file="$new_output" unchanged_file="$unchanged_output" \
      "$base_hashes" "$ported_hashes"
    
    # Post-processing for the "changed" files list
    if [[ -f "$changed_output" ]]; then
        echo -e "\nFiltering signature and blacklisted changes..." >&2
        
        local temp_changed="$TEMP_DIR/filtered_changed.tmp"
        local temp_signature_only="$TEMP_DIR/signature_only.tmp"
        local temp_blacklisted="$TEMP_DIR/blacklisted.tmp"
        
        > "$temp_changed"
        > "$temp_signature_only"
        > "$temp_blacklisted"
        
        local total_changed=$(wc -l < "$changed_output")
        local current=0
        
        # Iterate through initially changed files to filter them further
        while IFS= read -r filepath; do
            ((current++))
            printf "\r -> Filtering file %d of %d: %-50s" "$current" "$total_changed" "$(basename "$filepath")" >&2
            
            if is_blacklisted_file "$filepath"; then
                # This file is blacklisted, move it to the blacklisted list.
                echo "$filepath" >> "$temp_blacklisted"
            elif [[ "$FILTER_SIGNATURE_ONLY_CHANGES" == "true" ]] && check_signature_only_changes "$filepath"; then
                # This file only has signature changes, move it to the signature-only list.
                echo "$filepath" >> "$temp_signature_only"
            else
                # This is a real change.
                echo "$filepath" >> "$temp_changed"
            fi
        done < "$changed_output" 
        printf "\r\033[K" >&2
        
        # Replace original changed list with the filtered one
        mv "$temp_changed" "$changed_output"
        
        # Add signature-only files to the unchanged list
        local signature_count=$(wc -l < "$temp_signature_only" 2>/dev/null || echo 0)
        if [[ $signature_count -gt 0 ]]; then
            cat "$temp_signature_only" >> "$unchanged_output"
        fi
        
        # Handle blacklisted files by creating a separate report for them
        local blacklist_count=$(wc -l < "$temp_blacklisted" 2>/dev/null || echo 0)
        if [[ $blacklist_count -gt 0 ]]; then
            local blacklist_output="$REPORT_DIR/blacklisted_changes.txt"
            mkdir -p "$(dirname "$blacklist_output")"
            
            {
                echo "================================================================"
                echo " BLACKLISTED FILE CHANGES - Not included in main analysis"
                echo "================================================================"
                echo "These files are configured to be tracked separately as they"
                echo "typically represent useless changes (like odex/vdex files)."
                echo
                echo "Changed blacklisted files:"
                echo "-------------------------"
                sort "$temp_blacklisted"
                echo
                echo "Total blacklisted changes: $blacklist_count"
            } > "$blacklist_output"
            
            echo -e "\nFound $blacklist_count blacklisted file changes - see reports/blacklisted_changes.txt" >&2
        fi

        # Return the count of signature-only changes found
        echo "$signature_count"
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
        # [BUG FIX] Ensure we read from the provided argument, not a hardcoded path
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
        total_replaced_with_stock=$(wc -l < "$RAW_LISTS_DIR/07_REPLACED_WITH_STOCK.txt" 2>/dev/null || echo 0)
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

        if [[ "$ANALYSIS_MODE" == "TRIPLE" ]]; then
            echo "Replaced with stock files: $total_replaced_with_stock"
        fi

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

# New function to generate a focused, graphical report for critical directories
generate_deep_dive_report() {
    local output_file="$1"

    echo "Generating Deep Dive Analysis Report..."

    {
        echo "======================================================="
        echo " DETECTIVE DEEP DIVE ANALYSIS REPORT"
        echo "======================================================="
        echo "This report provides a focused, table-based breakdown of changes within user-defined critical directories."
        echo

        for crit_dir in $CRITICAL_DIRECTORIES; do
            # Ensure the directory path ends with a slash for more precise matching
            [[ "$crit_dir" != */ ]] && crit_dir="$crit_dir/"

            echo "--------------------------------------------------------------------------------"
            printf "ANALYSIS FOR: %s\n" "$crit_dir"
            echo "--------------------------------------------------------------------------------"

            # Create temporary filtered lists for the current directory
            grep "^$crit_dir" "$RAW_LISTS_DIR/07_REPLACED_WITH_STOCK.txt" > "$TEMP_DIR/dd_replaced.list" 2>/dev/null || touch "$TEMP_DIR/dd_replaced.list"
            grep "^$crit_dir" "$RAW_LISTS_DIR/04_ADDED_FROM_STOCK.txt" > "$TEMP_DIR/dd_added_stock.list" 2>/dev/null || touch "$TEMP_DIR/dd_added_stock.list"
            grep "^$crit_dir" "$RAW_LISTS_DIR/02_CHANGED_FILES.txt" > "$TEMP_DIR/dd_changed.list" 2>/dev/null || touch "$TEMP_DIR/dd_changed.list"
            grep "^$crit_dir" "$RAW_LISTS_DIR/03_NEW_FILES.txt" > "$TEMP_DIR/dd_new.list" 2>/dev/null || touch "$TEMP_DIR/dd_new.list"
            grep "^$crit_dir" "$RAW_LISTS_DIR/01_DELETED_FILES.txt" > "$TEMP_DIR/dd_deleted.list" 2>/dev/null || touch "$TEMP_DIR/dd_deleted.list"

            # Check if any of the lists have content
            local has_data=false
            for list_file in "$TEMP_DIR/dd_replaced.list" "$TEMP_DIR/dd_added_stock.list" "$TEMP_DIR/dd_changed.list" "$TEMP_DIR/dd_new.list" "$TEMP_DIR/dd_deleted.list"; do
                if [[ -s "$list_file" ]]; then
                    has_data=true
                    break
                fi
            done

            if [[ "$has_data" == "false" ]]; then
                echo "No changes detected in this directory."
                echo
                continue
            fi

            # Generate flexible table using dynamic column widths
            awk '
            BEGIN {
                # Load all data and count non-empty entries
                while ((getline line < ARGV[1]) > 0) if (line) { replaced[++r_count] = basename(line) }
                while ((getline line < ARGV[2]) > 0) if (line) { added_stock[++as_count] = basename(line) }
                while ((getline line < ARGV[3]) > 0) if (line) { changed[++c_count] = basename(line) }
                while ((getline line < ARGV[4]) > 0) if (line) { new_files[++nf_count] = basename(line) }
                while ((getline line < ARGV[5]) > 0) if (line) { deleted[++d_count] = basename(line) }
                
                # Find maximum rows needed (only count non-empty lists)
                max_rows = 0
                if (r_count > max_rows) max_rows = r_count
                if (as_count > max_rows) max_rows = as_count
                if (c_count > max_rows) max_rows = c_count
                if (nf_count > max_rows) max_rows = nf_count
                if (d_count > max_rows) max_rows = d_count
                
                if (max_rows == 0) {
                    print "No changes detected."
                    exit
                }
                
                # Calculate dynamic column widths based on content
                col1_width = length("[REPLACED] w/ Stock")
                col2_width = length("[ADDED] from Stock")
                col3_width = length("[CHANGED] by Porter")
                col4_width = length("[NEW] Files")
                col5_width = length("[DELETED] Files")
                
                for (i = 1; i <= r_count; i++) if (length(replaced[i]) > col1_width) col1_width = length(replaced[i])
                for (i = 1; i <= as_count; i++) if (length(added_stock[i]) > col2_width) col2_width = length(added_stock[i])
                for (i = 1; i <= c_count; i++) if (length(changed[i]) > col3_width) col3_width = length(changed[i])
                for (i = 1; i <= nf_count; i++) if (length(new_files[i]) > col4_width) col4_width = length(new_files[i])
                for (i = 1; i <= d_count; i++) if (length(deleted[i]) > col5_width) col5_width = length(deleted[i])
                
                # Cap maximum column width to prevent overly wide tables
                max_col_width = 50
                if (col1_width > max_col_width) col1_width = max_col_width
                if (col2_width > max_col_width) col2_width = max_col_width
                if (col3_width > max_col_width) col3_width = max_col_width
                if (col4_width > max_col_width) col4_width = max_col_width
                if (col5_width > max_col_width) col5_width = max_col_width
                
                # Ensure minimum width
                if (col1_width < 20) col1_width = 20
                if (col2_width < 20) col2_width = 20
                if (col3_width < 20) col3_width = 20
                if (col4_width < 15) col4_width = 15
                if (col5_width < 15) col5_width = 15
                
                separator_width = col1_width + col2_width + col3_width + col4_width + col5_width + 16
            }
            END {
                # Print header
                printf "\n"
                printf "%-*s | %-*s | %-*s | %-*s | %-*s\n", 
                    col1_width, "[REPLACED] w/ Stock", 
                    col2_width, "[ADDED] from Stock", 
                    col3_width, "[CHANGED] by Porter", 
                    col4_width, "[NEW] Files", 
                    col5_width, "[DELETED] Files"
                
                # Print separator
                for (i = 0; i < separator_width; i++) printf "-"
                printf "\n"
                
                # Print data rows (only up to max_rows, no empty rows)
                for (i = 1; i <= max_rows; i++) {
                    printf "%-*s | %-*s | %-*s | %-*s | %-*s\n",
                        col1_width, (i <= r_count ? truncate_if_needed(replaced[i], col1_width) : ""),
                        col2_width, (i <= as_count ? truncate_if_needed(added_stock[i], col2_width) : ""),
                        col3_width, (i <= c_count ? truncate_if_needed(changed[i], col3_width) : ""),
                        col4_width, (i <= nf_count ? truncate_if_needed(new_files[i], col4_width) : ""),
                        col5_width, (i <= d_count ? truncate_if_needed(deleted[i], col5_width) : "")
                }
                printf "\n"
                
                # Print summary counts
                printf "TOTALS: %d replaced, %d added, %d changed, %d new, %d deleted\n\n", 
                    r_count, as_count, c_count, nf_count, d_count
            }
            
            function basename(path) {
                # Extract filename from full path
                gsub(/.*\//, "", path)
                return path
            }
            
            function truncate_if_needed(text, width) {
                if (length(text) > width) {
                    return substr(text, 1, width - 3) "..."
                }
                return text
            }
            ' "$TEMP_DIR/dd_replaced.list" "$TEMP_DIR/dd_added_stock.list" "$TEMP_DIR/dd_changed.list" "$TEMP_DIR/dd_new.list" "$TEMP_DIR/dd_deleted.list"
            
            # Clean up temporary files for this directory
            rm -f "$TEMP_DIR/dd_replaced.list" "$TEMP_DIR/dd_added_stock.list" "$TEMP_DIR/dd_changed.list" "$TEMP_DIR/dd_new.list" "$TEMP_DIR/dd_deleted.list"
        done
    } > "$output_file"
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
                    ;;
                readelf)
                    if [[ "$mime_type" == "application/x-elf" || "$mime_type" == "application/x-sharedlib" || "$mime_type" == "application/x-executable" ]]; then
                        readelf -d "$stock_file" > "$TEMP_DIR/stock.elf" 2>/dev/null
                        readelf -d "$ported_file" > "$TEMP_DIR/ported.elf" 2>/dev/null
                        diff -u --label "$stock_file" --label "$ported_file" "$TEMP_DIR/stock.elf" "$TEMP_DIR/ported.elf" > "$patch_output_dir/$(basename "$relative_path").dependencies.patch" 2>/dev/null
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
check_and_install_apksigner
check_and_create_config

# Load the configuration file into the script's environment
source "./$CONFIG_FILE"

# --- Phase 1: Initialization ---
echo -e "\n--- Phase 1: Initialization ---\n"
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

# --- Timer Start ---
start_time=$SECONDS

# --- Phase 2: Hash Generation and Comparison ---
echo
echo -e "--- Phase 2: Generating File Hashes (This may take a while...) ---\n"

# Setup output environment
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
DEFAULT_FOLDER_NAME="detective_results_$TIMESTAMP"
SCRIPT_DIR=$(pwd)

read -e -p "Enter custom output folder name (or press Enter for default: $DEFAULT_FOLDER_NAME): " CUSTOM_FOLDER_NAME

if [[ -z "$CUSTOM_FOLDER_NAME" ]]; then
    OUTPUT_DIR="$SCRIPT_DIR/$DEFAULT_FOLDER_NAME"
else
    OUTPUT_DIR="$SCRIPT_DIR/$CUSTOM_FOLDER_NAME"
fi

# Define all output directories
PATCHES_DIR="$OUTPUT_DIR/patches"
RAW_LISTS_DIR="$OUTPUT_DIR/raw_file_lists"
REPORT_DIR="$OUTPUT_DIR/reports"
TEMP_DIR="$OUTPUT_DIR/temp"

# Create all necessary directories and files *before* starting analysis
mkdir -p "$OUTPUT_DIR" "$PATCHES_DIR" "$RAW_LISTS_DIR" "$REPORT_DIR" "$TEMP_DIR"
# Pre-create all result files to prevent "No such file" errors
touch "$RAW_LISTS_DIR/01_DELETED_FILES.txt"
touch "$RAW_LISTS_DIR/02_CHANGED_FILES.txt"
touch "$RAW_LISTS_DIR/03_NEW_FILES.txt"
touch "$RAW_LISTS_DIR/04_ADDED_FROM_STOCK.txt"
touch "$RAW_LISTS_DIR/05_UNCHANGED_FILES.txt"
touch "$RAW_LISTS_DIR/07_REPLACED_WITH_STOCK.txt"
touch "$RAW_LISTS_DIR/08_OFFICIAL_UPDATES.txt"
echo "Results will be saved in: $OUTPUT_DIR"


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

# This function now returns the count of signature-only (watermarked) files found
SIGNATURE_COUNT=$(compare_hash_files \
    "$TEMP_DIR/base.hashes" \
    "$TEMP_DIR/ported.hashes" \
    "$RAW_LISTS_DIR/01_DELETED_FILES.txt" \
    "$RAW_LISTS_DIR/03_NEW_FILES.txt" \
    "$RAW_LISTS_DIR/02_CHANGED_FILES.txt" \
    "$RAW_LISTS_DIR/05_UNCHANGED_FILES.txt"
)

# Post-analysis filtering for APKs based on their digital signatures
if [[ "$ENABLE_APK_SIGNATURE_FILTER" == "true" ]]; then
    echo -e "\nFiltering changed APKs by signature..." >&2
    
    temp_real_changes="$TEMP_DIR/real_apk_changes.tmp"
    temp_official_updates="$RAW_LISTS_DIR/08_OFFICIAL_UPDATES.txt"
    > "$temp_real_changes"
    > "$temp_official_updates"
    
    total_apks=$(grep -c '\.apk$' "$RAW_LISTS_DIR/02_CHANGED_FILES.txt" 2>/dev/null || echo 0)
    current_apk=0
    
    while IFS= read -r filepath; do
        # We only care about APKs in this filter
        if [[ "$filepath" == *.apk ]]; then
            ((current_apk++))
            printf "\r -> Checking APK signature %d of %d: %-50s" "$current_apk" "$total_apks" "$(basename "$filepath")" >&2
            
            if check_apk_signatures_differ "$BASE_ROM_PATH/$filepath" "$PORTED_ROM_PATH/$filepath"; then
                # Signatures differ: likely a porter modification
                echo "$filepath" >> "$temp_real_changes"
            else
                # Signatures match: likely an official OEM update
                echo "$filepath" >> "$temp_official_updates"
            fi
        else
            # Pass non-APK files through without checking
            echo "$filepath" >> "$temp_real_changes"
        fi
    done < "$RAW_LISTS_DIR/02_CHANGED_FILES.txt"
    printf "\r\033[K" >&2
    
    mv "$temp_real_changes" "$RAW_LISTS_DIR/02_CHANGED_FILES.txt"
    official_updates_count=$(wc -l < "$temp_official_updates" 2>/dev/null || echo 0)
    echo -e "${BOLD}Filtered out $official_updates_count official APK updates, $(wc -l < "$RAW_LISTS_DIR/02_CHANGED_FILES.txt") real changes remain${RESET}" >&2
fi


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

# Sort all the raw list files alphabetically for readability
for f in "$RAW_LISTS_DIR"/*.txt; do
    sort -o "$f" "$f"
done

echo "File comparison complete."

# Print summary of findings
echo
echo -e "${YELLOW}--- Comparison Summary ---${RESET}"
if [[ "$ENABLE_APK_SIGNATURE_FILTER" == "true" ]]; then
    porter_modified_apks=$(grep -c '\.apk$' "$RAW_LISTS_DIR/02_CHANGED_FILES.txt" 2>/dev/null || echo 0)
    echo "Porter modified APKs: $porter_modified_apks (will be deep scanned)"
    echo "Official APK updates: $(wc -l < "$RAW_LISTS_DIR/08_OFFICIAL_UPDATES.txt" 2>/dev/null || echo 0) (skipped deep scan)"
fi
echo "Changed files: $(wc -l < "$RAW_LISTS_DIR/02_CHANGED_FILES.txt" 2>/dev/null || echo 0)"
if [[ -f "$REPORT_DIR/blacklisted_changes.txt" && -s "$REPORT_DIR/blacklisted_changes.txt" ]]; then
    echo "Blacklisted changes: $(awk '/Total blacklisted changes:/ {print $NF}' "$REPORT_DIR/blacklisted_changes.txt") (see reports folder)"

fi
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
analyze_modification_patterns "$RAW_LISTS_DIR/02_CHANGED_FILES.txt" "$PATCHES_DIR" "$REPORT_DIR/Porting_Intelligence_Report.txt"

# Generate the new Deep Dive report
generate_deep_dive_report "$REPORT_DIR/Deep_Dive_Analysis.txt"

# --- Phase 4: Final Report & Cleanup ---
echo
echo "--- Phase 4: Generating Final Report ---"

SUMMARY_FILE="$OUTPUT_DIR/Analysis_Summary.txt"

# Generate the main summary report with a clean, logical structure.
{
    echo "======================================================="
    echo " Forensic Analysis Report - Generated by The Detective"
    echo "======================================================="
    echo "Generated on: $(date)"
    echo
    echo "Ported ROM: $PORTED_ROM_PATH"
    echo "Base ROM:   $BASE_ROM_PATH"
    [[ "$ANALYSIS_MODE" == "TRIPLE" ]] && echo "Stock ROM:  $TARGET_STOCK_PATH"
    echo "-------------------------------------------------------"
    echo

    echo "--- [DELETED] Files (Present in Base, missing in Ported) ---"
    if [[ -s "$RAW_LISTS_DIR/01_DELETED_FILES.txt" ]]; then cat "$RAW_LISTS_DIR/01_DELETED_FILES.txt"; else echo "None"; fi
    echo

    echo "--- [NEW] Files (Present in Ported, missing in Base) ---"
    if [[ -s "$RAW_LISTS_DIR/03_NEW_FILES.txt" ]]; then cat "$RAW_LISTS_DIR/03_NEW_FILES.txt"; else echo "None"; fi
    echo

    if [[ "$ANALYSIS_MODE" == "TRIPLE" ]]; then
        echo "--- [REPLACED] Base ROM Files with Target Stock Versions ---"
        if [[ -s "$RAW_LISTS_DIR/07_REPLACED_WITH_STOCK.txt" ]]; then cat "$RAW_LISTS_DIR/07_REPLACED_WITH_STOCK.txt"; else echo "None"; fi
        echo

        echo "--- [ADDED] New Files from Target Stock ROM ---"
        if [[ -s "$RAW_LISTS_DIR/04_ADDED_FROM_STOCK.txt" ]]; then cat "$RAW_LISTS_DIR/04_ADDED_FROM_STOCK.txt"; else echo "None"; fi
        echo
    fi

    echo "--- [CHANGED] Files (Content differs from Base ROM) ---"
    if [[ -s "$RAW_LISTS_DIR/02_CHANGED_FILES.txt" ]]; then cat "$RAW_LISTS_DIR/02_CHANGED_FILES.txt"; else echo "None"; fi
    echo

    echo "--- [BLACKLISTED] Useless Changes (Tracked Separately) ---"
    if [[ -s "$REPORT_DIR/blacklisted_changes.txt" ]]; then
        # Extract just the file list from the dedicated blacklist report
        awk '/^-+$/,!seen {seen=1;next} seen && NF {print} !NF {exit}' "$REPORT_DIR/blacklisted_changes.txt"
    else
        echo "None"
    fi
    echo

    echo "--- [OFFICIAL UPDATES] (Same signature, different hash) ---"
    if [[ -s "$RAW_LISTS_DIR/08_OFFICIAL_UPDATES.txt" ]]; then cat "$RAW_LISTS_DIR/08_OFFICIAL_UPDATES.txt"; else echo "None"; fi
    echo

    echo "--- [UNCHANGED] Files (Identical in both ROMs, including watermarked) ---"
    if [[ -s "$RAW_LISTS_DIR/05_UNCHANGED_FILES.txt" ]]; then cat "$RAW_LISTS_DIR/05_UNCHANGED_FILES.txt"; else echo "None"; fi
    echo
    
} > "$SUMMARY_FILE"

if [[ "$CLEANUP_TEMP_FILES" == "true" ]]; then
    echo "Cleaning up temporary files..."
    rm -rf "$TEMP_DIR"
fi

# Change ownership of output directory to original user
if [[ -n "$ORIGINAL_USER" && "$ORIGINAL_USER" != "root" ]]; then
    echo "Changing ownership of output directory to $ORIGINAL_USER..."
    chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$OUTPUT_DIR"
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
if [[ -n "$ORIGINAL_USER" && "$ORIGINAL_USER" != "root" ]]; then
    echo -e "Directory ownership: ${BOLD}$ORIGINAL_USER${RESET}"
fi
echo -e "${YELLOW}Elapsed Time: ${minutes} minutes and ${seconds} seconds.${RESET}"
echo
