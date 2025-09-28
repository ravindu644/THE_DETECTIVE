#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
declare -A PROCESSED_LIBS
declare -A COPIED_LIBS
declare -A COPIED_LIBS_PATHS  # Maps library name to array of full paths
MISSING_DEPS=""

# Additional global variables for statistics
TOTAL_LIBS_FOUND=0
TOTAL_DEPS_PROCESSED=0
CURRENT_STATUS=""

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to clean and validate path input
clean_path() {
    local input="$1"
    
    # Remove leading and trailing whitespace
    input=$(echo "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    
    # Remove surrounding quotes (single or double)
    if [[ "$input" =~ ^\".*\"$ ]] || [[ "$input" =~ ^\'.*\'$ ]]; then
        input="${input#?}"  # Remove first character
        input="${input%?}"  # Remove last character
    fi
    
    # Expand tilde to home directory if present
    input="${input/#\~/$HOME}"
    
    echo "$input"
}

# Function to find all instances of a library file in the extracted image
find_library() {
    local lib_name="$1"
    local search_path="$2"
    
    # Search for all instances of the library
    find "$search_path" -type f -name "$lib_name" 2>/dev/null
}

# Function to get dependencies of a library
get_dependencies() {
    local lib_file="$1"
    
    if [[ ! -f "$lib_file" ]]; then
        return 1
    fi
    
    # Use objdump to get NEEDED dependencies
    objdump -p "$lib_file" 2>/dev/null | grep -i "NEEDED" | awk '{print $2}' | sort -u
}

# Function to copy library with directory structure
copy_with_structure() {
    local source_file="$1"
    local extracted_root="$2"
    local output_root="$3"
    local is_reference="${4:-false}"
    
    local relative_path
    relative_path=$(realpath --relative-to="$extracted_root" "$source_file")
    local target_path
    
    if [[ "$is_reference" == "true" ]]; then
        target_path="$output_root/REFERENCES/$relative_path"
    else
        target_path="$output_root/$relative_path"
    fi
    
    local target_dir
    target_dir=$(dirname "$target_path")
    
    mkdir -p "$target_dir"
    
    if cp "$source_file" "$target_path" 2>/dev/null; then
        local lib_name
        lib_name=$(basename "$source_file")
        COPIED_LIBS["$lib_name"]=1
        
        if [[ -z "${COPIED_LIBS_PATHS[$lib_name]}" ]]; then
            COPIED_LIBS_PATHS["$lib_name"]="$source_file"
        else
            COPIED_LIBS_PATHS["$lib_name"]="${COPIED_LIBS_PATHS[$lib_name]}|$source_file"
        fi
        
        if [[ $is_main_lib -eq 1 ]]; then
           print_success "Copied main library: $relative_path"
           is_main_lib=0
        fi
        return 0
    else
        print_error "Failed to copy: $source_file"
        return 1
    fi
}

# Function to add to missing dependencies list
add_missing_dep() {
    local dep="$1"
    if [[ -z "$MISSING_DEPS" ]]; then
        MISSING_DEPS="$dep"
    else
        MISSING_DEPS="$MISSING_DEPS"$'\n'"$dep"
    fi
}

# Function to update status line
update_status() {
    local status="$1"
    CURRENT_STATUS="$status"
    echo -en "\r\033[K${BLUE}[INFO]${NC} $status"
}

# Function to finalize status (move to next line)
finalize_status() {
    [[ -n "$CURRENT_STATUS" ]] && echo
}

# Function to analyze dependencies recursively
analyze_dependencies() {
    local lib_file="$1"
    local extracted_root="$2"
    local main_analysis_dir="$3"
    local depth="$4"
    
    local lib_name
    lib_name=$(basename "$lib_file")
    update_status "Analyzing: $lib_name (Total processed: $TOTAL_DEPS_PROCESSED)"
    
    local deps
    deps=$(get_dependencies "$lib_file")
    [[ -z "$deps" ]] && return 0
    
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        [[ -n "${PROCESSED_LIBS[$dep]}" ]] && continue
        
        PROCESSED_LIBS["$dep"]=1
        local dep_paths=($(find_library "$dep" "$extracted_root"))
        
        if [[ ${#dep_paths[@]} -gt 0 ]]; then
            ((TOTAL_LIBS_FOUND+=${#dep_paths[@]}))
            ((TOTAL_DEPS_PROCESSED++))
            
            for dep_path in "${dep_paths[@]}"; do
                copy_with_structure "$dep_path" "$extracted_root" "$main_analysis_dir"
                analyze_dependencies "$dep_path" "$extracted_root" "$main_analysis_dir" $((depth + 1))
            done
        else
            add_missing_dep "$dep"
        fi
    done <<< "$deps"
}

# --- ORGANIZATIONAL UPDATE ---
# This function now saves BOTH the full suspected files in a cloned structure
# AND the summary snippet files for a quick overview.
find_and_copy_hal_files() {
    local hal_dir="$1"
    local extracted_root="$2"
    local -n libs_for_hal_analysis=$3
    
    print_info "Generating intelligent search pattern for HAL analysis..."
    
    local search_terms=()
    local excluded_pattern='^(lib|so|vendor|samsung|android|hardware|google|common|config|system|core|service|default|xml|rc|bin|etc|v[0-9]{1,2}|xml|name|type|version|target|level|entry|interface|permission|feature|value|path|key|hal|impl|so|jar|xml|rc|sh|conf|prop|txt|xml|bin|etc|lib32|lib64|x86|x86_64|arm|arm64|aarch64|user|debug|eng|soft|hard|product|odm|system_ext|framework|i[0-9]|v[0-9])$'

    for lib_name in "${!libs_for_hal_analysis[@]}"; do
        local words=($(echo "$lib_name" | sed 's/[._@-]/ /g' | tr ' ' '\n' | grep -vE "$excluded_pattern" | grep '...'))
        for word in "${words[@]}"; do
             if [[ ! "$word" =~ ^[0-9]+$ ]]; then
                search_terms+=("$word")
             fi
        done
        search_terms+=("$(basename "$lib_name" .so)")
    done
    
    local unique_terms=($(printf '%s\n' "${search_terms[@]}" | sort -u))
    if [[ ${#unique_terms[@]} -eq 0 ]]; then
        print_warning "Could not generate meaningful search terms. Skipping HAL analysis."
        return
    fi
    
    local lib_pattern=$(for term in "${unique_terms[@]}"; do echo -n "\\b${term}\\b|"; done | sed 's/|$//')
    print_info "Using intelligent search pattern: $lib_pattern"

    local manifest_snippets="$hal_dir/manifest_snippets.txt"
    local init_snippets="$hal_dir/init_snippets.txt"
    local selinux_snippets="$hal_dir/selinux_snippets.txt"
    local build_snippets="$hal_dir/build_snippets.txt"
    local config_snippets="$hal_dir/config_snippets.txt"

    # Helper to process a file if it matches the pattern
    process_file() {
        local file="$1"
        local pattern="$2"
        local subfolder="$3"
        local snippet_file="$4"

        local matches
        matches=$(grep -i -n -E "$pattern" "$file" 2>/dev/null)
        if [[ -n "$matches" ]]; then
            # Copy the full file into a cloned structure
            local rel_path
            rel_path=$(realpath --relative-to="$extracted_root" "$file")
            local target_dir="$hal_dir/$subfolder/$(dirname "$rel_path")"
            mkdir -p "$target_dir"
            cp "$file" "$target_dir/"

            # Append the matched lines to the snippet file
            echo -e "\n---[ Snippets from: $rel_path ]---\n" >> "$snippet_file"
            echo "$matches" >> "$snippet_file"
        fi
    }

    print_info "Analyzing manifest files (*.xml)..."
    find "$extracted_root/etc/vintf" -name "*.xml" -type f | while read file; do process_file "$file" "$lib_pattern" "manifests" "$manifest_snippets"; done
    
    print_info "Analyzing init script files (*.rc)..."
    find "$extracted_root" -name "*.rc" -type f | while read file; do process_file "$file" "$lib_pattern" "init_scripts" "$init_snippets"; done
    
    print_info "Analyzing SELinux policy files..."
    find "$extracted_root" -path "*/selinux/*" -type f | while read file; do process_file "$file" "$lib_pattern" "selinux" "$selinux_snippets"; done
    
    print_info "Analyzing build files (*.mk)..."
    find "$extracted_root" -name "*.mk" -type f | while read file; do process_file "$file" "$lib_pattern" "build_files" "$build_snippets"; done
    
    print_info "Analyzing configuration files from /etc..."
    find "$extracted_root/etc" -type f \( -name "*.xml" -o -name "*.conf" -o -name "*.config" \) | while read file; do process_file "$file" "$lib_pattern" "configs" "$config_snippets"; done
    
    # Clean up any empty snippet files
    for f in "$manifest_snippets" "$init_snippets" "$selinux_snippets" "$build_snippets" "$config_snippets"; do
        [[ ! -s "$f" ]] && rm -f "$f"
    done

    print_success "HAL analysis files saved in: $hal_dir"
}

# Function to generate references file for selected libraries
generate_references_file() {
    local main_analysis_dir="$1"
    local hal_analysis_dir="$2"
    local extracted_root="$3"
    local -n selected_libs_ref=$4
    local refs_dir="$main_analysis_dir/REFERENCES"
    local references_file="$refs_dir/REFERENCES.txt"
    local total_libs=${#selected_libs_ref[@]}
    local current_lib=0

    mkdir -p "$refs_dir"
    print_info "Starting deep analysis (fast mode)..."

    declare -A FILE_DEPS
    declare -A LIB_REFERENCES

    print_info "Indexing all ELF/shared object dependencies..."
    mapfile -t all_files < <(find "$extracted_root" -type f \( -executable -o -name "*.so*" \) 2>/dev/null)

    if command_exists parallel; then
        parallel --halt soon,fail=1 --jobs 0 '
            deps=$(objdump -p {} 2>/dev/null | grep -i "NEEDED" | awk "{print \$2}" | sort -u | tr "\n" " ")
            [ -n "$deps" ] && echo "{}:$deps"
        ' ::: "${all_files[@]}" > "$refs_dir/.deps_map"
    else
        > "$refs_dir/.deps_map"
        for file in "${all_files[@]}"; do
            (
                deps=$(objdump -p "$file" 2>/dev/null | grep -i "NEEDED" | awk '{print $2}' | sort -u | tr '\n' ' ')
                [ -n "$deps" ] && echo "$file:$deps"
            ) >> "$refs_dir/.deps_map" &
        done
        wait
    fi

    while IFS=: read -r file deps; do
        FILE_DEPS["$file"]="$deps"
        for dep in $deps; do
            LIB_REFERENCES["$dep"]+="$file "
        done
    done < "$refs_dir/.deps_map"

    {
        echo "Library References Report"
        echo "Generated on: $(date)"
        echo "========================================"
        echo
    } > "$references_file"

    for lib_name in "${!selected_libs_ref[@]}"; do
        ((current_lib++))
        update_status "Analyzing references: $lib_name ($current_lib of $total_libs)"
        
        {
            echo "-----------------------------------"
            echo "References of $lib_name"
            echo "-----------------------------------"
        } >> "$references_file"

        local lib_paths_str="${COPIED_LIBS_PATHS[$lib_name]}"
        IFS='|' read -ra lib_paths <<< "$lib_paths_str"
        
        echo "Analyzed variants:" >> "$references_file"
        for lib_path in "${lib_paths[@]}"; do
            local relative_path
            relative_path=$(realpath --relative-to="$extracted_root" "$lib_path")
            echo "  - $relative_path" >> "$references_file"
        done
        echo >> "$references_file"

        local found_refs=0
        for ref_file in ${LIB_REFERENCES["$lib_name"]}; do
            [[ "$(basename "$ref_file")" == "$lib_name" ]] && continue
            local relative_path
            relative_path=$(realpath --relative-to="$extracted_root" "$ref_file")
            echo "./$relative_path" >> "$references_file"
            copy_with_structure "$ref_file" "$extracted_root" "$main_analysis_dir" "true"
            found_refs=1
        done
        [[ $found_refs -eq 0 ]] && echo "No references found" >> "$references_file"
        echo >> "$references_file"
    done

    {
        echo "========================================"
        echo "End of References Report"
    } >> "$references_file"

    finalize_status
    print_success "References analysis completed! File saved to: $references_file"
    
    find_and_copy_hal_files "$hal_analysis_dir" "$extracted_root" selected_libs_ref
}

# Function to select libraries for deep analysis
select_libs_for_analysis() {
    local -n libs=$1
    
    if ! command_exists whiptail; then
        print_warning "whiptail not found. Proceeding with all libraries."
        return 0
    fi
    
    tput smcup
    
    local sorted_libs=($(printf '%s\n' "${!libs[@]}" | sort))
    
    local items=()
    for lib_name in "${sorted_libs[@]}"; do
        local lib_paths_str="${COPIED_LIBS_PATHS[$lib_name]}"
        local instance_count
        instance_count=$(echo "$lib_paths_str" | tr '|' '\n' | wc -l)
        
        if [[ $instance_count -gt 1 ]]; then
            items+=("$lib_name" "($instance_count instances found)" "ON")
        else
            items+=("$lib_name" "" "ON")
        fi
    done
    
    local term_height
    term_height=$(tput lines)
    local term_width
    term_width=$(tput cols)
    
    local dialog_width=$((term_width - 10))
    [[ $dialog_width -lt 60 ]] && dialog_width=60
    [[ $dialog_width -gt 120 ]] && dialog_width=120
    
    local dialog_height=$((term_height - 8))
    [[ $dialog_height -lt 15 ]] && dialog_height=15
    [[ $dialog_height -gt 40 ]] && dialog_height=40
    
    local list_height=$((dialog_height - 8))
    
    local selected_libs
    selected_libs=$(TERM=ansi whiptail --title "Select Libraries for Deep Analysis" \
        --checklist "Use SPACE to toggle, ENTER to confirm" \
        $dialog_height $dialog_width $list_height \
        "${items[@]}" \
        3>&1 1>&2 2>&3)
    local return_code=$?
    
    tput rmcup
    
    if [[ $return_code -ne 0 ]]; then
        print_warning "Selection cancelled. Skipping deep analysis."
        return 1
    fi
    
    declare -A selected
    for lib in $selected_libs; do
        lib=$(echo "$lib" | tr -d '"')
        selected["$lib"]=1
    done
    
    for lib in "${!libs[@]}"; do
        [[ -z "${selected[$lib]}" ]] && unset libs["$lib"]
    done
    
    return 0
}

# Function to check if system is Debian/Ubuntu based
is_debian_based() {
    [[ -f /etc/debian_version ]] || command -v apt-get >/dev/null 2>&1
}

# Function to check and install required commands
check_and_install_commands() {
    declare -A cmd_pkg=(
        ["objdump"]="binutils"
        ["tree"]="tree"
        ["whiptail"]="whiptail"
    )
    local missing_pkgs=()
    for cmd in "${!cmd_pkg[@]}"; do
        if ! command_exists "$cmd"; then
            missing_pkgs+=("${cmd_pkg[$cmd]}")
        fi
    done
    if [ ${#missing_pkgs[@]} -eq 0 ]; then
        return 0
    fi
    
    local unique_pkgs
    unique_pkgs=$(printf "%s\n" "${missing_pkgs[@]}" | sort -u | tr '\n' ' ')
    print_warning "Some required packages are missing: $unique_pkgs"
    read -p "Do you want to install them? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Installing missing packages..."
        if sudo apt-get update && sudo apt-get install -y $unique_pkgs; then
            print_success "Successfully installed required packages!"
        else
            print_error "Failed to install some packages."
        fi
    else
        print_warning "Proceeding without installing packages."
    fi
}

# Main function
main() {
    print_info "Enhanced HAL Dependency Analyzer"
    print_info "======================================"
    echo

    if is_debian_based; then
        check_and_install_commands
    else
        print_warning "Not a Debian/Ubuntu based system. Please ensure required packages are installed manually."
    fi

    if ! command_exists objdump; then
        print_error "objdump command not found. Please install binutils package."
        exit 1
    fi

    while true; do
        read -p "Enter the path to the library file: " lib_file_input
        lib_file=$(clean_path "$lib_file_input")
        if [[ -f "$lib_file" ]]; then
            lib_file=$(realpath "$lib_file")
            break
        else
            print_error "File not found: $lib_file"
        fi
    done
    
    while true; do
        read -p "Enter the path to the extracted image root folder: " extracted_root_input
        extracted_root=$(clean_path "$extracted_root_input")
        if [[ -d "$extracted_root" ]]; then
            extracted_root=$(realpath "$extracted_root")
            break
        else
            print_error "Directory not found: $extracted_root"
        fi
    done
    
    while true; do
        read -p "Enter the path for all outputs: " output_root_input
        output_root=$(clean_path "$output_root_input")
        if [[ ! -e "$output_root" ]]; then
            mkdir -p "$output_root" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                output_root=$(realpath "$output_root")
                break
            else
                print_error "Cannot create directory: $output_root"
            fi
        elif [[ -d "$output_root" ]]; then
            output_root=$(realpath "$output_root")
            read -p "Output directory exists. Overwrite contents? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                # Clean the directories to avoid old results
                rm -rf "$output_root/MAIN_ANALYSIS" "$output_root/HAL_ANALYSIS"
                break
            fi
        else
            print_error "Path exists but is not a directory: $output_root"
        fi
    done
    
    # --- ORGANIZATIONAL UPDATE ---
    local main_analysis_dir="$output_root/MAIN_ANALYSIS"
    local hal_analysis_dir="$output_root/HAL_ANALYSIS"
    mkdir -p "$main_analysis_dir" "$hal_analysis_dir"
    
    echo
    print_info "Configuration:"
    print_info "Library file: $lib_file"
    print_info "Extracted root: $extracted_root"
    print_info "Main analysis output: $main_analysis_dir"
    print_info "HAL analysis output: $hal_analysis_dir"
    echo
    
    read -p "Proceed with dependency analysis? (Y/n): " proceed
    if [[ "$proceed" =~ ^[Nn]$ ]]; then
        print_info "Operation cancelled."
        exit 0
    fi
    
    echo
    print_info "Starting dependency analysis..."
    
    is_main_lib=1
    copy_with_structure "$lib_file" "$extracted_root" "$main_analysis_dir"
    PROCESSED_LIBS[$(basename "$lib_file")]=1
    
    ((TOTAL_LIBS_FOUND++))
    analyze_dependencies "$lib_file" "$extracted_root" "$main_analysis_dir" 0
    finalize_status
    
    echo
    print_success "Dependency analysis completed!"
    print_info "Total libraries processed: $TOTAL_DEPS_PROCESSED"
    print_info "Total library instances found: $TOTAL_LIBS_FOUND"
    echo
    
    read -p "Do you want to deep analyze for references and HAL configurations? (y/N): " analyze_refs
    if [[ "$analyze_refs" =~ ^[Yy]$ ]]; then
        declare -A SELECTED_LIBS
        for k in "${!COPIED_LIBS[@]}"; do
            SELECTED_LIBS[$k]=${COPIED_LIBS[$k]}
        done
        
        if select_libs_for_analysis SELECTED_LIBS; then
            if [[ ${#SELECTED_LIBS[@]} -gt 0 ]]; then
                generate_references_file "$main_analysis_dir" "$hal_analysis_dir" "$extracted_root" SELECTED_LIBS
            else
                print_warning "No libraries selected for analysis."
            fi
        fi
        echo
    else
        print_info "Skipping references and HAL analysis."
        echo
    fi
    
    print_info "Summary of all output files:"
    local summary_tree_file="$output_root/output_summary_tree.txt"
    if command_exists tree; then
        tree "$output_root" | tee "$summary_tree_file"
    else
        print_warning "tree command not found. Using 'find' for a basic list."
        find "$output_root" -print | sed -e "s;$output_root;.;" -e "s;[^/]*;;g;s;/[^/]*;/-- ;g;s;-- |; |;s;-- ;|-- ;" | tee "$summary_tree_file"
    fi
    print_success "Full output summary saved to: $summary_tree_file"
    echo
    
    if [[ -n "$MISSING_DEPS" ]]; then
        local unique_missing=$(echo "$MISSING_DEPS" | sort -u)
        local missing_count=$(echo "$unique_missing" | wc -l)
        local missing_deps_file="$output_root/missing_deps.txt"
        echo "$unique_missing" > "$missing_deps_file"
        print_warning "$missing_count missing dependencies found. List saved to: $missing_deps_file"
        echo -e "${YELLOW}--- Missing Libraries ---${NC}"
        echo "$unique_missing"
        echo -e "${YELLOW}-------------------------${NC}"
    else
        print_success "All dependencies were found and copied!"
    fi
    
    echo
    print_info "Operation finished. All files are in: $output_root"
    if [[ "$analyze_refs" =~ ^[Yy]$ ]]; then
        print_info "Check MAIN_ANALYSIS/REFERENCES.txt for library usage information."
        print_info "Check HAL_ANALYSIS/ for suspected configuration files and snippets."
    fi
}

# Run main function
main "$@"
