# Libvirt/KVM VM Migration Tool

A Bash utility for safely exporting and importing libvirt/KVM virtual machines, including QCOW2 backing chains and snapshot metadata.

## Features

- Exports only powered-off VMs.
- Preserves original absolute disk paths and QCOW2 backing chains.
- Exports libvirt domain and snapshot metadata.
- Supports file-backed disks and libvirt storage-pool volumes.
- Refuses to create incomplete backups when unsupported VM disks are detected.
- Verifies backup files with SHA-256 checksums and file sizes.
- Refuses to overwrite existing or conflicting files during import.
- Optionally restores SELinux contexts with `--selinux`.
- Does not automatically merge, commit, rebase, or delete snapshots.
- Performs QCOW2 backing-chain and disk consistency checks.
- Does not automatically start an imported VM.

## Requirements

The script requires:

- `virsh`
- `qemu-img`
- `python3`
- `sha256sum`
- Standard Unix utilities such as:
  - `cp`
  - `mv`
  - `stat`
  - `find`
  - `awk`
  - `grep`

Run it with sufficient privileges, typically using `sudo`.

## Usage

### Export

The VM must be completely shut down before exporting.

```bash
sudo ./vm-migrate.sh export "VM_NAME" /path/to/backup
```

Example:

```bash
sudo ./vm-migrate.sh export "Windows 11" /mnt/backup/windows11
```

The backup is first created as a `.partial` directory and renamed to its final destination only after verification succeeds.

### Import

```bash
sudo ./vm-migrate.sh import /path/to/backup
```

Example:

```bash
sudo ./vm-migrate.sh import /mnt/backup/windows11
```

To restore SELinux contexts:

```bash
sudo ./vm-migrate.sh import --selinux /mnt/backup/windows11
```

After import, inspect the VM before starting it:

```bash
virsh --connect qemu:///system start "Windows 11"
```

## Backup Layout

A typical backup contains:

```text
backup/
├── disks/
│   └── ...original absolute paths...
└── metadata/
    ├── domain.xml
    ├── domain.uuid
    ├── domain.name
    ├── snapshots/
    ├── snapshots.list
    ├── snapshot-files.tsv
    ├── snapshot-tree.txt
    ├── current-snapshot.txt
    ├── all-files.unique
    ├── manifest.tsv
    └── README.txt
```

## Important Notes

The script intentionally does **not** perform destructive or modifying storage operations such as:

- `qemu-img commit`
- `qemu-img rebase`
- `blockpull`
- `blockcommit`
- Snapshot merging
- Snapshot deletion

### QCOW2 Backing Files

QCOW2 backing files are preserved at their original absolute paths.

Consequently, the files must be restored to compatible paths on the destination host.

### Unsupported VM Disks

Block-device and unsupported network-backed VM disks are rejected when they are required VM disks.

This prevents a backup from silently missing critical data.

### Backup Integrity

Backup files are verified using:

- SHA-256 checksums
- File sizes
- QCOW2 backing-chain checks
- Disk consistency checks

The backup is only renamed from `.partial` to its final destination after verification succeeds.

### Import Safety

The import process refuses to overwrite existing or conflicting files.

This helps prevent accidental destruction of existing VM storage or metadata.

### SELinux

SELinux contexts can optionally be restored during import:

```bash
sudo ./vm-migrate.sh import --selinux /mnt/backup/windows11
```

### Imported VM State

The imported VM remains **powered off** after the import.

This allows you to inspect the VM configuration, disks, networking, and snapshot metadata before starting it.

Start the VM manually when you are ready:

```bash
virsh --connect qemu:///system start "Windows 11"
```

## Limitations

- VMs must be powered off before export.
- QCOW2 backing files must be restored to compatible absolute paths.
- Unsupported block-device and network-backed disks are rejected when required by the VM.
- The tool does not automatically resolve storage conflicts.
- The tool does not automatically merge or delete snapshots.
- The tool does not automatically start imported VMs.

## Safety Philosophy

This tool is designed to favor **data safety over automation**.

It avoids destructive storage operations and refuses to continue when it cannot produce a complete and verifiable backup.

Before starting an imported VM, always verify:

1. Domain configuration.
2. Disk paths.
3. QCOW2 backing chains.
4. Network configuration.
5. Snapshot metadata.
6. File ownership and permissions.
7. SELinux contexts, when applicable.

Only start the VM after the imported environment has been verified.
