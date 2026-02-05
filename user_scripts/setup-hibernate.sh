#!/bin/bash
set -e

# Hibernate setup script for btrfs filesystems
# Supports: plain btrfs, LUKS-encrypted btrfs, LVM
#
# Run as root: sudo ./setup-hibernate.sh [swap_size]
#
# Arguments:
#   swap_size - Optional. Size of swap file (e.g., "32G").
#               Defaults to RAM size + 2GB.
#
# What this script does:
#   1. Creates a @swap btrfs subvolume (with nodatacow)
#   2. Creates a swapfile with COW disabled (required for btrfs)
#   3. Configures fstab entries
#   4. Sets up kernel resume parameters (GRUB/systemd-boot)
#   5. Adds resume hook to initramfs (mkinitcpio/dracut)

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo ./setup-hibernate.sh)"
   exit 1
fi

# Auto-detect RAM size and add 2GB buffer
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$(( (RAM_KB / 1024 / 1024) + 2 ))
SWAP_SIZE="${1:-${RAM_GB}G}"

echo "Detected RAM: $((RAM_KB / 1024 / 1024))GB, using swap size: $SWAP_SIZE"

# Auto-detect root device
ROOT_DEV=$(findmnt -n -o SOURCE /)
# Strip btrfs subvolume notation (e.g., [/@]) if present
ROOT_DEV="${ROOT_DEV%%\[*}"
RESUME_DEV=""

if [[ "$ROOT_DEV" == /dev/mapper/luks-* ]]; then
    # Direct LUKS mapping
    RESUME_DEV="$ROOT_DEV"
    echo "Detected LUKS device: $RESUME_DEV"
