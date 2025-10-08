#!/system/bin/sh

# =================================================================
#  Android Dependency Lister & Copier v3.3 (Final)
#
#  - POSIX compliant, avoids subshell bugs by reading from a file.
#  - MUST be run from a root shell (run 'su' first).
#  - Saves lists and libraries to /sdcard.
# =================================================================

# --- Main Script Logic ---
clear
echo "========================================="
echo "  Android Dependency Lister & Copier"
echo "========================================="
echo

# Step 1: Get keyword
echo "Enter a keyword to search for processes:"
read -r keyword
if [ -z "$keyword" ]; then
    echo "Error: Keyword cannot be empty."
    exit 1
fi

# Step 2: Search for processes
echo
echo "Searching for processes..."
processes=$(ps -ef | awk -v kw="$keyword" '$0 ~ kw' | awk '!/awk -v kw=/ {print $2"|"$8}')

if [ -z "$processes" ]; then
    echo "No matching processes found for keyword: ${keyword}"
    exit 1
fi

# Step 3: Let user select a process
echo
echo "Matching processes found:"
echo "$processes" | awk -F'|' '{ printf "  [%d] PID: %s | Process: %s\n", NR, $1, $2 }'
num_options=$(echo "$processes" | wc -l)
cancel_num=$((num_options + 1))
echo "  [$cancel_num] Cancel and exit"

user_choice=0
while [ "$user_choice" -le 0 ] || [ "$user_choice" -gt "$cancel_num" ]; do
    echo
    echo "Enter a number (1-$cancel_num):"
    read -r user_choice
    case "$user_choice" in
        (*[!0-9]*|'')
            echo "Invalid input. Please enter a number."
            user_choice=0
            ;;
    esac
done

if [ "$user_choice" -eq "$cancel_num" ]; then
    echo; echo "Operation cancelled."; exit 0;
fi

selected_line=$(echo "$processes" | sed -n "${user_choice}p")
selected_pid=$(echo "$selected_line" | cut -d'|' -f1)
selected_name=$(echo "$selected_line" | cut -d'|' -f2)

clear
echo "Selected: PID $selected_pid | Process $selected_name"
echo

# Step 4: Extract dependencies
echo "Extracting dependencies for PID $selected_pid..."
dependencies=$(cat "/proc/$selected_pid/maps" | awk '/\.so/ {print $NF}' | sort -u)

if [ -z "$dependencies" ]; then
    echo "No .so dependencies found for PID: $selected_pid"; exit 1;
fi

# Step 5: Display dependencies
echo
echo "-----------------------------------------"
echo "     Shared Library Dependencies"
echo "-----------------------------------------"
echo "$dependencies" | awk '{ print "     " NR "  " $0 }'
dep_count=$(echo "$dependencies" | wc -l)
echo "-----------------------------------------"
echo "Total unique dependencies found: $dep_count"
echo

# Step 6: Save the dependency list to /sdcard
deps_list_file="/sdcard/deps_${selected_pid}.txt"
echo "$dependencies" > "$deps_list_file"
if [ -f "$deps_list_file" ]; then
    echo "Successfully saved dependency list to: $deps_list_file"
else
    echo "Error: Failed to save dependency list."
    exit 1
fi

# Step 7: Offer to copy the actual library files
echo
echo "Would you like to copy the actual library files to /sdcard? (y/n)"
read -r copy_choice

if [ "$copy_choice" = "y" ] || [ "$copy_choice" = "Y" ]; then
    default_folder="libs_${selected_pid}"
    echo "Enter folder name to save libraries in /sdcard/"
    echo "(default: ${default_folder}):"
    read -r custom_folder

    if [ -z "$custom_folder" ]; then
        dest_folder="/sdcard/$default_folder"
    else
        dest_folder="/sdcard/$custom_folder"
    fi
    
    echo
    echo "Preparing to copy libraries to: $dest_folder"
    mkdir -p "$dest_folder"
    
    copied_count=0
    failed_count=0
    
    # =========================================================================
    # THE FIX: Read from the file directly using `<` to avoid a subshell.
    # This ensures the counter variables are not lost after the loop.
    # =========================================================================
    while IFS= read -r lib_path; do
        if [ -z "$lib_path" ]; then continue; fi
        
        if cp --parents "$lib_path" "$dest_folder" >/dev/null 2>&1; then
            echo "  COPIED: $lib_path"
            copied_count=$((copied_count + 1))
        else
            echo "  FAILED: $lib_path"
            failed_count=$((failed_count + 1))
        fi
    done < "$deps_list_file"
    
    # Final Summary
    echo
    echo "-----------------------------------------"
    echo "             Copy Summary"
    echo "-----------------------------------------"
    echo "Successfully copied: $copied_count files"
    echo "Failed to copy: $failed_count files"
    echo
    echo "Note: Failures are expected for files in protected"
    echo "areas like /apex due to Android's SELinux security."
    echo
    echo "All accessible files were saved in:"
    echo "$dest_folder"
    echo "-----------------------------------------"
fi

echo
echo "Done!"
