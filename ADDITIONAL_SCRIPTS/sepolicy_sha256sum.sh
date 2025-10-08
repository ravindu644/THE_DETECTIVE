#!/system/bin/sh

OUTPUT_DIR="/sdcard/generated_sha256_selinux"
SYSTEM_DIR="$OUTPUT_DIR/system"
SYSTEM_EXT_DIR="$OUTPUT_DIR/system_ext"
VENDOR_DIR="$OUTPUT_DIR/vendor"

mkdir -p "$SYSTEM_DIR" "$SYSTEM_EXT_DIR" "$VENDOR_DIR"

generate_hash() {
    output_file=$1
    shift
    cat "$@" 2>/dev/null | sha256sum | cut -d' ' -f1 > "$output_file" 2>/dev/null
}

# Generate system hashes
generate_hash "$SYSTEM_DIR/plat_sepolicy_and_mapping.sha256" \
    /system/etc/selinux/plat_sepolicy.cil \
    /system/etc/selinux/mapping/*

# Generate system_ext hashes
generate_hash "$SYSTEM_EXT_DIR/system_ext_sepolicy_and_mapping.sha256" \
    /system_ext/etc/selinux/system_ext_sepolicy.cil \
    /system_ext/etc/selinux/mapping/*

# Generate vendor hashes
generate_hash "$VENDOR_DIR/precompiled_sepolicy.plat_sepolicy_and_mapping.sha256" \
    /system/etc/selinux/plat_sepolicy.cil \
    /system/etc/selinux/mapping/*

generate_hash "$VENDOR_DIR/precompiled_sepolicy.system_ext_sepolicy_and_mapping.sha256" \
    /system_ext/etc/selinux/system_ext_sepolicy.cil \
    /system_ext/etc/selinux/mapping/*

generate_hash "$VENDOR_DIR/precompiled_sepolicy.vendor_sepolicy_and_mapping.sha256" \
    /vendor/etc/selinux/vendor_sepolicy.cil \
    /vendor/etc/selinux/mapping/*

# Copy original hashes
for orig in /system/etc/selinux/*.sha256; do
    [ -f "$orig" ] && cp "$orig" "$SYSTEM_DIR/original_$(basename "$orig")"
done

for orig in /system_ext/etc/selinux/*.sha256; do
    [ -f "$orig" ] && cp "$orig" "$SYSTEM_EXT_DIR/original_$(basename "$orig")"
done

for orig in /vendor/etc/selinux/*.sha256; do
    [ -f "$orig" ] && cp "$orig" "$VENDOR_DIR/original_$(basename "$orig")"
done

echo "Done. Output: $OUTPUT_DIR"
