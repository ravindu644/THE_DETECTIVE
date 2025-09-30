#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
declare -A PROCESSED_PATHS
declare -A PROCESSED_SONAMES
declare -A PROCESSED_LIBS
declare -A COPIED_LIBS
declare -A COPIED_LIBS_PATHS
declare -A APPROVED_LIBS      # Libraries user wants to analyze
declare -A REJECTED_LIBS      # Libraries user explicitly rejected
declare -A PENDING_ANALYSIS   # New libraries found in current iteration
MISSING_DEPS=""
COPIED_LIBS_FALLBACK=""
PROCESSED_LIBS_FALLBACK=""

# State files
STATE_FILE=""
APPROVED_STATE_FILE=""
REJECTED_STATE_FILE=""

# Helper functions
set_copied_lib() {
    local key="$1"
    if (declare -p COPIED_LIBS >/dev/null 2>&1); then
        COPIED_LIBS["$key"]=1
    else
        COPIED_LIBS_FALLBACK="${COPIED_LIBS_FALLBACK:+$COPIED_LIBS_FALLBACK$'\n'}$key"
    fi
}

copied_libs_keys() {
    if (declare -p COPIED_LIBS >/dev/null 2>&1); then
        printf '%s\n' "${!COPIED_LIBS[@]}"
    else
        printf '%s\n' "$COPIED_LIBS_FALLBACK" | sed '/^$/d'
    fi
}

set_processed_soname() {
    local key="$1"
    if (declare -p PROCESSED_LIBS >/dev/null 2>&1); then
        PROCESSED_LIBS["$key"]=1
    else
        PROCESSED_LIBS_FALLBACK="${PROCESSED_LIBS_FALLBACK:+$PROCESSED_LIBS_FALLBACK$'\n'}$key"
    fi
}

processed_sonames_keys() {
    if (declare -p PROCESSED_LIBS >/dev/null 2>&1); then
        printf '%s\n' "${!PROCESSED_LIBS[@]}"
    else
        printf '%s\n' "$PROCESSED_LIBS_FALLBACK" | sed '/^$/d'
    fi
}

# Additional global variables for statistics
TOTAL_LIBS_FOUND=0
TOTAL_DEPS_PROCESSED=0
CURRENT_STATUS=""
GRAPH_EDGES_FILE=""
FIRST_BINARY_DONE=false

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
    input=$(echo "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ "$input" =~ ^\".*\"$ ]] || [[ "$input" =~ ^\'.*\'$ ]]; then
        input="${input#?}"
        input="${input%?}"
    fi
    input="${input/#\~/$HOME}"
    echo "$input"
}

# Function to find all instances of a library file
find_library() {
    local lib_name="$1"
    local search_path="$2"
    find "$search_path" -type f -name "$lib_name" 2>/dev/null
}

# Function to get dependencies of a library
get_dependencies() {
    local lib_file="$1"
    [[ ! -f "$lib_file" ]] && return 1
    objdump -p "$lib_file" 2>/dev/null | grep -i "NEEDED" | awk '{print $2}' | sort -u
}

# Extract DT_RPATH and DT_RUNPATH entries
parse_runpaths() {
    local lib_file="$1"
    objdump -p "$lib_file" 2>/dev/null | awk '/RPATH|RUNPATH/ {for(i=2;i<=NF;i++) printf "%s ", $i; print ""}' | tr ' ' '\n' | sed '/^$/d' | tr ':' '\n' | sed '/^$/d'
}

