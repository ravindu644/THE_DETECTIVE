#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
declare -A PROCESSED_LIBS
MISSING_DEPS=""

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

# Function to find a library file in the extracted image
find_library() {
    local lib_name="$1"
    local search_path="$2"
    
    # Search for the library in common directories
    local found_lib=$(find "$search_path" -type f -name "$lib_name" 2>/dev/null | head -1)
    
    if [[ -n "$found_lib" ]]; then
        echo "$found_lib"
        return 0
    fi
    
    return 1
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

# Function to analyze dependencies recursively
analyze_dependencies() {
    local lib_file="$1"
    local extracted_root="$2"
    local output_root="$3"
    local depth="$4"
    
    # Create indentation for visual hierarchy
    local indent=""
    for ((i=0; i<depth; i++)); do
        indent+="  "
    done
    
    print_info "${indent}Analyzing: $(basename "$lib_file")"
    
    # Get dependencies of current library
    local deps=$(get_dependencies "$lib_file")
    
    if [[ -z "$deps" ]]; then
        return 0
    fi
    
    # Process each dependency
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        
        # Skip if already processed
        if [[ -n "${PROCESSED_LIBS[$dep]}" ]]; then
            continue
        fi
        
        # Mark as processed immediately to handle cyclic dependencies
        PROCESSED_LIBS["$dep"]=1

        # Find the dependency in the extracted image
        local dep_path=$(find_library "$dep" "$extracted_root")
        
        if [[ -n "$dep_path" ]]; then
            print_info "${indent}→ Found '$dep', copying and analyzing..."
            # Copy the dependency with proper structure
            copy_with_structure "$dep_path" "$extracted_root" "$output_root"
            
            # Recursively analyze dependencies of this dependency
            analyze_dependencies "$dep_path" "$extracted_root" "$output_root" $((depth + 1))
        else
            # Add to missing dependencies list silently
            add_missing_dep "$dep"
        fi
        
    done <<< "$deps"
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
    analyze_dependencies "$lib_file" "$extracted_root" "$output_root" 0
    
    echo
    print_success "Dependency analysis completed!"
    echo
    
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
}

# Run main function
main "$@"
