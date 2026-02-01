#!/bin/bash
# Script to generate a JWT token for Slurm REST API authentication
# Usage: ./generate-jwt-token.sh [lifetime_in_seconds]
# Default lifetime: 3600 seconds (1 hour)

set -e

LIFETIME=${1:-3600}
CONTAINER_NAME="slurmctld"

echo "=== Generating JWT Token for Slurm REST API ==="
echo "Lifetime: ${LIFETIME} seconds ($(($LIFETIME / 60)) minutes)"

# Check if container is running
if ! docker ps | grep -q "$CONTAINER_NAME"; then
    echo "Error: Container $CONTAINER_NAME is not running"
    echo "Please start the Slurm cluster first: make up"
    exit 1
fi

# Check if JWT plugin is available
JWT_PLUGIN_AVAILABLE=false
for PLUGIN_DIR in /usr/lib/slurm /usr/lib64/slurm /usr/libexec/slurm; do
    if docker exec "$CONTAINER_NAME" test -f "${PLUGIN_DIR}/auth_jwt.so" 2>/dev/null || \
       docker exec "$CONTAINER_NAME" test -f "${PLUGIN_DIR}/auth_jwt" 2>/dev/null; then
        JWT_PLUGIN_AVAILABLE=true
        break
    fi
done

if [ "$JWT_PLUGIN_AVAILABLE" != "true" ]; then
    echo "Error: JWT plugin is not available in the container"
    echo ""
    echo "Alternative: Use Unix socket from inside the container:"
    echo "  docker exec slurmrestd curl --unix-socket /var/run/slurmrestd/slurmrestd.socket http://localhost/slurm/v0.0.40/ping"
    echo ""
    echo "Or configure JWT authentication by:"
    echo "  1. Ensuring JWT plugin is built with Slurm"
    echo "  2. Restarting the cluster"
    exit 1
fi

# JWT key is NOT auto-generated; admin must create it (see REST_API_AUTH.md or init-jwt-key.sh)
JWT_KEY_PATH="/var/lib/slurm/jwt_hs256.key"
echo "Checking JWT key at $JWT_KEY_PATH..."
if ! docker exec "$CONTAINER_NAME" test -f "$JWT_KEY_PATH" 2>/dev/null; then
    echo "Error: JWT key not found. jwt_hs256.key must be created by the Slurm admin."
    echo ""
    echo "Create the key inside the slurmctld container:"
    echo "  docker exec -it slurmctld ./init-jwt-key.sh"
    echo "Or manually (as root in container):"
    echo "  cd /var/lib/slurm"
    echo "  dd if=/dev/urandom of=jwt_hs256.key bs=32 count=1"
    echo "  chown slurm:slurm jwt_hs256.key"
    echo "  chmod 0600 jwt_hs256.key"
    echo ""
    echo "Then restart: docker compose restart slurmctld slurmrestd"
    exit 1
fi

# Generate token using scontrol
echo "Generating token..."
TOKEN_OUTPUT=$(docker exec "$CONTAINER_NAME" scontrol token lifespan="$LIFETIME" 2>&1)

# Extract token from output (handle different output formats)
TOKEN=$(echo "$TOKEN_OUTPUT" | grep -iE "(token|jwt)" | grep -oE "[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+" | head -1)

# If no token found in expected format, try to get the last line that looks like a token
if [ -z "$TOKEN" ]; then
    TOKEN=$(echo "$TOKEN_OUTPUT" | grep -oE "[A-Za-z0-9_-]{20,}" | tail -1)
fi

# If still no token, try getting the entire last line
if [ -z "$TOKEN" ]; then
    TOKEN=$(echo "$TOKEN_OUTPUT" | tail -1 | tr -d '[:space:]')
fi

if [ -z "$TOKEN" ]; then
    echo "Error: Failed to generate token. Output was:"
    echo "$TOKEN_OUTPUT"
    echo ""
    echo "Make sure:"
    echo "  1. slurmctld is running and healthy"
    echo "  2. JWT key exists at /var/lib/slurm/jwt_hs256.key (create with init-jwt-key.sh if needed)"
    echo "  3. JWT is configured in slurm.conf (AuthAltTypes=auth/jwt)"
    exit 1
fi

# Get current user (default to root if running as root in container)
USERNAME=$(docker exec "$CONTAINER_NAME" whoami 2>/dev/null || echo "root")

echo ""
echo "=== JWT Token Generated Successfully ==="
echo ""
echo "Token: $TOKEN"
echo "Username: $USERNAME"
echo "Lifetime: ${LIFETIME} seconds"
echo ""
echo "=== Usage Examples ==="
echo ""
echo "1. Test REST API with curl:"
echo "   curl -H \"X-SLURM-USER-NAME: $USERNAME\" \\"
echo "        -H \"X-SLURM-USER-TOKEN: $TOKEN\" \\"
echo "        http://localhost:6820/slurm/v0.0.40/ping"
echo ""
echo "2. Get cluster information:"
echo "   curl -H \"X-SLURM-USER-NAME: $USERNAME\" \\"
echo "        -H \"X-SLURM-USER-TOKEN: $TOKEN\" \\"
echo "        http://localhost:6820/slurm/v0.0.40/cluster"
echo ""
echo "3. Get nodes:"
echo "   curl -H \"X-SLURM-USER-NAME: $USERNAME\" \\"
echo "        -H \"X-SLURM-USER-TOKEN: $TOKEN\" \\"
echo "        http://localhost:6820/slurm/v0.0.40/nodes"
echo ""
echo "4. Get jobs:"
echo "   curl -H \"X-SLURM-USER-NAME: $USERNAME\" \\"
echo "        -H \"X-SLURM-USER-TOKEN: $TOKEN\" \\"
echo "        http://localhost:6820/slurm/v0.0.40/jobs"
echo ""
