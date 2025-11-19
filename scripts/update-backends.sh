#!/bin/bash

set -e

# Background daemon to update nginx backend nodes
# Runs every 60 seconds, discovers Tailscale nodes, and updates nginx config if nodes changed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODES_FILE="/tmp/current_nodes.txt"
UPDATE_INTERVAL=60

echo "Backend update daemon started (interval: ${UPDATE_INTERVAL}s)"
echo "Script directory: ${SCRIPT_DIR}"
echo "Target node prefix: ${TARGET_NODE_PREFIX}"
echo "Target port: ${TARGET_PORT}"
echo "Health check path: ${NODE_HEALTH_CHECK:-"(not set)"}"

# Verify required scripts exist
if [ ! -f "${SCRIPT_DIR}/discover-nodes.sh" ]; then
    echo "Error: discover-nodes.sh not found in ${SCRIPT_DIR}"
    exit 1
fi
if [ ! -f "${SCRIPT_DIR}/generate-nginx-upstream.sh" ]; then
    echo "Error: generate-nginx-upstream.sh not found in ${SCRIPT_DIR}"
    exit 1
fi

# Function to discover and update backends
update_backends() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Discovering backend nodes..."

    # Discover nodes matching the prefix
    # Stderr passes through to system logs
    DISCOVERY_OUTPUT=$("${SCRIPT_DIR}/discover-nodes.sh")
    DISCOVERY_EXIT=$?

    if [ $DISCOVERY_EXIT -ne 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Warning: Failed to discover nodes (check logs for details)"
        return 1
    fi

    DISCOVERED_NODES="$DISCOVERY_OUTPUT"

    # Count discovered nodes (count non-empty lines)
    if [ -z "$DISCOVERED_NODES" ]; then
        NODE_COUNT=0
    else
        NODE_COUNT=$(echo "$DISCOVERED_NODES" | wc -l | tr -d ' ')
    fi

    if [ "$NODE_COUNT" -eq 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Warning: No nodes matching prefix '${TARGET_NODE_PREFIX}' found. Will retry..."
        return 1
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Found ${NODE_COUNT} node(s), checking health..."

    # Health check each node in parallel and filter to only healthy ones
    TMP_RESULTS_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_RESULTS_DIR"' RETURN

    check_node_health() {
        local node=$1
        local output_file=$2
        
        if [ -z "$node" ]; then
            return
        fi

        # Perform health check
        if [ -n "$NODE_HEALTH_CHECK" ]; then
            # HTTP health check
            HEALTH_URL="http://${node}:${TARGET_PORT}${NODE_HEALTH_CHECK}"
            if curl -sf --connect-timeout 5 --max-time 10 "$HEALTH_URL" >/dev/null 2>&1; then
                echo "  - $node [HEALTHY]"
                echo "$node" >> "$output_file"
            else
                echo "  - $node [UNHEALTHY] - removing from pool"
            fi
        else
            # TCP port check only
            if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${node}/${TARGET_PORT}" 2>/dev/null; then
                echo "  - $node [HEALTHY]"
                echo "$node" >> "$output_file"
            else
                echo "  - $node [UNHEALTHY] - removing from pool"
            fi
        fi
    }

    # Loop through nodes and start background checks
    while read -r node; do
        if [ -n "$node" ]; then
            check_node_health "$node" "${TMP_RESULTS_DIR}/nodes" &
        fi
    done <<< "$DISCOVERED_NODES"
    
    # Wait for all background jobs to finish
    wait

    # Collect healthy nodes
    if [ -f "${TMP_RESULTS_DIR}/nodes" ]; then
        HEALTHY_NODES=$(cat "${TMP_RESULTS_DIR}/nodes")
    else
        HEALTHY_NODES=""
    fi

    # Count healthy nodes
    if [ -z "$HEALTHY_NODES" ]; then
        HEALTHY_COUNT=0
    else
        HEALTHY_COUNT=$(echo "$HEALTHY_NODES" | wc -l | tr -d ' ')
    fi

    if [ "$HEALTHY_COUNT" -eq 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Warning: No healthy nodes found. Will retry..."
        return 1
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${HEALTHY_COUNT} healthy node(s) available"

    # Use healthy nodes for comparison
    DISCOVERED_NODES="$HEALTHY_NODES"

    # Check if nodes have changed
    NODES_CHANGED=false
    if [ -f "$NODES_FILE" ]; then
        if ! diff -q <(echo "$DISCOVERED_NODES" | sort) <(sort "$NODES_FILE") >/dev/null 2>&1; then
            NODES_CHANGED=true
        fi
    else
        NODES_CHANGED=true
    fi

    if [ "$NODES_CHANGED" = true ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backend nodes changed, updating nginx configuration..."

        # Generate new nginx configuration
        NEW_CONFIG=$(echo "$DISCOVERED_NODES" | "${SCRIPT_DIR}/generate-nginx-upstream.sh" 2>&1) || {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Failed to generate nginx config: $NEW_CONFIG"
            return 1
        }

        # Write new configuration
        echo "$NEW_CONFIG" > /etc/nginx/conf.d/default.conf

        # Test nginx configuration
        if ! nginx -t 2>&1; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Invalid nginx configuration, not reloading"
            return 1
        fi

        # Reload nginx gracefully
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Reloading nginx..."
        nginx -s reload

        # Save current nodes
        echo "$DISCOVERED_NODES" > "$NODES_FILE"

        # Save VPC_SERVER_APP_ID and healthy node hostnames into /evidences/vpc.json
        if [ -n "$VPC_SERVER_APP_ID" ]; then
            if [ -n "$DISCOVERED_NODES" ]; then
                HOSTNAMES_JSON=$(printf '%s\n' "$DISCOVERED_NODES" | jq -R . | jq -s .)
            else
                HOSTNAMES_JSON="[]"
            fi
            mkdir -p /evidences
            if ! jq -n --arg vpc_server_app_id "$VPC_SERVER_APP_ID" --argjson nodes "$HOSTNAMES_JSON" \
                '{vpc_server_app_id: $vpc_server_app_id, nodes: $nodes}' > /evidences/vpc.json; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] Error: Failed to write /evidences/vpc.json"
                return 1
            fi
        fi

        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backend update completed successfully"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] No changes detected, skipping update"
    fi
}

# Initial update - keep retrying until we have at least one node
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Performing initial backend discovery..."
while true; do
    if update_backends; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Initial backend configuration completed"
        break
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Retrying in ${UPDATE_INTERVAL} seconds..."
    sleep "$UPDATE_INTERVAL"
done

# Main loop - continue checking for updates
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting periodic backend monitoring..."
while true; do
    sleep "$UPDATE_INTERVAL"

    # Update backends (non-fatal if it fails)
    update_backends || true
done
