Libvirt/KVM VM Migration Tool

A Bash utility for safely exporting and importing libvirt/KVM virtual machines, including QCOW2 backing chains and snapshot metadata.

Features
Exports only powered-off VMs.
Preserves original absolute disk paths and QCOW2 backing chains.
Exports libvirt domain and snapshot metadata.
Supports file-backed disks and libvirt storage-pool volumes.
Refuses to create incomplete backups when unsupported VM disks are detected.
Verifies backup files with SHA-256 checksums and file sizes.
Refuses to overwrite existing or conflicting files during import.
Optionally restores SELinux contexts with --selinux.
Does not automatically merge, commit, rebase, or delete snapshots.
Performs QCOW2 backing-chain and disk consistency checks.
Does not automatically start an imported VM.
Requirements

The script requires:

virsh
qemu-img
python3
sha256sum
Standard Unix utilities such as cp, mv, stat, find, awk, and grep

Run it with sufficient privileges, typically using sudo.

Usage
Export

The VM must be completely shut down:

sudo ./vm-migrate.sh export "VM_NAME" /path/to/backup


Example:

sudo ./vm-migrate.sh export "Windows 11" /mnt/backup/windows11


The backup is first created as a .partial directory and renamed to its final destination only after verification succeeds.

Import
sudo ./vm-migrate.sh import /path/to/backup


Example:

sudo ./vm-migrate.sh import /mnt/backup/windows11


To restore SELinux contexts:

sudo ./vm-migrate.sh import --selinux /mnt/backup/windows11


After import, inspect the VM before starting it:

virsh --connect qemu:///system start "Windows 11"

Backup Layout

A typical backup contains:

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

Important Notes

The script intentionally does not perform destructive or modifying storage operations such as qemu-img commit, qemu-img rebase, blockpull, blockcommit, snapshot merging, or snapshot deletion.

QCOW2 backing files are preserved at their original absolute paths. Consequently, the files must be restored to compatible paths on the destination host.

Block-device and unsupported network-backed VM disks are rejected when they are required VM disks, preventing a backup from silently missing critical data.

The imported VM remains powered off so it can be inspected before first boot.