# Resolve a soname using runpath hints first
resolve_soname() {
    local soname="$1"
    local referencing_file="$2"
    local extracted_root="$3"

    local runpaths
    runpaths=$(parse_runpaths "$referencing_file" 2>/dev/null)
    if [[ -n "$runpaths" ]]; then
        while IFS= read -r rp; do
            [[ -z "$rp" ]] && continue
            rp_expanded=${rp/#\$ORIGIN/$(dirname "$referencing_file")}
            if [[ "$rp_expanded" != /* ]]; then
                rp_expanded="$extracted_root/$rp_expanded"
            fi
            candidate="$rp_expanded/$soname"
            if [[ -f "$candidate" ]]; then
                echo "$candidate"
                return 0
            fi
        done <<< "$runpaths"
    fi

    find "$extracted_root" -type f -name "$soname" 2>/dev/null
}

# Emit an edge to the dependency DOT file
emit_graph_edge() {
    local from="$1"
    local to="$2"
    [[ -z "$GRAPH_EDGES_FILE" ]] && return
    echo "\"$from\" -> \"$to\";" >> "$GRAPH_EDGES_FILE"
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
        set_copied_lib "$lib_name"
        
        if [[ -z "${COPIED_LIBS_PATHS[$lib_name]}" ]]; then
            COPIED_LIBS_PATHS["$lib_name"]="$source_file"
        else
            COPIED_LIBS_PATHS["$lib_name"]="${COPIED_LIBS_PATHS[$lib_name]}|$source_file"
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

# Function to finalize status
finalize_status() {
    [[ -n "$CURRENT_STATUS" ]] && echo
}

# Check if library should be analyzed based on state
should_analyze_library() {
    local lib_name="$1"
    
    # If explicitly rejected, never analyze
    if [[ -n "${REJECTED_LIBS[$lib_name]}" ]]; then
        return 1
    fi
    
    # If already approved, always analyze
    if [[ -n "${APPROVED_LIBS[$lib_name]}" ]]; then
        return 0
    fi
    
    # New library - add to pending
    PENDING_ANALYSIS[$lib_name]=1
    return 2  # Special code: needs user decision
}

# Function to analyze dependencies recursively with approval checks
analyze_dependencies() {
    local lib_file="$1"
    local extracted_root="$2"
    local main_analysis_dir="$3"
    local depth="$4"
    
    local lib_name
    lib_name=$(basename "$lib_file")
    
    # Check if this library should be analyzed
    should_analyze_library "$lib_name"
    local should_analyze=$?
    
    if [[ $should_analyze -eq 1 ]]; then
        # Rejected - skip entirely
        return 0
    fi
    
    update_status "Analyzing: $lib_name (Total processed: $TOTAL_DEPS_PROCESSED)"

    local abs_path
    abs_path=$(realpath -e "$lib_file" 2>/dev/null || realpath -m "$lib_file")
    if [[ -n "${PROCESSED_PATHS[$abs_path]}" ]]; then
        return 0
    fi
    PROCESSED_PATHS["$abs_path"]=1

    local deps
    deps=$(get_dependencies "$lib_file")
    [[ -z "$deps" ]] && return 0

    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        
        # Check if dependency should be analyzed
        should_analyze_library "$dep"
        local dep_should_analyze=$?
        
        if [[ $dep_should_analyze -eq 1 ]]; then
            # Rejected - skip this dependency
            continue
        fi

        mapfile -t dep_paths_arr < <(resolve_soname "$dep" "$lib_file" "$extracted_root")

        if [[ ${#dep_paths_arr[@]} -gt 0 ]]; then
            ((TOTAL_LIBS_FOUND+=${#dep_paths_arr[@]}))
            ((TOTAL_DEPS_PROCESSED++))

            for dep_path in "${dep_paths_arr[@]}"; do
                emit_graph_edge "$abs_path" "$dep_path"

                dep_realpath=$(realpath -m "$dep_path" 2>/dev/null || printf "%s" "$dep_path")
                if [[ -z "${PROCESSED_PATHS[$dep_realpath]}" ]]; then
                    copy_with_structure "$dep_path" "$extracted_root" "$main_analysis_dir"
                    
                    # Only recurse if approved or pending (not rejected)
                    if [[ $dep_should_analyze -ne 1 ]]; then
                        analyze_dependencies "$dep_path" "$extracted_root" "$main_analysis_dir" $((depth + 1))
                    fi
                else
                    copy_with_structure "$dep_path" "$extracted_root" "$main_analysis_dir"
                fi
            done
        else
            add_missing_dep "$dep"
        fi
    done <<< "$deps"
}

# Load approved libraries from state file
load_approved_libs() {
    local file="$APPROVED_STATE_FILE"
    [[ ! -f "$file" ]] && return
    while IFS= read -r lib; do
        [[ -z "$lib" ]] && continue
        APPROVED_LIBS["$lib"]=1
    done < "$file"
}

# Load rejected libraries from state file
load_rejected_libs() {
    local file="$REJECTED_STATE_FILE"
    [[ ! -f "$file" ]] && return
    while IFS= read -r lib; do
        [[ -z "$lib" ]] && continue
        REJECTED_LIBS["$lib"]=1
    done < "$file"
}

# Save approved libraries to state file
save_approved_libs() {
    local file="$APPROVED_STATE_FILE"
    > "$file"
    for lib in "${!APPROVED_LIBS[@]}"; do
        echo "$lib" >> "$file"
    done
}

# Save rejected libraries to state file
save_rejected_libs() {
    local file="$REJECTED_STATE_FILE"
    > "$file"
    for lib in "${!REJECTED_LIBS[@]}"; do
        echo "$lib" >> "$file"
    done
}

# Function to select libraries - only shows NEW libraries
select_new_libraries() {
    if ! command_exists whiptail; then
        print_warning "whiptail not found. Auto-approving all new libraries."
        for lib in "${!PENDING_ANALYSIS[@]}"; do
            APPROVED_LIBS["$lib"]=1
        done
        return 0
    fi
    
    if [[ ${#PENDING_ANALYSIS[@]} -eq 0 ]]; then
        print_info "No new libraries to review."
        return 0
    fi
    
    local sorted_libs=($(printf '%s\n' "${!PENDING_ANALYSIS[@]}" | sort))
    
    local items=()
    for lib_name in "${sorted_libs[@]}"; do
        local lib_paths_str="${COPIED_LIBS_PATHS[$lib_name]}"
        local instance_count
        instance_count=$(echo "$lib_paths_str" | tr '|' '\n' | wc -l)
        
        if [[ $instance_count -gt 1 ]]; then
            items+=("$lib_name" "($instance_count instances)" "ON")
        else
            items+=("$lib_name" "" "ON")
        fi
    done
    
    local term_height=$(tput lines)
    local term_width=$(tput cols)
    
    local dialog_width=$((term_width - 10))
    [[ $dialog_width -lt 60 ]] && dialog_width=60
    [[ $dialog_width -gt 120 ]] && dialog_width=120
    
    local dialog_height=$((term_height - 8))
    [[ $dialog_height -lt 15 ]] && dialog_height=15
    [[ $dialog_height -gt 40 ]] && dialog_height=40
    
    local list_height=$((dialog_height - 8))
    
    local selected_libs
    selected_libs=$(whiptail --title "Select Libraries for Deep Analysis" \
        --checklist "NEW libraries found. Use SPACE to toggle, ENTER to confirm.\nDeselected libraries will be PERMANENTLY ignored." \
        $dialog_height $dialog_width $list_height \
        "${items[@]}" \
        3>&1 1>&2 2>&3)
    local return_code=$?
    
    if [[ $return_code -ne 0 ]]; then
        print_warning "Selection cancelled. Auto-approving all new libraries."
        for lib in "${!PENDING_ANALYSIS[@]}"; do
            APPROVED_LIBS["$lib"]=1
        done
        return 0
    fi
    
    # Parse selected libraries
    declare -A selected
    for lib in $selected_libs; do
        lib=$(echo "$lib" | tr -d '"')
        selected["$lib"]=1
    done
    
    # Update approved and rejected lists
    for lib in "${!PENDING_ANALYSIS[@]}"; do
        if [[ -n "${selected[$lib]}" ]]; then
            APPROVED_LIBS["$lib"]=1
        else
            REJECTED_LIBS["$lib"]=1
            print_info "Permanently rejecting: $lib"
        fi
    done
    
    # Save state immediately
    save_approved_libs
    save_rejected_libs
    
    print_success "Selection saved. Approved: ${#APPROVED_LIBS[@]}, Rejected: ${#REJECTED_LIBS[@]}"
    
    # Clear pending
    PENDING_ANALYSIS=()
}

# HAL analysis function
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
    print_info "Using search pattern with ${#unique_terms[@]} terms"

    local manifest_snippets="$hal_dir/manifest_snippets.txt"
    local init_snippets="$hal_dir/init_snippets.txt"
    local selinux_snippets="$hal_dir/selinux_snippets.txt"
    local build_snippets="$hal_dir/build_snippets.txt"
    local config_snippets="$hal_dir/config_snippets.txt"

    process_file() {
        local file="$1"
        local pattern="$2"
        local subfolder="$3"
        local snippet_file="$4"

        local matches
        matches=$(grep -i -n -E "$pattern" "$file" 2>/dev/null)
        if [[ -n "$matches" ]]; then
            local rel_path
            rel_path=$(realpath --relative-to="$extracted_root" "$file")
            local target_dir="$hal_dir/$subfolder/$(dirname "$rel_path")"
            mkdir -p "$target_dir"
            cp "$file" "$target_dir/"

            echo -e "\n---[ Snippets from: $rel_path ]---\n" >> "$snippet_file"
            echo "$matches" >> "$snippet_file"
        fi
    }

    print_info "Analyzing manifest files..."
    find "$extracted_root/etc/vintf" -name "*.xml" -type f 2>/dev/null | while read file; do process_file "$file" "$lib_pattern" "manifests" "$manifest_snippets"; done
    
    print_info "Analyzing init scripts..."
    find "$extracted_root" -name "*.rc" -type f 2>/dev/null | while read file; do process_file "$file" "$lib_pattern" "init_scripts" "$init_snippets"; done
    
    print_info "Analyzing SELinux policies..."
    find "$extracted_root" -path "*/selinux/*" -type f 2>/dev/null | while read file; do process_file "$file" "$lib_pattern" "selinux" "$selinux_snippets"; done
    
    print_info "Analyzing build files..."
    find "$extracted_root" -name "*.mk" -type f 2>/dev/null | while read file; do process_file "$file" "$lib_pattern" "build_files" "$build_snippets"; done
    
    print_info "Analyzing config files..."
    find "$extracted_root/etc" -type f \( -name "*.xml" -o -name "*.conf" -o -name "*.config" \) 2>/dev/null | while read file; do process_file "$file" "$lib_pattern" "configs" "$config_snippets"; done
    
    for f in "$manifest_snippets" "$init_snippets" "$selinux_snippets" "$build_snippets" "$config_snippets"; do
        [[ ! -s "$f" ]] && rm -f "$f"
    done

    print_success "HAL analysis complete: $hal_dir"
}

# Generate references file
generate_references_file() {
    local main_analysis_dir="$1"
    local hal_analysis_dir="$2"
    local extracted_root="$3"
    
    local refs_dir="$main_analysis_dir/REFERENCES"
    local references_file="$refs_dir/REFERENCES.txt"
    
    mkdir -p "$refs_dir"
    print_info "Starting deep reference analysis..."

    declare -A FILE_DEPS
    declare -A LIB_REFERENCES

    print_info "Indexing all ELF dependencies..."
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

    local total_approved=${#APPROVED_LIBS[@]}
    local current=0
    
    for lib_name in "${!APPROVED_LIBS[@]}"; do
        ((current++))
        update_status "Analyzing references: $lib_name ($current/$total_approved)"
        
        {
            echo "-----------------------------------"
            echo "References of $lib_name"
            echo "-----------------------------------"
        } >> "$references_file"

        local lib_paths_str="${COPIED_LIBS_PATHS[$lib_name]}"
        if [[ -n "$lib_paths_str" ]]; then
            IFS='|' read -ra lib_paths <<< "$lib_paths_str"
            
            echo "Analyzed variants:" >> "$references_file"
            for lib_path in "${lib_paths[@]}"; do
                local relative_path
                relative_path=$(realpath --relative-to="$extracted_root" "$lib_path")
                echo "  - $relative_path" >> "$references_file"
            done
            echo >> "$references_file"
        fi

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
    print_success "References analysis complete: $references_file"
    
    find_and_copy_hal_files "$hal_analysis_dir" "$extracted_root" APPROVED_LIBS
}

# Check if system is Debian/Ubuntu based
is_debian_based() {
    [[ -f /etc/debian_version ]] || command -v apt-get >/dev/null 2>&1
}

# Check and install required commands
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
    print_warning "Missing packages: $unique_pkgs"
    read -p "Install them? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Installing packages..."
        if sudo apt-get update && sudo apt-get install -y $unique_pkgs; then
            print_success "Packages installed!"
        else
            print_error "Installation failed."
        fi
    fi
}

# Main function
main() {
    print_info "Enhanced HAL Dependency Analyzer"
    print_info "======================================"
    echo

    if is_debian_based; then
        check_and_install_commands
    fi

    if ! command_exists objdump; then
        print_error "objdump not found. Install binutils."
        exit 1
    fi

    echo "Select operation mode:"
    echo "  1) Single library/binary analysis"
    echo "  2) Batch analysis from text file"
    echo

    read -p "Choose mode (1/2): " mode_choice
    
    if [[ "$mode_choice" != "1" && "$mode_choice" != "2" ]]; then
        print_error "Invalid choice. Choose 1 or 2."
        exit 1
    fi

    local lib_file=""
    local suspects_file=""
    
    if [[ "$mode_choice" == "1" ]]; then
        # Single library mode
        while true; do
            read -p "Enter path to library/binary file: " lib_file_input
            lib_file=$(clean_path "$lib_file_input")
            if [[ -f "$lib_file" ]]; then
                lib_file=$(realpath "$lib_file")
                break
            else
                print_error "File not found: $lib_file"
            fi
        done
    else
        # Batch mode
        while true; do
            read -p "Enter path to suspects file: " suspects_input
            suspects_file=$(clean_path "$suspects_input")
            if [[ -f "$suspects_file" ]]; then
                suspects_file=$(realpath "$suspects_file")
                break
            else
                print_error "File not found: $suspects_file"
            fi
        done
    fi
    
    local extracted_root
    while true; do
        read -p "Enter extracted image root path: " extracted_root_input
        extracted_root=$(clean_path "$extracted_root_input")
        if [[ -d "$extracted_root" ]]; then
            extracted_root=$(realpath "$extracted_root")
            break
        else
            print_error "Directory not found: $extracted_root"
        fi
    done
    
    local output_root
    while true; do
        read -p "Enter output path: " output_root_input
        output_root=$(clean_path "$output_root_input")
        if [[ ! -e "$output_root" ]]; then
            mkdir -p "$output_root" 2>/dev/null
            if [[ $? -eq 0 ]]; then
                output_root=$(realpath "$output_root")
                break
            else
                print_error "Cannot create: $output_root"
            fi
        elif [[ -d "$output_root" ]]; then
            output_root=$(realpath "$output_root")
            break
        else
            print_error "Path exists but not a directory: $output_root"
        fi
    done
    
    # Set state file paths
    APPROVED_STATE_FILE="$output_root/.approved_libs.txt"
    REJECTED_STATE_FILE="$output_root/.rejected_libs.txt"
    
    # Load existing state
    load_approved_libs
    load_rejected_libs
    
    if [[ ${#APPROVED_LIBS[@]} -gt 0 ]] || [[ ${#REJECTED_LIBS[@]} -gt 0 ]]; then
        print_info "Loaded state: ${#APPROVED_LIBS[@]} approved, ${#REJECTED_LIBS[@]} rejected"
    fi
    
    local main_analysis_dir="$output_root/MAIN_ANALYSIS"
    local hal_analysis_dir="$output_root/HAL_ANALYSIS"
    mkdir -p "$main_analysis_dir" "$hal_analysis_dir"
    
    echo
    print_info "Configuration:"
    if [[ "$mode_choice" == "1" ]]; then
        print_info "Mode: Single library analysis"
        print_info "Library: $lib_file"
    else
        print_info "Mode: Batch analysis"
        print_info "Suspects file: $suspects_file"
    fi
    print_info "Extracted root: $extracted_root"
    print_info "Output root: $output_root"
    echo
    
    read -p "Proceed? (Y/n): " proceed
    if [[ "$proceed" =~ ^[Nn]$ ]]; then
        exit 0
    fi
    
    GRAPH_EDGES_FILE="$main_analysis_dir/dependency_graph.dot"
    echo "digraph dependencies {" > "$GRAPH_EDGES_FILE"
    
    if [[ "$mode_choice" == "1" ]]; then
        # Single library mode
        print_info "Analyzing single library: $(basename "$lib_file")"
        
        copy_with_structure "$lib_file" "$extracted_root" "$main_analysis_dir"
        local lib_name=$(basename "$lib_file")
        set_processed_soname "$lib_name"
        APPROVED_LIBS["$lib_name"]=1
        
        ((TOTAL_LIBS_FOUND++))
        analyze_dependencies "$lib_file" "$extracted_root" "$main_analysis_dir" 0
        finalize_status
        
        # Prompt for new libraries found
        if [[ ${#PENDING_ANALYSIS[@]} -gt 0 ]]; then
            print_info "Found ${#PENDING_ANALYSIS[@]} dependencies."
            select_new_libraries
            
            # Re-analyze with selections
            print_info "Re-analyzing with your selections..."
            PROCESSED_PATHS=()
            TOTAL_DEPS_PROCESSED=0
            analyze_dependencies "$lib_file" "$extracted_root" "$main_analysis_dir" 0
            finalize_status
        fi
        
    else
        # Batch mode
        local idx=0
        
        while IFS= read -r line || [[ -n "$line" ]]; do
            line=$(clean_path "$line")
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^# ]] && continue
            
            if [[ ! -f "$line" ]]; then
                print_warning "Not found: $line"
                continue
            fi
            
            ((idx++))
            print_info "Processing binary [$idx]: $line"
            
            # Copy and analyze
            copy_with_structure "$line" "$extracted_root" "$main_analysis_dir"
            local lib_name=$(basename "$line")
            set_processed_soname "$lib_name"
            
            # Mark main binary as approved automatically
            APPROVED_LIBS["$lib_name"]=1
            
            ((TOTAL_LIBS_FOUND++))
            analyze_dependencies "$line" "$extracted_root" "$main_analysis_dir" 0
            finalize_status
            
            # Only prompt ONCE after first binary
            if [[ "$FIRST_BINARY_DONE" == "false" ]]; then
                FIRST_BINARY_DONE=true
                
                if [[ ${#PENDING_ANALYSIS[@]} -gt 0 ]]; then
                    print_info "Found ${#PENDING_ANALYSIS[@]} new libraries from first binary."
                    select_new_libraries
                    
                    # Re-analyze first binary with approved/rejected state
                    print_info "Re-analyzing first binary with your selections..."
                    PROCESSED_PATHS=()
                    TOTAL_DEPS_PROCESSED=0
                    analyze_dependencies "$line" "$extracted_root" "$main_analysis_dir" 0
                    finalize_status
                fi
            else
                # For subsequent binaries, check for new libraries
                if [[ ${#PENDING_ANALYSIS[@]} -gt 0 ]]; then
                    print_info "Found ${#PENDING_ANALYSIS[@]} NEW libraries from binary [$idx]."
                    select_new_libraries
                    
                    # Re-analyze this binary with updated state
                    print_info "Re-analyzing binary [$idx] with selections..."
                    PROCESSED_PATHS=()
                    TOTAL_DEPS_PROCESSED=0
                    analyze_dependencies "$line" "$extracted_root" "$main_analysis_dir" 0
                    finalize_status
                fi
            fi
            
        done < "$suspects_file"
    fi
    
    echo "}" >> "$GRAPH_EDGES_FILE"
    print_success "Dependency graph: $GRAPH_EDGES_FILE"
    
    echo
    print_success "Analysis complete!"
    print_info "Total libraries processed: $TOTAL_DEPS_PROCESSED"
    print_info "Total instances found: $TOTAL_LIBS_FOUND"
    print_info "Approved libraries: ${#APPROVED_LIBS[@]}"
    print_info "Rejected libraries: ${#REJECTED_LIBS[@]}"
    echo
    
    # Generate references and HAL analysis for approved libs only
    if [[ ${#APPROVED_LIBS[@]} -gt 0 ]]; then
        generate_references_file "$main_analysis_dir" "$hal_analysis_dir" "$extracted_root"
    else
        print_info "No approved libraries. Skipping deep analysis."
    fi
    
    print_info "Output summary:"
    local summary_tree_file="$output_root/output_summary_tree.txt"
    if command_exists tree; then
        tree "$output_root" | tee "$summary_tree_file"
    else
        find "$output_root" -print | sed -e "s;$output_root;.;" -e "s;[^/]*;;g;s;/[^/]*;/-- ;g;s;-- |; |;s;-- ;|-- ;" | tee "$summary_tree_file"
    fi
    print_success "Summary saved: $summary_tree_file"
    echo
    
    if [[ -n "$MISSING_DEPS" ]]; then
        local unique_missing=$(echo "$MISSING_DEPS" | sort -u)
        local missing_count=$(echo "$unique_missing" | wc -l)
        local missing_deps_file="$output_root/missing_deps.txt"
        echo "$unique_missing" > "$missing_deps_file"
        print_warning "$missing_count missing dependencies: $missing_deps_file"
        echo -e "${YELLOW}--- Missing Libraries ---${NC}"
        echo "$unique_missing"
        echo -e "${YELLOW}-------------------------${NC}"
    else
        print_success "All dependencies found!"
    fi
    
    echo
    print_success "Complete! All output in: $output_root"
    print_info "State files:"
    print_info "  Approved: $APPROVED_STATE_FILE"
    print_info "  Rejected: $REJECTED_STATE_FILE"
    echo
    print_info "To reset state, delete these files manually."
}

# Run main
main "$@"
