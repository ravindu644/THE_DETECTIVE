#!/bin/bash

# --- Colors and Basic Setup ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Prerequisite Checks ---
if ! command -v adb &> /dev/null; then
    echo -e "${RED}Error: adb is not installed or not in your PATH.${NC}"
    exit 1
fi
if ! adb devices | grep -q "device$"; then
    echo -e "${RED}Error: No ADB device is connected or authorized.${NC}"
    exit 1
fi

# --- Menu Function ---
select_option() {
    local options=("$@")
    local num_options=${#options[@]}
    local selected=0
    local key
    tput civis; trap 'tput cnorm' EXIT
    while true; do
        clear
        echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}${BOLD}    Select a Process (Use ↑/↓ arrows, Enter)${NC}"
        echo -e "${CYAN}${BOLD}═══════════════════════════════════════════════════${NC}\n"
        for i in "${!options[@]}"; do
            if [ $i -eq $selected ]; then echo -e "${GREEN}▶ ${options[$i]}${NC}"; else echo -e "  ${options[$i]}"; fi
        done
        read -rsn3 key
        case "$key" in
            $'\x1b[A') ((selected--)); [ $selected -lt 0 ] && selected=$((num_options - 1));;
            $'\x1b[B') ((selected++)); [ $selected -ge $num_options ] && selected=0;;
            '') tput cnorm; trap - EXIT; return $selected;;
        esac
    done
}

# --- Main Script Logic ---
clear
echo -e "${CYAN}${BOLD}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║        ADB Dependency List Extractor v5.0 (Save Only)      ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}\n"

# Step 1: Get keyword
echo -ne "${YELLOW}Enter a keyword to search for running processes:${NC} "
read -r keyword
if [ -z "$keyword" ]; then echo -e "${RED}Error: Keyword cannot be empty.${NC}"; exit 1; fi

# Step 2: Search for processes using `su -c`
echo -e "\n${BLUE}Searching for processes (with root)...${NC}"
processes=$(adb shell "su -c 'ps -ef'" | awk -v kw="$keyword" '$0 ~ kw {print $2"|"$8}')
if [ -z "$processes" ]; then echo -e "${RED}No matching processes found for keyword: ${keyword}${NC}"; exit 1; fi
echo -e "${GREEN}Found $(echo "$processes" | wc -l) matching process(es).${NC}\n"

# Step 3: Let user select a process
process_options=()
pids=()
while IFS='|' read -r pid name; do
    process_options+=("PID: $pid | Process: $name")
    pids+=("$pid")
done <<< "$processes"
process_options+=("Cancel and exit")
select_option "${process_options[@]}"; selected_index=$?
if [ $selected_index -eq ${#pids[@]} ]; then echo -e "\n${YELLOW}Operation cancelled.${NC}"; exit 0; fi
selected_pid=${pids[$selected_index]}
selected_process=${process_options[$selected_index]}

clear
echo -e "${CYAN}${BOLD}Selected: $selected_process${NC}\n"

# Step 6: Ask for output folder
echo -ne "${YELLOW}Enter output folder for saved files (default: current directory):${NC} "
read -r output_folder
if [ -z "$output_folder" ]; then
    output_folder="."
fi
mkdir -p "$output_folder"
echo -e "${BLUE}Extracting dependencies from /proc (with root)...${NC}"
dependencies=$(adb shell "su -c 'cat /proc/$selected_pid/maps'" | awk '/\.so/ {print $NF}' | sort -u)
if [ -z "$dependencies" ]; then echo -e "${RED}No .so dependencies found for PID: $selected_pid${NC}"; exit 1; fi

# Step 5: Display dependencies
echo -e "${CYAN}${BOLD}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║              Shared Library Dependencies                   ║${NC}"
echo -e "${CYAN}${BOLD}╚════════════════════════════════════════════════════════════╝${NC}\n"
dep_count=$(echo "$dependencies" | wc -l)
echo "$dependencies" | cat -n
echo -e "\n${GREEN}Total unique dependencies found: $dep_count${NC}\n"

# =================================================================================
# MODIFIED SECTION: Save to file only
# =================================================================================
# Step 6: Offer to save the dependency list
echo -ne "${YELLOW}Would you like to save this dependency list to a text file? (y/n):${NC} "
read -r save_choice

# Step 7: Offer to copy the actual library files to host
echo -ne "${YELLOW}Would you like to copy the actual library files to the host machine? (y/n):${NC} "
read -r copy_choice

if [[ $copy_choice == "y" || $copy_choice == "Y" ]]; then
    # Determine base name for output folder
    if [[ $save_choice == "y" || $save_choice == "Y" ]]; then
        echo -ne "${YELLOW}Enter name for the dependency list file (default: deps_${selected_pid}):${NC} "
        read -r custom_filename
        if [ -z "$custom_filename" ]; then
            base_name="deps_${selected_pid}"
        else
            base_name="$custom_filename"
        fi
    else
        base_name="deps_${selected_pid}"
    fi

    # Create temporary folder on device
    temp_folder="tmp_libs_${selected_pid}"
    device_temp_path="/sdcard/$temp_folder"
    adb shell "su -c 'mkdir -p \"$device_temp_path\"'"
    # Copy libraries to temp folder
    echo -e "${BLUE}Copying libraries to device temp folder...${NC}"
    copied_count=0
    failed_count=0
    
    for lib_path in $dependencies; do
        if [ -z "$lib_path" ]; then continue; fi
        
        output=$(adb shell "su -c 'if cp --parents \"$lib_path\" \"$device_temp_path\" 2>/dev/null; then echo copied; fi'")
        if [ "$output" = "copied" ]; then
            echo "  COPIED: $lib_path"
            copied_count=$((copied_count + 1))
        else
            echo "  FAILED: $lib_path"
            failed_count=$((failed_count + 1))
        fi
    done
    
    # Pull the temp folder to host
    host_output_folder="$output_folder/$base_name"
    echo -e "${BLUE}Pulling libraries to host folder: $host_output_folder${NC}"
    adb pull "$device_temp_path" "$host_output_folder"
    adb shell "rm -rf '$device_temp_path'"
    
    # Save the dependency list if requested
    if [[ $save_choice == "y" || $save_choice == "Y" ]]; then
        txt_file="$host_output_folder/${base_name}.txt"
        echo "$dependencies" > "$txt_file"
        if [ -f "$txt_file" ]; then
            echo -e "\n${GREEN}Successfully saved dependency list to: $txt_file${NC}"
        else
            echo -e "\n${RED}Error: Failed to save file.${NC}"
        fi
    fi
    
    # Summary
    echo -e "${CYAN}${BOLD}Copy Summary${NC}"
    echo "Successfully copied: $copied_count files"
    echo "Libraries saved to: $host_output_folder"
    echo "Note: Failures are expected for files in protected areas like /apex."
fi

echo -e "\n${CYAN}Done!${NC}"
