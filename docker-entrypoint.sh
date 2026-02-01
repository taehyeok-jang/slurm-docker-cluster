#!/bin/bash
set -e

# Check if auth_jwt plugin is available (for slurmdbd/slurmctld)
check_jwt_auth_plugin() {
    echo "---> Checking for JWT authentication plugin..."
    JWT_PLUGIN_AVAILABLE=false
    for PLUGIN_DIR in /usr/lib/slurm /usr/lib64/slurm /usr/libexec/slurm; do
        if [ -f "${PLUGIN_DIR}/auth_jwt.so" ] || [ -f "${PLUGIN_DIR}/auth_jwt" ]; then
            JWT_PLUGIN_AVAILABLE=true
            break
        fi
    done
}

# Remove JWT config from a Slurm config file if JWT plugin is not available
strip_jwt_from_conf() {
    echo "---> Stripping JWT configuration from $1"
    local conf_file="$1"
    if [ "$JWT_PLUGIN_AVAILABLE" != "true" ]; then
        echo "---> JWT plugin not available, removing JWT configuration from $conf_file"
        sed '/^AuthType=auth\/jwt$/d; /^AuthAltTypes=auth\/jwt/d; /^AuthAltParameters=jwt_key=/d' \
            "$conf_file" > "${conf_file}.tmp"
        mv "${conf_file}.tmp" "$conf_file"
        if ! grep -q "^AuthType=" "$conf_file"; then
            echo "AuthType=auth/munge" >> "$conf_file"
        fi
    fi
}

echo "---> Starting the MUNGE Authentication service (munged) ..."
gosu munge /usr/sbin/munged

if [ "$1" = "slurmdbd" ]
then
    echo "---> Starting the Slurm Database Daemon (slurmdbd) ..."

    check_jwt_auth_plugin
    [ "$JWT_PLUGIN_AVAILABLE" = "true" ] && echo "---> JWT authentication plugin found"

    if [ "$JWT_PLUGIN_AVAILABLE" = "true" ] && [ ! -f /var/lib/slurm/jwt_hs256.key ]; then
        echo "---> Creating JWT key for slurmdbd..."
        /usr/local/bin/init-jwt-key.sh /var/lib/slurm
    fi
    [ -f /var/lib/slurm/jwt_hs256.key ] && chgrp slurmjwt /var/lib/slurm/jwt_hs256.key && chmod 0640 /var/lib/slurm/jwt_hs256.key

    # Substitute environment variables in slurmdbd.conf
    envsubst < /etc/slurm/slurmdbd.conf > /etc/slurm/slurmdbd.conf.tmp
    mv /etc/slurm/slurmdbd.conf.tmp /etc/slurm/slurmdbd.conf

    # strip_jwt_from_conf /etc/slurm/slurmdbd.conf

    chown slurm:slurm /etc/slurm/slurmdbd.conf
    chmod 600 /etc/slurm/slurmdbd.conf

    # Wait for MySQL using environment variables directly
    until echo "SELECT 1" | mysql -h mysql -u${MYSQL_USER} -p${MYSQL_PASSWORD} 2>&1 > /dev/null
    do
        echo "-- Waiting for database to become active ..."
        sleep 2
    done
    echo "-- Database is now active ..."

    exec gosu slurm /usr/sbin/slurmdbd -Dvvv
    # exec tail -f /dev/null
fi

if [ "$1" = "slurmctld" ]
then
    echo "---> Waiting for slurmdbd to become active before starting slurmctld ..."

    until 2>/dev/null >/dev/tcp/slurmdbd/6819
    do
        echo "-- slurmdbd is not available.  Sleeping ..."
        sleep 2
    done
    echo "-- slurmdbd is now active ..."

    check_jwt_auth_plugin
    [ "$JWT_PLUGIN_AVAILABLE" = "true" ] && echo "---> JWT authentication plugin found (slurmctld check)"

    if [ "$JWT_PLUGIN_AVAILABLE" = "true" ] && [ ! -f /var/lib/slurm/jwt_hs256.key ]; then
        echo "---> Creating JWT key for slurmctld..."
        /usr/local/bin/init-jwt-key.sh /var/lib/slurm
    fi
    [ -f /var/lib/slurm/jwt_hs256.key ] && chgrp slurmjwt /var/lib/slurm/jwt_hs256.key && chmod 0640 /var/lib/slurm/jwt_hs256.key

    echo "---> Starting the Slurm Controller Daemon (slurmctld) ..."
    exec gosu slurm /usr/sbin/slurmctld -i -Dvvv
fi

