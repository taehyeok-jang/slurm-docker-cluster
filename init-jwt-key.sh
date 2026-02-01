#!/bin/bash
# Create JWT HS256 key for Slurm REST API authentication.
# jwt_hs256.key is NOT auto-generated; the Slurm admin must create it.
# Run this script as root (e.g. inside slurmctld: docker exec slurmctld /path/to/init-jwt-key.sh)
#
# Key location: StateSaveLocation (/var/lib/slurm). Permissions: slurm:slurm, 0600.

set -e

KEY_DIR="${1:-/var/lib/slurm}"
KEY_FILE="${KEY_DIR}/jwt_hs256.key"

if [ ! -d "$KEY_DIR" ]; then
    echo "Error: Directory $KEY_DIR does not exist (StateSaveLocation)."
    exit 1
fi

if [ -f "$KEY_FILE" ]; then
    echo "jwt_hs256.key already exists at $KEY_FILE. Remove it first if you want to regenerate."
    exit 0
fi

echo "Creating 32-byte (256-bit) random key at $KEY_FILE ..."
dd if=/dev/urandom of="$KEY_FILE" bs=32 count=1
chown slurm:slurmjwt "$KEY_FILE"
chmod 0640 "$KEY_FILE"
echo "Done. Key created with slurm:slurmjwt ownership and mode 0640 (group slurmjwt so slurmrestd can verify JWTs without being in SlurmUser's group)."
echo "Restart slurmctld and slurmrestd if they are already running: docker compose restart slurmctld slurmrestd"
