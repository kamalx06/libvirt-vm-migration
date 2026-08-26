#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="1.0"
CONN="qemu:///system"
SELINUX_RESTORE=0
SCRIPT_NAME="$(basename "$0")"
WORK_DEST=""
RESTORED_FILES=()

###############################################################################
# Helpers
###############################################################################

die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
}

info() {
    echo "[+] $*"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}

cleanup_on_error() {
    local rc=$?

    if [[ -n "${WORK_DEST:-}" && -d "${WORK_DEST:-}" ]]; then
        warn "Operation failed."
        warn "Partial export data remains at:"
        warn "  $WORK_DEST"
    fi

    if (( ${#RESTORED_FILES[@]} > 0 )); then
        warn "Operation failed."
        warn "The following files were already restored to their original,"
        warn "system-wide paths before the failure. They were NOT removed"
        warn "automatically -- review them before retrying the import:"
        local f
        for f in "${RESTORED_FILES[@]}"; do
            warn "  $f"
        done
    fi

    exit "$rc"
}

trap cleanup_on_error ERR

###############################################################################
# Requirements
###############################################################################

for cmd in \
    virsh \
    qemu-img \
    python3 \
    sha256sum \
    cp \
    mv \
    stat \
    sort \
    dirname \
    tr \
    awk \
    grep \
    find
do
    need_cmd "$cmd"
done

if (( SELINUX_RESTORE == 1 )); then
    need_cmd restorecon
fi

###############################################################################
# Usage
###############################################################################

usage() {
    local exit_code="${1:-0}"

    cat <<EOF

$SCRIPT_NAME v$VERSION
Safe libvirt/KVM VM migration and backup tool.

USAGE
  $SCRIPT_NAME export [OPTIONS] <VM_NAME> <BACKUP_DIR>
  $SCRIPT_NAME import [OPTIONS] <BACKUP_DIR>
  $SCRIPT_NAME -h | --help

COMMANDS
  export    Export a powered-off VM and its disk/snapshot data.
  import    Restore a previously exported VM backup.
  help      Show this help message.

OPTIONS
  --selinux     Restore SELinux contexts during import.
  -h, --help    Show this help message.

EXAMPLES
  Export:
    sudo $SCRIPT_NAME export "Windows 11" /mnt/backup/windows11

  Import:
    sudo $SCRIPT_NAME import /mnt/backup/windows11

  Import with SELinux:
    sudo $SCRIPT_NAME import --selinux /mnt/backup/windows11

NOTES
  • VMs must be powered off before export.
  • QCOW2 backing chains and snapshot metadata are preserved.
  • Files are verified using SHA-256 checksums.
  • Existing files are never overwritten if they differ.
  • No snapshot merging, commit, rebase, blockpull, or blockcommit
    operations are performed automatically.
  • Imported VMs remain powered off.

For more information, see the project README.

EOF

    exit "$exit_code"
}


###############################################################################
# VM information
###############################################################################

get_vm_uuid() {
    local vm="$1"

    virsh --connect "$CONN" domuuid "$vm" |
        tr -d '[:space:]'
}

get_vm_state() {
    local vm="$1"

    virsh --connect "$CONN" domstate "$vm" |
        tr -d '\r'
}

get_vm_name_from_xml() {
    local xml="$1"

    python3 - "$xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()

name = root.findtext("name")

if not name:
    raise SystemExit("Could not determine VM name")

print(name)
PY
}

###############################################################################
# XML file discovery
###############################################################################

extract_paths_from_xml() {
    local xml="$1"
    local output="$2"
    local warnings_output="$3"
    local poolvols_output="$4"

    python3 - "$xml" "$output" "$warnings_output" "$poolvols_output" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

xml_file = sys.argv[1]
files_output = sys.argv[2]
warnings_output = sys.argv[3]
poolvols_output = sys.argv[4]

root = ET.parse(xml_file).getroot()

paths = set()
warnings = []
poolvols = []

if root.tag == "domainsnapshot":
    disk_nodes = root.findall("./disks/disk")

    def dev_name_of(disk):
        return disk.get("name", "?")
else:
    disk_nodes = root.findall(".//disk")

    def dev_name_of(disk):
        target = disk.find("target")
        return target.get("dev") if target is not None else "?"

for disk in disk_nodes:
    device = disk.get("device", "disk")
    source = disk.find("source")
    dev_name = dev_name_of(disk)

    if source is None:
        continue

    file_path = source.get("file")
    if file_path:
        paths.add(os.path.abspath(os.path.expanduser(file_path)))
        continue

    severity = "FATAL" if device == "disk" else "WARN"

    block_dev = source.get("dev")
    if block_dev:
        warnings.append(
            f"{severity}\tdisk '{dev_name}' ({device}): block device "
            f"source not backed up: {block_dev}"
        )
        continue

    protocol = source.get("protocol")
    if protocol:
        name = source.get("name", "")
        warnings.append(
            f"{severity}\tdisk '{dev_name}' ({device}): network storage "
            f"source not backed up: {protocol}://{name}"
        )
        continue

    pool = source.get("pool")
    volume = source.get("volume")
    if pool and volume:
        poolvols.append(f"{pool}\t{volume}\t{dev_name}\t{device}")
        continue

    warnings.append(
        f"{severity}\tdisk '{dev_name}' ({device}): source could not be "
        f"backed up automatically (unsupported source type)"
    )

for memory in root.iter("memory"):
    path = memory.get("file")

    if path:
        paths.add(os.path.abspath(os.path.expanduser(path)))

with open(files_output, "w") as f:
    for path in sorted(paths):
        f.write(path + "\n")

with open(warnings_output, "w") as f:
    for w in warnings:
        f.write(w + "\n")

with open(poolvols_output, "w") as f:
    for pv in poolvols:
        f.write(pv + "\n")
PY
}

###############################################################################
# QCOW2 backing chain
###############################################################################

get_qemu_img_format() {
    local image="$1"

    qemu-img info --force-share --output=json "$image" 2>/dev/null |
        python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("format", ""))
except Exception:
    print("")
'
}

collect_backing_chain() {
    local image="$1"
    local output="$2"

    python3 - "$image" "$output" <<'PY'
import json
import os
import subprocess
import sys

image = os.path.abspath(sys.argv[1])
output = sys.argv[2]

seen = set()
result = []

def inspect(path):
    path = os.path.abspath(path)

    if path in seen:
        raise RuntimeError(f"Backing-chain loop detected at: {path}")

    seen.add(path)

    if not os.path.isfile(path):
        raise RuntimeError(f"Missing image: {path}")

    result.append(path)

    p = subprocess.run(
        [
            "qemu-img",
            "info",
            "--force-share",
            "--output=json",
            path
        ],
        text=True,
        capture_output=True
    )

    if p.returncode != 0:
        raise RuntimeError(
            f"qemu-img failed for {path}:\n{p.stderr}"
        )

    info = json.loads(p.stdout)

    backing = info.get("full-backing-filename")

    if backing:
        backing = os.path.abspath(backing)
        inspect(backing)

inspect(image)

with open(output, "w") as f:
    for path in result:
        f.write(path + "\n")
PY
}

###############################################################################
# Snapshot discovery
###############################################################################

export_snapshot_metadata() {
    local vm="$1"
    local meta="$2"

    mkdir -p "$meta/snapshots"

    mapfile -t snapshots < <(
        virsh --connect "$CONN" snapshot-list "$vm" --name
    )

    printf '%s\n' "${snapshots[@]}" > "$meta/snapshots.list"

    local index=0

    for snapshot in "${snapshots[@]}"; do
        [[ -z "$snapshot" ]] && continue

        index=$((index + 1))

        local filename
        filename=$(printf "%04d.xml" "$index")

        info "Exporting snapshot: $snapshot"

        virsh --connect "$CONN" snapshot-dumpxml \
            "$vm" \
            "$snapshot" \
            > "$meta/snapshots/$filename"

        printf '%s\t%s\n' \
            "$snapshot" \
            "$filename" \
            >> "$meta/snapshot-files.tsv"
    done
}

###############################################################################
# Verify manifest
###############################################################################

verify_manifest() {
    local manifest="$1"
    local base="$2"

    while IFS=$'\t' read -r expected_hash expected_size relative; do

        [[ -z "$relative" ]] && continue

        local file="$base/$relative"

        [[ -f "$file" ]] ||
            die "Missing file during verification: $file"

        local actual_size
        actual_size=$(stat -c '%s' "$file")

        [[ "$actual_size" == "$expected_size" ]] ||
            die "Size mismatch:
File: $file
Expected: $expected_size
Actual:   $actual_size"

        local actual_hash
        actual_hash=$(sha256sum "$file" | awk '{print $1}')

        [[ "$actual_hash" == "$expected_hash" ]] ||
            die "SHA-256 mismatch:
File: $file
Expected: $expected_hash
Actual:   $actual_hash"

    done < "$manifest"
}

###############################################################################
# EXPORT
###############################################################################

export_vm() {

    [[ $# -eq 2 ]] ||
        usage

    local VM="$1"
    local DEST="$2"

    virsh --connect "$CONN" dominfo "$VM" >/dev/null 2>&1 ||
        die "VM '$VM' does not exist."

    local state
    state=$(get_vm_state "$VM")

    [[ "$state" == "shut off" ]] ||
        die "VM '$VM' is currently '$state'.

For safety, shut the VM down completely before exporting."

    [[ -e "$DEST" ]] &&
        die "Destination already exists:
$DEST

Refusing to overwrite an existing backup."

    local parent
    parent="$(dirname "$DEST")"

    mkdir -p "$parent"

    WORK_DEST="${DEST}.partial"

    [[ -e "$WORK_DEST" ]] &&
        die "Partial backup already exists:
$WORK_DEST"

    mkdir -p "$WORK_DEST"

    local META="$WORK_DEST/metadata"
    local DISKS="$WORK_DEST/disks"

    mkdir -p "$META" "$DISKS"

    info "Exporting VM: $VM"
    info "Destination: $DEST"

    ###########################################################################
    # Domain XML
    ###########################################################################

    info "Exporting domain XML..."

    virsh --connect "$CONN" dumpxml "$VM" \
        > "$META/domain.xml"

    local UUID
    UUID=$(get_vm_uuid "$VM")

    echo "$UUID" > "$META/domain.uuid"

    echo "$VM" > "$META/domain.name"

    ###########################################################################
    # Snapshot metadata
    ###########################################################################

    info "Exporting snapshot metadata..."

    export_snapshot_metadata "$VM" "$META"

    ###########################################################################
    # Current snapshot
    ###########################################################################

    local current_snapshot=""

    current_snapshot=$(
        virsh --connect "$CONN" snapshot-current \
            "$VM" --name 2>/dev/null || true
    )

    printf '%s\n' "$current_snapshot" \
        > "$META/current-snapshot.txt"

    ###########################################################################
    # Snapshot tree
    ###########################################################################

    virsh --connect "$CONN" snapshot-list "$VM" --tree \
        > "$META/snapshot-tree.txt"

    ###########################################################################
    # Discover files
    ###########################################################################

    info "Discovering VM and snapshot files..."

    : > "$META/direct-files.list"
    : > "$META/disk-warnings.list"
    : > "$META/pool-volumes.tsv"

    extract_paths_from_xml \
        "$META/domain.xml" \
        "$META/domain-files.tmp" \
        "$META/domain-warnings.tmp" \
        "$META/domain-poolvols.tmp"

    cat "$META/domain-files.tmp" \
        >> "$META/direct-files.list"

    cat "$META/domain-warnings.tmp" \
        >> "$META/disk-warnings.list"

    cat "$META/domain-poolvols.tmp" \
        >> "$META/pool-volumes.tsv"

    if [[ -d "$META/snapshots" ]]; then

        while IFS= read -r snapshot_xml; do

            [[ -z "$snapshot_xml" ]] && continue

            extract_paths_from_xml \
                "$snapshot_xml" \
                "$snapshot_xml.files" \
                "$snapshot_xml.warnings" \
                "$snapshot_xml.poolvols"

            cat "$snapshot_xml.files" \
                >> "$META/direct-files.list"

            cat "$snapshot_xml.warnings" \
                >> "$META/disk-warnings.list"

            cat "$snapshot_xml.poolvols" \
                >> "$META/pool-volumes.tsv"

        done < <(find "$META/snapshots" -type f -name '*.xml' | sort)

    fi

    ###########################################################################
    # Resolve storage-pool-backed disks
    ###########################################################################

    if [[ -s "$META/pool-volumes.tsv" ]]; then

        info "Resolving storage-pool-backed disks..."

        sort -u "$META/pool-volumes.tsv" \
            -o "$META/pool-volumes.tsv"

        while IFS=$'\t' read -r pool volume dev_name device; do

            [[ -z "$pool" ]] && continue

            local resolved=""
            resolved=$(
                virsh --connect "$CONN" vol-path \
                    --pool "$pool" "$volume" 2>/dev/null || true
            )

            if [[ -n "$resolved" && -f "$resolved" ]]; then
                info "Resolved disk '$dev_name': pool='$pool' volume='$volume' -> $resolved"
                echo "$resolved" >> "$META/direct-files.list"
            else
                local severity="FATAL"
                [[ "$device" == "disk" ]] || severity="WARN"

                printf '%s\t%s\n' \
                    "$severity" \
                    "disk '$dev_name' ($device): could not resolve storage-pool volume (pool='$pool' volume='$volume')" \
                    >> "$META/disk-warnings.list"
            fi

        done < "$META/pool-volumes.tsv"

    fi

    sort -u "$META/direct-files.list" \
        > "$META/direct-files.unique"

    sort -u "$META/disk-warnings.list" \
        -o "$META/disk-warnings.list"

    ###########################################################################
    # Refuse to produce a silently incomplete backup
    ###########################################################################

    if [[ -s "$META/disk-warnings.list" ]]; then

        local has_fatal=0
        local severity message

        while IFS=$'\t' read -r severity message; do
            [[ -z "$severity" ]] && continue

            warn "$message"

            [[ "$severity" == "FATAL" ]] && has_fatal=1
        done < "$META/disk-warnings.list"

        if (( has_fatal == 1 )); then
            die "One or more virtual disks use storage this script cannot
back up (see warnings above: block devices such as LVM, or
network storage such as RBD/iSCSI/NFS).

Refusing to produce a backup that is silently missing disk data.
Back up those disks manually (e.g. 'qemu-img convert' or a
block-level copy) before exporting this VM."
        fi
    fi

    ###########################################################################
    # Follow every backing chain
    ###########################################################################

    info "Inspecting QCOW2 backing chains..."

    : > "$META/all-files.list"

    while IFS= read -r file; do

        [[ -z "$file" ]] && continue

        [[ -f "$file" ]] ||
            die "Required VM/snapshot file does not exist:
$file"

        echo "$file" >> "$META/all-files.list"

        if qemu-img info --output=json "$file" >/dev/null 2>&1; then

            local chain
            chain="$META/chain.$(sha256sum <<< "$file" | awk '{print $1}').list"

            collect_backing_chain "$file" "$chain"

            cat "$chain" >> "$META/all-files.list"

        fi

    done < "$META/direct-files.unique"

    sort -u "$META/all-files.list" \
        > "$META/all-files.unique"

    ###########################################################################
    # Copy files
    ###########################################################################

    info "Copying VM files..."

    while IFS= read -r file; do

        [[ -z "$file" ]] && continue

        [[ -f "$file" ]] ||
            die "File disappeared:
$file"

        local relative
        relative="${file#/}"

        local target
        target="$DISKS/$relative"

        mkdir -p "$(dirname "$target")"

        info "Copying: $file"

        cp --archive --sparse=always \
            "$file" "$target"

    done < "$META/all-files.unique"

    ###########################################################################
    # Verify copied files
    ###########################################################################

    info "Generating SHA-256 manifest..."

    : > "$META/manifest.tsv"

    while IFS= read -r file; do

        [[ -z "$file" ]] && continue

        local relative
        relative="${file#/}"

        local copied
        copied="$DISKS/$relative"

        [[ -f "$copied" ]] ||
            die "Copied file missing:
$copied"

        local source_size
        source_size=$(stat -c '%s' "$file")

        local copied_size
        copied_size=$(stat -c '%s' "$copied")

        [[ "$source_size" == "$copied_size" ]] ||
            die "Size mismatch after copy:
$file"

        local hash
        hash=$(sha256sum "$copied" | awk '{print $1}')

        printf '%s\t%s\t%s\n' \
            "$hash" \
            "$copied_size" \
            "$relative" \
            >> "$META/manifest.tsv"

    done < "$META/all-files.unique"

    ###########################################################################
    # Verify backing chains inside backup
    ###########################################################################

    info "Verifying copied QCOW2 backing chains..."

    while IFS= read -r file; do

        [[ -z "$file" ]] && continue

        local relative
        relative="${file#/}"

        local copied
        copied="$DISKS/$relative"

        if qemu-img info --output=json "$copied" >/dev/null 2>&1; then
            qemu-img info \
                --force-share \
                --backing-chain \
                "$copied" >/dev/null ||
                die "Backing-chain verification failed:
$copied"

        fi

    done < "$META/all-files.unique"

    ###########################################################################
    # Metadata
    ###########################################################################

    cat > "$META/README.txt" <<EOF
VM Migration Backup

Tool version:
$VERSION

VM:
$VM

UUID:
$UUID

Libvirt connection:
$CONN

VM was shut off during export:
yes

Snapshot metadata:
metadata/snapshots/

Snapshot hierarchy:
metadata/snapshot-tree.txt

Current snapshot:
metadata/current-snapshot.txt

Original files:
metadata/all-files.unique

SHA-256 manifest:
metadata/manifest.tsv

IMPORTANT:
The QCOW2 images were copied without:
- commit
- rebase
- blockpull
- blockcommit
- merge
- snapshot deletion

The original absolute paths are preserved.

EOF

    if [[ -s "$META/disk-warnings.list" ]]; then
        cat >> "$META/README.txt" <<EOF
Disk source notices:
The following disk sources were not copied into this backup (see
metadata/disk-warnings.list). These were non-fatal (e.g. cdrom/floppy
passthrough) -- a fatal one would have aborted the export outright.

EOF
        cut -f2- "$META/disk-warnings.list" >> "$META/README.txt"
        echo >> "$META/README.txt"
    fi

    ###########################################################################
    # Finalize backup
    ###########################################################################

    info "Finalizing backup..."

    sync

    mv "$WORK_DEST" "$DEST"

    WORK_DEST=""

    echo
    echo "============================================================"
    echo " EXPORT COMPLETE"
    echo "============================================================"
    echo
    echo "VM:"
    echo "  $VM"
    echo
    echo "UUID:"
    echo "  $UUID"
    echo
    echo "Backup:"
    echo "  $DEST"
    echo
    echo "Snapshots:"
    cat "$DEST/metadata/snapshot-tree.txt"
    echo
    echo "Current snapshot:"
    cat "$DEST/metadata/current-snapshot.txt"
    echo
    echo "SHA-256 manifest:"
    echo "  $DEST/metadata/manifest.tsv"
    echo

    if [[ -s "$DEST/metadata/disk-warnings.list" ]]; then
        echo "NOTE: some disk sources were skipped (non-fatal). See:"
        echo "  $DEST/metadata/disk-warnings.list"
        echo
    fi
    echo "The backup was verified before completion."
    echo
}

###############################################################################
# IMPORT
###############################################################################

import_vm() {

    [[ $# -eq 1 ]] ||
        usage

    local SRC="$1"

    [[ -d "$SRC" ]] ||
        die "Backup directory does not exist:
$SRC"

    local META="$SRC/metadata"
    local DISKS="$SRC/disks"

    [[ -f "$META/domain.xml" ]] ||
        die "Missing:
$META/domain.xml"

    [[ -f "$META/manifest.tsv" ]] ||
        die "Missing:
$META/manifest.tsv"

    [[ -f "$META/snapshots.list" ]] ||
        die "Missing:
$META/snapshots.list"

    [[ -d "$DISKS" ]] ||
        die "Missing:
$DISKS"

    local VM
    VM=$(cat "$META/domain.name")

    local UUID
    UUID=$(cat "$META/domain.uuid")

    local xml_name
    xml_name=$(get_vm_name_from_xml "$META/domain.xml")

    [[ "$xml_name" == "$VM" ]] ||
        die "Inconsistent backup metadata:
$META/domain.name says: $VM
$META/domain.xml <name> is: $xml_name"

    echo
    echo "============================================================"
    echo " IMPORTING VM"
    echo "============================================================"
    echo
    echo "VM:"
    echo "  $VM"
    echo
    echo "UUID:"
    echo "  $UUID"
    echo

    ###########################################################################
    # Check destination VM
    ###########################################################################

    if virsh --connect "$CONN" dominfo "$VM" >/dev/null 2>&1; then
        die "VM '$VM' already exists.

Refusing to overwrite it."
    fi

    ###########################################################################
    # Verify backup BEFORE touching destination
    ###########################################################################

    info "Verifying backup checksums..."

    verify_manifest "$META/manifest.tsv" "$DISKS"

    info "Backup checksum verification passed."

    ###########################################################################
    # Restore files
    ###########################################################################

    info "Restoring VM files..."

    while IFS=$'\t' read -r expected_hash expected_size relative; do

        [[ -z "$relative" ]] && continue

        local source
        source="$DISKS/$relative"

        local original
        original="/$relative"

        if [[ -e "$original" ]]; then

            [[ -f "$original" ]] ||
                die "Destination exists and is not a regular file:
$original"

            local existing_size
            existing_size=$(stat -c '%s' "$original")

            local existing_hash=""

            if [[ "$existing_size" == "$expected_size" ]]; then
                existing_hash=$(sha256sum "$original" | awk '{print $1}')
            fi

            if [[ "$existing_hash" == "$expected_hash" ]]; then
                info "Already present and verified, skipping: $original"
                continue
            fi

            die "Destination file already exists and differs from the backup:
$original

Refusing to overwrite it. If this file legitimately belongs to
another VM, resolve the conflict manually before importing."

        fi

        mkdir -p "$(dirname "$original")"

        info "Restoring:"
        info "  $source"
        info "  -> $original"

        cp --archive --sparse=always \
            "$source" "$original"

        RESTORED_FILES+=("$original")

    done < "$META/manifest.tsv"

    ###########################################################################
    # Verify restored files
    ###########################################################################

    info "Verifying restored files..."

    verify_manifest "$META/manifest.tsv" ""

    RESTORED_FILES=()

    ###############################################################################
    # Restore SELinux contexts (optional)
    ###############################################################################

    if (( SELINUX_RESTORE == 1 )); then

        info "Restoring SELinux contexts on restored files..."

        while IFS=$'\t' read -r _hash _size relative; do

            [[ -z "$relative" ]] && continue

            restorecon -R "/$relative" ||
                die "SELinux relabel failed:
    /$relative"

        done < "$META/manifest.tsv"

    else

        info "SELinux relabeling disabled."

    fi

    ###########################################################################
    # Check restored disk images
    ###########################################################################

    info "Checking restored disk images..."

    while IFS=$'\t' read -r _hash _size relative; do

        [[ -z "$relative" ]] && continue

        local file
        file="/$relative"

        if qemu-img info --output=json "$file" >/dev/null 2>&1; then

            local check_output
            local check_rc=0

            check_output=$(qemu-img check "$file" 2>&1) || check_rc=$?

            if (( check_rc != 0 )); then

                if grep -qi "does not support" <<< "$check_output"; then

                    local fmt
                    fmt=$(get_qemu_img_format "$file")

                    info "Skipping consistency check (format: ${fmt:-unknown}): $file"

                else

                    die "Disk image consistency check failed:
$file

$check_output"

                fi

            fi

        fi

    done < "$META/manifest.tsv"

    ###########################################################################
    # Verify backing chains AFTER restoration
    ###########################################################################

    info "Verifying restored backing chains..."

    while IFS=$'\t' read -r _hash _size relative; do

        [[ -z "$relative" ]] && continue

        local restored
        restored="/$relative"

        if qemu-img info --output=json "$restored" >/dev/null 2>&1; then

            qemu-img info \
                --force-share \
                --backing-chain \
                "$restored" >/dev/null ||
                die "Restored backing chain is broken:
$restored"

        fi

    done < "$META/manifest.tsv"

    ###########################################################################
    # Define domain
    ###########################################################################

    info "Defining VM..."

    virsh --connect "$CONN" define \
        "$META/domain.xml" >/dev/null

    ###########################################################################
    # Verify UUID
    ###########################################################################

    local imported_uuid
    imported_uuid=$(get_vm_uuid "$VM")

    [[ "$imported_uuid" == "$UUID" ]] ||
        die "VM UUID mismatch after import.

Expected:
$UUID

Actual:
$imported_uuid"

    info "VM UUID verified."

    ###########################################################################
    # Restore snapshot metadata
    ###########################################################################

    info "Restoring snapshot metadata..."

    local snapshot_files="$META/snapshot-files.tsv"

    if [[ -s "$snapshot_files" ]]; then

        local -A SNAP_DONE=()

        local total_snapshots
        total_snapshots=$(
            grep -cve '^[[:space:]]*$' "$snapshot_files" || true
        )

        local imported_count=0

        while (( imported_count < total_snapshots )); do

            local progress=0

            while IFS=$'\t' read -r snapshot filename; do

                [[ -z "$snapshot" ]] && continue

                [[ -n "${SNAP_DONE[$snapshot]:-}" ]] &&
                    continue

                local xml
                xml="$META/snapshots/$filename"

                [[ -f "$xml" ]] ||
                    die "Missing snapshot XML:
$xml"

                local parent
                parent=$(
                    python3 - "$xml" <<'PY'
import sys
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()

parent = root.find("parent/name")

if parent is not None and parent.text:
    print(parent.text)
PY
                )

                if [[ -z "$parent" ]] ||
                   virsh --connect "$CONN" snapshot-info \
                       "$VM" "$parent" >/dev/null 2>&1
                then

                    info "Redefining snapshot: $snapshot"

                    virsh --connect "$CONN" snapshot-create \
                        "$VM" \
                        "$xml" \
                        --redefine \
                        --validate >/dev/null

                    virsh --connect "$CONN" snapshot-info \
                        "$VM" "$snapshot" >/dev/null

                    SNAP_DONE["$snapshot"]=1

                    imported_count=$((imported_count + 1))
                    progress=1

                fi

            done < "$snapshot_files"

            (( progress == 1 )) ||
                die "Could not resolve snapshot hierarchy.

There may be missing or circular parent metadata."

        done

    fi

    ###########################################################################
    # Restore current snapshot
    ###########################################################################

    local current
    current=$(cat "$META/current-snapshot.txt")

    if [[ -n "$current" ]]; then

        info "Restoring current snapshot: $current"

        local current_xml=""

        while IFS=$'\t' read -r snapshot filename; do

            if [[ "$snapshot" == "$current" ]]; then
                current_xml="$META/snapshots/$filename"
                break
            fi

        done < "$snapshot_files"

        [[ -f "$current_xml" ]] ||
            die "Current snapshot XML not found:
$current"

        virsh --connect "$CONN" snapshot-create \
            "$VM" \
            "$current_xml" \
            --redefine \
            --current \
            --validate >/dev/null

    fi

    ###########################################################################
    # Final verification
    ###########################################################################

    info "Final verification..."

    echo
    echo "VM:"
    virsh --connect "$CONN" list --all
    echo

    echo "Snapshots:"
    virsh --connect "$CONN" snapshot-list "$VM" --tree
    echo

    local final_uuid
    final_uuid=$(get_vm_uuid "$VM")

    [[ "$final_uuid" == "$UUID" ]] ||
        die "Final UUID verification failed."

    echo
    echo "============================================================"
    echo " IMPORT COMPLETE"
    echo "============================================================"
    echo
    echo "VM:"
    echo "  $VM"
    echo
    echo "UUID:"
    echo "  $UUID"
    echo
    echo "The VM has NOT been started automatically."
    echo
    echo "Please inspect it in virt-manager first."
    echo
    echo "Recommended first test:"
    echo
    echo "  virsh --connect $CONN start \"$VM\""
    echo
}

###############################################################################
# Main
###############################################################################

[[ $# -ge 1 ]] ||
    usage

ACTION="$1"
shift

case "$ACTION" in

    -h|--help|help)
        usage 0
        ;;

    export|import)
        ;;

    *)
        usage
        ;;

esac

while [[ $# -gt 0 ]]; do

    case "$1" in

        --selinux)
            SELINUX_RESTORE=1
            shift
            ;;

        -h|--help)
            usage 0
            ;;

        --)
            shift
            break
            ;;

        -*)
            die "Unknown option: $1

Run:
  $SCRIPT_NAME --help"
            ;;

        *)
            break
            ;;

    esac

done