if [ "$1" = "slurmrestd" ]
then
    echo "---> Waiting for slurmctld to become active before starting slurmrestd ..."

    until 2>/dev/null >/dev/tcp/slurmctld/6817
    do
        echo "-- slurmctld is not available.  Sleeping ..."
        sleep 2
    done
    echo "-- slurmctld is now active ..."

    # Check available REST authentication plugins
    JWT_PLUGIN_AVAILABLE=false
    MUNGE_PLUGIN_AVAILABLE=false
    
    for PLUGIN_DIR in /usr/lib/slurm /usr/lib64/slurm /usr/libexec/slurm; do
        # Check for JWT plugin
        if [ -f "${PLUGIN_DIR}/rest_auth_jwt.so" ] || [ -f "${PLUGIN_DIR}/rest_auth/jwt.so" ] || \
           [ -f "${PLUGIN_DIR}/rest_auth_jwt" ] || [ -f "${PLUGIN_DIR}/rest_auth/jwt" ]; then
            JWT_PLUGIN_AVAILABLE=true
        fi
        # Check for MUNGE/local plugin
        if [ -f "${PLUGIN_DIR}/rest_auth_local.so" ] || [ -f "${PLUGIN_DIR}/rest_auth/local.so" ] || \
           [ -f "${PLUGIN_DIR}/rest_auth_local" ] || [ -f "${PLUGIN_DIR}/rest_auth/local" ]; then
            MUNGE_PLUGIN_AVAILABLE=true
        fi
    done

    echo "---> Starting the Slurm REST API Daemon (slurmrestd) ..."
    # Run slurmrestd on both Unix socket and network port
    # Unix socket provides passwordless local access
    # Note: slurmrestd should NOT be run as SlurmUser or root (security requirement)
    mkdir -p /var/run/slurmrestd
    chown slurmrest:slurmrest /var/run/slurmrestd
    
    # Determine authentication plugins to use
    AUTH_PLUGINS=""
    if [ "$JWT_PLUGIN_AVAILABLE" = "true" ]; then
        echo "---> JWT REST authentication plugin found"
        AUTH_PLUGINS="rest_auth/jwt"
        mkdir -p /var/spool/slurm
        chown slurm:slurm /var/spool/slurm
    fi
    
    if [ "$MUNGE_PLUGIN_AVAILABLE" = "true" ]; then
        echo "---> MUNGE/local REST authentication plugin found"
        if [ -n "$AUTH_PLUGINS" ]; then
            AUTH_PLUGINS="$AUTH_PLUGINS,rest_auth/local"
        else
            AUTH_PLUGINS="rest_auth/local"
        fi
    fi
    
    # Start slurmrestd with appropriate authentication plugins.
    # SLURM_JWT=daemon activates auth/jwt as primary auth (see slurm.schedmd.com/jwt.html).
    if [ -n "$AUTH_PLUGINS" ]; then
        echo "---> Using authentication plugins: $AUTH_PLUGINS"
        export SLURM_JWT=daemon
        exec gosu slurmrest /usr/sbin/slurmrestd -a "$AUTH_PLUGINS" -vvv unix:/var/run/slurmrestd/slurmrestd.socket 0.0.0.0:6820
    else
        echo "---> No specific auth plugins found, using defaults (Unix socket only)"
        exec gosu slurmrest /usr/sbin/slurmrestd -vvv unix:/var/run/slurmrestd/slurmrestd.socket 0.0.0.0:6820
    fi
fi

if [ "$1" = "slurmd" ]
then
    echo "---> Waiting for slurmctld to become active before starting slurmd..."

    until 2>/dev/null >/dev/tcp/slurmctld/6817
    do
        echo "-- slurmctld is not available.  Sleeping ..."
        sleep 2
    done
    echo "-- slurmctld is now active ..."

    # Extract container name from cgroup path
    # Docker Compose sets container name to c1, c2, etc.
    # We can find this in the cgroup path
    CONTAINER_NAME=""

    # Try reading from /proc/self/cgroup (works in cgroup v1 and v2)
    if [ -f /proc/self/cgroup ]; then
        # Extract container name from cgroup path
        # Format: 0::/docker/<container_id> or similar
        CONTAINER_NAME=$(cat /proc/self/cgroup | sed -n 's|.*/docker/\([^/]*\).*|\1|p' | head -1)
    fi

    # If we got a container ID, try to resolve it to a name using the host's /proc
    if [ -n "$CONTAINER_NAME" ] && [ -d "/host_proc" ]; then
        # Try to find the container name by looking at cmdline or environ
        # This is a fallback - we'll use the cgroup container ID to query Docker
        echo "---> Container ID from cgroup: $CONTAINER_NAME"
    fi

    # Fallback: try to extract from /proc/1/cpuset which often contains container name
    if [ -z "$CONTAINER_NAME" ] || [ ${#CONTAINER_NAME} -eq 64 ]; then
        # We only have a container ID, need the actual name
        # Try cpuset path which may have the name
        if [ -f /proc/1/cpuset ]; then
            CPUSET_PATH=$(cat /proc/1/cpuset)
            # Extract last component which might be container name
            CONTAINER_NAME=$(basename "$CPUSET_PATH")
            echo "---> Container name from cpuset: $CONTAINER_NAME"
        fi
    fi

    # If container name looks like c1, c2, use it directly
    if [[ "$CONTAINER_NAME" =~ ^c[0-9]+$ ]]; then
        echo "---> Using container name as hostname: $CONTAINER_NAME"
        hostname "$CONTAINER_NAME"
    else
        echo "---> WARNING: Could not determine proper container name"
        echo "---> Got: $CONTAINER_NAME"
        echo "---> Using fallback hostname"
    fi

    NODE_HOSTNAME=$(hostname)
    echo "---> Final hostname: $NODE_HOSTNAME"
    echo "---> Starting the Slurm Node Daemon (slurmd) as $NODE_HOSTNAME..."
    exec /usr/sbin/slurmd -Dvvv
fi

exec "$@"
