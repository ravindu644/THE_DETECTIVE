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
    
    # Get relative path from extracted root
    local relative_path=$(realpath --relative-to="$extracted_root" "$source_file")
    local target_path="$output_root/$relative_path"
    local target_dir=$(dirname "$target_path")
    
    # Create target directory if it doesn't exist
    mkdir -p "$target_dir"
    
    # Copy the file
    if cp "$source_file" "$target_path" 2>/dev/null; then
        # Track copied libraries
        COPIED_LIBS[$(basename "$source_file")]=1
        
        # Only print success on the first copy of the main lib
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
    echo -en "\r\033[K[INFO] $status"  # Clear line and show new status
}

# Function to finalize status (move to next line)
finalize_status() {
    [[ -n "$CURRENT_STATUS" ]] && echo
}

# Function to analyze dependencies recursively
analyze_dependencies() {
    local lib_file="$1"
    local extracted_root="$2"
    local output_root="$3"
    local depth="$4"
    
    local lib_name=$(basename "$lib_file")
    update_status "Analyzing: $lib_name (Total processed: $TOTAL_DEPS_PROCESSED)"
    
    local deps=$(get_dependencies "$lib_file")
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
                copy_with_structure "$dep_path" "$extracted_root" "$output_root"
                analyze_dependencies "$dep_path" "$extracted_root" "$output_root" $((depth + 1))
            done
        else
            add_missing_dep "$dep"
        fi
    done <<< "$deps"
}

# Function to generate references file
generate_references_file() {
    local output_root="$1"
    local extracted_root="$2"
    local references_file="$output_root/REFERENCES.txt"
    local total_libs=${#COPIED_LIBS[@]}
    local current_lib=0
    
    print_info "Starting deep analysis..."
    
    # Start file with headers
    {
        echo "Library References Report"
        echo "Generated on: $(date)"
        echo "========================================"
        echo
    } > "$references_file"
    
    # Process each library
    for lib_name in "${!COPIED_LIBS[@]}"; do
        ((current_lib++))
        update_status "Analyzing references: $lib_name ($current_lib of $total_libs)"
        
        {
            echo "-----------------------------------"
            echo "References of $lib_name"
            echo "-----------------------------------"
        } >> "$references_file"
        
        # Find references
        local found_refs=0
        while IFS= read -r -d '' file; do
            [[ "$(basename "$file")" == "$lib_name" ]] && continue
            local deps=$(get_dependencies "$file" 2>/dev/null)
            if [[ -n "$deps" ]] && echo "$deps" | grep -q "^$lib_name$"; then
                local relative_path=$(realpath --relative-to="$extracted_root" "$file")
                echo "./$relative_path" >> "$references_file"
                found_refs=1
            fi
        done < <(find "$extracted_root" -type f \( -executable -o -name "*.so*" \) -print0 2>/dev/null)
        
        [[ $found_refs -eq 0 ]] && echo "No references found" >> "$references_file"
        echo >> "$references_file"
    done
    
    # Add footer to file
    {
        echo "========================================"
        echo "End of References Report"
    } >> "$references_file"
    
    finalize_status
    print_success "References analysis completed! File saved to: $references_file"
}

# Main function
main() {
    print_info "Library Dependency Analyzer"
    print_info "================================"
    echo
    
    # Check required commands
    if ! command_exists objdump; then
        print_error "objdump command not found. Please install binutils package."
        exit 1
    fi
    
    # Get input library file
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
    
    # Get extracted image root folder
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
    
    # Get output folder
    while true; do
        read -p "Enter the path to save the output: " output_root_input
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
            read -p "Output directory exists. Overwrite files? (y/N): " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                break
            fi
        else
            print_error "Path exists but is not a directory: $output_root"
        fi
    done
    
    echo
    print_info "Configuration:"
    print_info "Library file: $lib_file"
    print_info "Extracted root: $extracted_root"
    print_info "Output root: $output_root"
    echo
    
    # Confirm before proceeding
    read -p "Proceed with dependency analysis? (Y/n): " proceed
    if [[ "$proceed" =~ ^[Nn]$ ]]; then
        print_info "Operation cancelled."
        exit 0
    fi
    
    echo
    print_info "Starting dependency analysis..."
    
    # First, copy the main library file
    is_main_lib=1
    copy_with_structure "$lib_file" "$extracted_root" "$output_root"
    PROCESSED_LIBS[$(basename "$lib_file")]=1
    
    # Start recursive dependency analysis
    ((TOTAL_LIBS_FOUND++))
    analyze_dependencies "$lib_file" "$extracted_root" "$output_root" 0
    finalize_status
    
    echo
    print_success "Dependency analysis completed!"
    print_info "Total libraries processed: $TOTAL_DEPS_PROCESSED"
    print_info "Total library instances found: $TOTAL_LIBS_FOUND"
    echo
    
    # Ask if user wants references analysis
    read -p "Do you want to deep analyze for the references? (y/N): " analyze_refs
    if [[ "$analyze_refs" =~ ^[Yy]$ ]]; then
        generate_references_file "$output_root" "$extracted_root"
        echo
    else
        print_info "Skipping references analysis."
        echo
    fi
    
    # --- Generate Tree Output ---
    print_info "Summary of copied files:"
    local found_libs_file="$output_root/found_libs_tree.txt"
    if command_exists tree; then
        tree "$output_root" | tee "$found_libs_file"
    else
        print_warning "tree command not found. Using 'find' for a basic list."
        find "$output_root" -print | sed -e "s;$output_root;.;" -e "s;[^/]*;;g;s;/[^/]*;/-- ;g;s;-- |; |;s;-- ;|-- ;" | tee "$found_libs_file"
    fi
    print_success "Library tree saved to: $found_libs_file"
    echo
    
    # --- Handle missing dependencies ---
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
        print_info "Check REFERENCES.txt for library usage information"
    fi
}

# Run main function
main "$@"