elif [[ "$ROOT_DEV" == /dev/mapper/* ]]; then
    # Other device-mapper (LVM, etc.)
    RESUME_DEV="$ROOT_DEV"
    echo "Detected device-mapper device: $RESUME_DEV"
elif [[ -L "$ROOT_DEV" ]]; then
    # Resolve symlink
    RESOLVED=$(readlink -f "$ROOT_DEV")
    if [[ "$RESOLVED" == /dev/dm-* ]]; then
        # Find the mapper name
        DM_NAME=$(dmsetup info -c --noheadings -o name "$RESOLVED" 2>/dev/null | head -1)
        if [[ -n "$DM_NAME" ]]; then
            RESUME_DEV="/dev/mapper/$DM_NAME"
        fi
    else
        RESUME_DEV="$RESOLVED"
    fi
    echo "Detected device: $RESUME_DEV (via symlink)"
else
    # Direct block device (e.g., /dev/sda2, /dev/nvme0n1p2)
    RESUME_DEV="$ROOT_DEV"
    echo "Detected device: $RESUME_DEV"
fi

if [[ -z "$RESUME_DEV" ]] || [[ ! -e "$RESUME_DEV" ]]; then
    echo "Error: Could not auto-detect root device"
    echo "Detected: $ROOT_DEV"
    exit 1
fi

# Check if btrfs
ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)
if [[ "$ROOT_FSTYPE" != "btrfs" ]]; then
    echo "Error: This script is designed for btrfs filesystems"
    echo "Detected filesystem: $ROOT_FSTYPE"
    exit 1
fi

echo "Filesystem: $ROOT_FSTYPE"

echo "=== Step 1: Creating swap subvolume ==="
# Mount the btrfs root to create subvolume
TEMP_MNT=$(mktemp -d)
mount -o subvolid=5 "$RESUME_DEV" "$TEMP_MNT"

if btrfs subvolume show "$TEMP_MNT/@swap" &>/dev/null; then
    echo "Swap subvolume @swap already exists"
else
    btrfs subvolume create "$TEMP_MNT/@swap"
    echo "Created @swap subvolume"
fi
umount "$TEMP_MNT"
rmdir "$TEMP_MNT"

echo "=== Step 2: Setting up /swap mount point ==="
mkdir -p /swap

# Check if already in fstab
if grep -q "@swap" /etc/fstab; then
    echo "/swap already in fstab"
else
    echo "" >> /etc/fstab
    echo "# Swap subvolume for hibernation" >> /etc/fstab
    echo "$RESUME_DEV /swap btrfs subvol=/@swap,defaults,noatime,nodatacow 0 0" >> /etc/fstab
    echo "Added /swap to fstab"
fi

mount /swap 2>/dev/null || true

echo "=== Step 3: Creating swapfile ==="
# Calculate required size in bytes for comparison
REQUIRED_BYTES=$(numfmt --from=iec "$SWAP_SIZE")

if [[ -f /swap/swapfile ]]; then
    echo "Swapfile already exists, checking size..."
    CURRENT_SIZE=$(stat -c%s /swap/swapfile 2>/dev/null || echo 0)
    if [[ $CURRENT_SIZE -lt $REQUIRED_BYTES ]]; then
        echo "Swapfile too small ($CURRENT_SIZE < $REQUIRED_BYTES), recreating..."
        swapoff /swap/swapfile 2>/dev/null || true
        rm -f /swap/swapfile
    else
        echo "Swapfile size OK ($CURRENT_SIZE bytes)"
    fi
fi

if [[ ! -f /swap/swapfile ]]; then
    echo "Creating ${SWAP_SIZE} swapfile (this may take a moment)..."
    truncate -s 0 /swap/swapfile
    chattr +C /swap/swapfile  # Disable COW - required for btrfs swap
    fallocate -l "$SWAP_SIZE" /swap/swapfile
    chmod 600 /swap/swapfile
    mkswap /swap/swapfile
    echo "Swapfile created"
fi

echo "=== Step 4: Getting resume offset ==="
# For btrfs we need the physical offset
RESUME_OFFSET=$(filefrag -v /swap/swapfile | awk 'NR==4 {gsub(/\./,""); print $4}')
echo "Resume offset: $RESUME_OFFSET"

echo "=== Step 5: Enabling swap ==="
if swapon --show | grep -q "/swap/swapfile"; then
    echo "Swapfile already active"
else
    swapon /swap/swapfile
    echo "Swapfile activated"
fi

# Add to fstab if not present
if grep -q "/swap/swapfile" /etc/fstab; then
    echo "Swapfile already in fstab"
else
    echo "/swap/swapfile none swap defaults 0 0" >> /etc/fstab
    echo "Added swapfile to fstab"
fi

echo "=== Step 6: Configuring kernel parameters ==="
# Detect boot loader
if [[ -d /boot/loader/entries ]]; then
    BOOTLOADER="systemd-boot"
elif [[ -f /etc/default/grub ]]; then
    BOOTLOADER="grub"
else
    BOOTLOADER="unknown"
fi

echo "Detected bootloader: $BOOTLOADER"

RESUME_PARAMS="resume=UUID=$(blkid -s UUID -o value $RESUME_DEV) resume_offset=$RESUME_OFFSET"
echo "Required kernel parameters: $RESUME_PARAMS"

if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
    echo ""
    echo "For systemd-boot, add these parameters to your entry in /boot/loader/entries/*.conf:"
    echo "  $RESUME_PARAMS"
    echo ""
    # Try to auto-configure
    for entry in /boot/loader/entries/*.conf; do
        if [[ -f "$entry" ]] && ! grep -q "resume=" "$entry"; then
            echo "Updating $entry..."
            sed -i "s|^options.*|& $RESUME_PARAMS|" "$entry"
        fi
    done
elif [[ "$BOOTLOADER" == "grub" ]]; then
    if ! grep -q "resume=" /etc/default/grub; then
        sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\"|GRUB_CMDLINE_LINUX_DEFAULT=\"$RESUME_PARAMS |" /etc/default/grub
        echo "Updated /etc/default/grub"
        echo "Regenerating GRUB config..."
        grub-mkconfig -o /boot/grub/grub.cfg
    else
        echo "Resume parameters already in GRUB config"
    fi
fi

echo "=== Step 7: Configuring initramfs ==="
# For mkinitcpio (Arch-based)
if [[ -f /etc/mkinitcpio.conf ]]; then
    if grep -q "^HOOKS=.*resume" /etc/mkinitcpio.conf; then
        echo "Resume hook already in mkinitcpio.conf"
    else
        echo "Adding resume hook to mkinitcpio.conf..."
        # Add resume after udev or after filesystems
        sed -i 's/\(HOOKS=.*filesystems\)/\1 resume/' /etc/mkinitcpio.conf
        echo "Regenerating initramfs..."
        mkinitcpio -P
    fi
# For dracut (Fedora, etc.)
elif command -v dracut &>/dev/null; then
    echo "Regenerating initramfs with dracut..."
    dracut -f
fi

echo ""
echo "=== Setup Complete ==="
echo ""
swapon --show
echo ""
echo "IMPORTANT: You must REBOOT for hibernate to work!"
echo ""
echo "After reboot, test with: systemctl hibernate"
