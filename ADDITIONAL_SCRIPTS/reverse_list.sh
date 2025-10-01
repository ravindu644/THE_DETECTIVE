#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "Choose mode:"
echo "  1) Generate file list"
echo "  2) Delete files from list"
echo "  3) Copy files to list"
read -p "Enter mode (1/2/3): " MODE

if [[ "$MODE" == "1" ]]; then
    # Mode 1: Generate file list
    read -p "Enter root path to scan: " ROOT_PATH
    ROOT_PATH=$(echo "$ROOT_PATH" | sed "s/^['\"]//;s/['\"]$//")
    ROOT_PATH=$(realpath "$ROOT_PATH")
    if [[ ! -d "$ROOT_PATH" ]]; then
        print_error "Directory not found: $ROOT_PATH"
        exit 1
    fi

    # List subfolders for ignore selection
    mapfile -t SUBFOLDERS < <(find "$ROOT_PATH" -mindepth 1 -maxdepth 1 -type d | sed "s|$ROOT_PATH/||")
    IGNORE=()
    if [[ ${#SUBFOLDERS[@]} -gt 0 ]]; then
        echo "Subfolders:"
        for i in "${!SUBFOLDERS[@]}"; do
            echo "  $((i+1))) ${SUBFOLDERS[$i]}"
        done
        read -p "Enter comma-separated numbers to ignore (or leave empty): " IGNORE_INPUT
        if [[ -n "$IGNORE_INPUT" ]]; then
            IFS=',' read -ra IGNORE_IDX <<< "$IGNORE_INPUT"
            for idx in "${IGNORE_IDX[@]}"; do
                IGNORE+=("${SUBFOLDERS[$((idx-1))]}")
            done
        fi
    fi

    # Build find command
    FIND_CMD=(find "$ROOT_PATH" -type f)
    for folder in "${IGNORE[@]}"; do
        FIND_CMD+=('!' -path "$ROOT_PATH/$folder/*")
    done

    # Output file
    read -p "Enter output txt file path: " OUT_FILE
    OUT_FILE=$(echo "$OUT_FILE" | sed "s/^['\"]//;s/['\"]$//")
    > "$OUT_FILE"
    while IFS= read -r file; do
        rel="${file#$ROOT_PATH/}"
        echo "$rel" >> "$OUT_FILE"
    done < <("${FIND_CMD[@]}")

    print_success "File list saved to $OUT_FILE"

elif [[ "$MODE" == "2" ]]; then
    # Mode 2: Delete files from list
    read -p "Enter root path for relative files: " ROOT_PATH
    ROOT_PATH=$(echo "$ROOT_PATH" | sed "s/^['\"]//;s/['\"]$//")
    ROOT_PATH=$(realpath "$ROOT_PATH")
    if [[ ! -d "$ROOT_PATH" ]]; then
        print_error "Directory not found: $ROOT_PATH"
        exit 1
    fi
    read -p "Enter txt file with file paths: " TXT_FILE
    TXT_FILE=$(echo "$TXT_FILE" | sed "s/^['\"]//;s/['\"]$//")
    if [[ ! -f "$TXT_FILE" ]]; then
        print_error "File not found: $TXT_FILE"
        exit 1
    fi

    DEL_COUNT=0
    FAIL_COUNT=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" = /* ]]; then
            TARGET="$line"
        else
            TARGET="$ROOT_PATH/$line"
        fi
        if [[ -f "$TARGET" ]]; then
            rm -f "$TARGET" && ((DEL_COUNT++)) || ((FAIL_COUNT++))
        else
            print_info "Not found: $TARGET"
            ((FAIL_COUNT++))
        fi
    done < "$TXT_FILE"

    print_success "Deleted $DEL_COUNT files. $FAIL_COUNT files not found or failed."

elif [[ "$MODE" == "3" ]]; then
    # Mode 3: Copy files from list to destination root, preserving folder structure
    read -p "Enter root path for relative files: " ROOT_PATH
    ROOT_PATH=$(echo "$ROOT_PATH" | sed "s/^['\"]//;s/['\"]$//")
    ROOT_PATH=$(realpath "$ROOT_PATH")
    if [[ ! -d "$ROOT_PATH" ]]; then
        print_error "Directory not found: $ROOT_PATH"
        exit 1
    fi

    read -p "Enter txt file with file paths: " TXT_FILE
    TXT_FILE=$(echo "$TXT_FILE" | sed "s/^['\"]//;s/['\"]$//")
    if [[ ! -f "$TXT_FILE" ]]; then
        print_error "File not found: $TXT_FILE"
        exit 1
    fi

    read -p "Enter destination root path: " DEST_ROOT
    DEST_ROOT=$(echo "$DEST_ROOT" | sed "s/^['\"]//;s/['\"]$//")
    mkdir -p "$DEST_ROOT" || { print_error "Failed to create destination root: $DEST_ROOT"; exit 1; }
    DEST_ROOT=$(realpath "$DEST_ROOT")

    COPIED=0
    FAIL_COUNT=0

    while IFS= read -r line; do
        # strip surrounding quotes and skip empty
        line=$(echo "$line" | sed "s/^['\"]//;s/['\"]$//")
        [[ -z "$line" ]] && continue

        if [[ "$line" = /* ]]; then
            TARGET="$line"
            # if absolute path is under ROOT_PATH, make REL relative to ROOT_PATH
            if [[ "$TARGET" == "$ROOT_PATH" || "$TARGET" == "$ROOT_PATH/"* ]]; then
                REL="${TARGET#$ROOT_PATH/}"
            else
                REL="${TARGET#/}"
            fi
        else
            REL="$line"
            TARGET="$ROOT_PATH/$line"
        fi

        if [[ -f "$TARGET" || -L "$TARGET" ]]; then
            dest_dir="$(dirname "$DEST_ROOT/$REL")"
            if mkdir -p "$dest_dir"; then
                if cp -a "$TARGET" "$DEST_ROOT/$REL"; then
                    ((COPIED++))
                else
                    print_error "Failed to copy: $TARGET -> $DEST_ROOT/$REL"
                    ((FAIL_COUNT++))
                fi
            else
                print_error "Failed to create directory: $dest_dir"
                ((FAIL_COUNT++))
            fi
        else
            print_info "Not found: $TARGET"
            ((FAIL_COUNT++))
        fi
    done < "$TXT_FILE"

    print_success "Copied $COPIED files. $FAIL_COUNT files not found or failed."

else
    print_error "Invalid mode."
    exit 1
fi
