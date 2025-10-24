#!/bin/bash

set -e

# Discover Tailscale nodes matching the TARGET_NODE_PREFIX
# Outputs one hostname per line

if [ -z "$TARGET_NODE_PREFIX" ]; then
    echo "Error: TARGET_NODE_PREFIX not set" >&2
    exit 1
fi

# Get tailscale status as JSON
TAILSCALE_STATUS=$(tailscale status --json 2>&1)
TAILSCALE_EXIT=$?

if [ $TAILSCALE_EXIT -ne 0 ]; then
    echo "Error: Failed to get tailscale status (exit code: $TAILSCALE_EXIT)" >&2
    echo "Output: $TAILSCALE_STATUS" >&2
    exit 1
fi

# Validate JSON
if ! echo "$TAILSCALE_STATUS" | jq empty 2>/dev/null; then
    echo "Error: tailscale status returned invalid JSON" >&2
    echo "First 200 chars: ${TAILSCALE_STATUS:0:200}" >&2
    exit 1
fi

# Debug: Log all available nodes to stderr for troubleshooting
echo "Debug: Available Tailscale nodes:" >&2
echo "$TAILSCALE_STATUS" | jq -r '.Peer // {} | to_entries[] | "  Peer: \(.value.HostName) (\(.value.DNSName // "no DNS"))"' >&2
echo "$TAILSCALE_STATUS" | jq -r '.Self // {} | "  Self: \(.HostName) (\(.DNSName // "no DNS"))"' >&2
echo "Debug: Looking for nodes with prefix: $TARGET_NODE_PREFIX" >&2

# Parse JSON to find nodes matching the prefix
# Extract the hostname/DNSName for each matching node
{
    echo "$TAILSCALE_STATUS" | jq -r --arg prefix "$TARGET_NODE_PREFIX" '
        .Peer // {} |
        to_entries[] |
        select(.value.HostName | startswith($prefix)) |
        .value.DNSName // .value.HostName
    ' | sed 's/\.$//' # Remove trailing dot from DNS names

    # Also check self if it matches
    echo "$TAILSCALE_STATUS" | jq -r --arg prefix "$TARGET_NODE_PREFIX" '
        .Self // {} |
        select(.HostName | startswith($prefix)) |
        .DNSName // .HostName
    ' | sed 's/\.$//'
} | grep -v '^$' # Filter out empty lines
