#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to remove quotes from input
remove_quotes() {
    echo "$1" | tr -d "\"'"
}

# Get HAL directory
read -p "Enter path to HAL directory: " hal_input
HAL_DIR=$(remove_quotes "$hal_input")

# Validate HAL directory
if [ ! -d "$HAL_DIR" ]; then
    echo -e "${RED}Error: HAL directory does not exist: $HAL_DIR${NC}"
    exit 1
fi

# Get Vendor directory
read -p "Enter path to Vendor directory: " vendor_input
VENDOR_DIR=$(remove_quotes "$vendor_input")

# Validate Vendor directory
if [ ! -d "$VENDOR_DIR" ]; then
    echo -e "${RED}Error: Vendor directory does not exist: $VENDOR_DIR${NC}"
    exit 1
fi

# Get keywords
read -p "Enter keywords (comma separated): " keywords_input
KEYWORDS=$(remove_quotes "$keywords_input")

# Display configuration
echo -e "${GREEN}HAL Directory:${NC} $HAL_DIR"
echo -e "${GREEN}Vendor Directory:${NC} $VENDOR_DIR"
echo -e "${GREEN}Keywords:${NC} $KEYWORDS"
echo ""

# Convert comma-separated keywords to array
IFS=',' read -ra KEYWORD_ARRAY <<< "$KEYWORDS"

# Trim whitespace from keywords
for i in "${!KEYWORD_ARRAY[@]}"; do
    KEYWORD_ARRAY[$i]=$(echo "${KEYWORD_ARRAY[$i]}" | xargs)
done

# Build associative array of all .so files in HAL directory (excluding symlinks)
echo -e "${YELLOW}Indexing HAL directory...${NC}"
declare -A HAL_FILES
while IFS= read -r hal_file; do
    filename=$(basename "$hal_file")
    HAL_FILES["$filename"]=1
done < <(find "$HAL_DIR" -type f -name "*.so" 2>/dev/null)

echo -e "${YELLOW}Found ${#HAL_FILES[@]} libraries in HAL directory${NC}"
echo ""

# Find all .so files in vendor directory matching keywords
echo -e "${YELLOW}Searching for matching libraries in vendor directory...${NC}"
echo ""

MISSING_COUNT=0
FOUND_COUNT=0

# Use find to search for .so files, excluding symlinks
while IFS= read -r vendor_file; do
    # Get just the filename
    filename=$(basename "$vendor_file")
    
    # Check if filename matches any keyword
    match=false
    for keyword in "${KEYWORD_ARRAY[@]}"; do
        if [[ "$filename" == *"$keyword"* ]]; then
            match=true
            break
        fi
    done
    
    if [ "$match" = true ]; then
        # Check if this file exists in HAL directory
        if [[ -z "${HAL_FILES[$filename]}" ]]; then
            echo -e "${RED}[MISSING]${NC} $filename"
            echo "          Found in: $vendor_file"
            MISSING_COUNT=$((MISSING_COUNT + 1))
        else
            FOUND_COUNT=$((FOUND_COUNT + 1))
        fi
    fi
done < <(find "$VENDOR_DIR" -type f -name "*.so" 2>/dev/null)

# Summary
echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}Summary:${NC}"
echo -e "${GREEN}  Found in HAL:${NC} $FOUND_COUNT"
echo -e "${RED}  Missing from HAL:${NC} $MISSING_COUNT"
echo -e "${GREEN}======================================${NC}"

# Save missing libraries to file if any were found
if [ $MISSING_COUNT -gt 0 ]; then
    OUTPUT_FILE="missing_hal.txt"
    
    # Clear the output file
    > "$OUTPUT_FILE"
    
    # Re-scan and collect missing filenames
    while IFS= read -r vendor_file; do
        filename=$(basename "$vendor_file")
        
        # Check if filename matches any keyword
        match=false
        for keyword in "${KEYWORD_ARRAY[@]}"; do
            if [[ "$filename" == *"$keyword"* ]]; then
                match=true
                break
            fi
        done
        
        if [ "$match" = true ]; then
            if [[ -z "${HAL_FILES[$filename]}" ]]; then
                echo "$filename" >> "$OUTPUT_FILE"
            fi
        fi
    done < <(find "$VENDOR_DIR" -type f -name "*.so" 2>/dev/null)
    
    # Sort and remove duplicates
    sort -u "$OUTPUT_FILE" -o "$OUTPUT_FILE"
    
    echo ""
    echo -e "${GREEN}Missing libraries saved to: ${YELLOW}$OUTPUT_FILE${NC}"
fi

exit 0

