#!/bin/bash

set -e

# Generate nginx configuration with upstream load balancing
# Reads nodes from stdin (one hostname per line)

if [ -z "$DOMAIN" ]; then
	echo "Error: DOMAIN not set" >&2
	exit 1
fi

if [ -z "$PORT" ]; then
	echo "Error: PORT not set" >&2
	exit 1
fi

if [ -z "$TARGET_PORT" ]; then
	echo "Error: TARGET_PORT not set" >&2
	exit 1
fi

# Determine proxy command (proxy or grpc)
PROXY_CMD="proxy"
if [[ "${TARGET_ENDPOINT}" == grpc://* ]] || [[ "${PROTOCOL}" == "grpc" ]]; then
	PROXY_CMD="grpc"
fi

# Read nodes from stdin into an array
mapfile -t NODES

if [ ${#NODES[@]} -eq 0 ]; then
	echo "Error: No backend nodes provided" >&2
	exit 1
fi

# Generate upstream block
UPSTREAM_SERVERS=""
for node in "${NODES[@]}"; do
	# Remove any whitespace
	node=$(echo "$node" | xargs)
	if [ -n "$node" ]; then
		# Add server with passive health check parameters (backup layer)
		# Note: Only healthy nodes are included (pre-filtered by active checks)
		# max_fails=2: mark server as unavailable after 2 failed requests
		# fail_timeout=30s: time to consider server unavailable before retry
		UPSTREAM_SERVERS="${UPSTREAM_SERVERS}    server ${node}:${TARGET_PORT} max_fails=2 fail_timeout=30s;\n"
	fi
done

if [ -z "$UPSTREAM_SERVERS" ]; then
	echo "Error: No valid backend nodes" >&2
	exit 1
fi

# Prepare client_max_body_size configuration
CLIENT_MAX_BODY_SIZE_CONF=""
if [ -n "$CLIENT_MAX_BODY_SIZE" ]; then
	CLIENT_MAX_BODY_SIZE_CONF="    client_max_body_size ${CLIENT_MAX_BODY_SIZE};"
fi

# Generate the full nginx configuration
cat <<EOF
upstream backend {
$(echo -e "$UPSTREAM_SERVERS")
    # Round-robin load balancing (default)
    # Two-layer health checking:
    # 1. Active checks: Only healthy nodes included (checked every 60s by daemon)
    # 2. Passive checks: Backup layer via max_fails/fail_timeout
}

server {
    listen ${PORT} ssl;
    http2 on;
    server_name ${DOMAIN};

    # SSL certificate configuration
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    # Modern SSL configuration - TLS 1.2 and 1.3 only
    ssl_protocols TLSv1.2 TLSv1.3;

    # Strong cipher suites - Only AES-GCM and ChaCha20-Poly1305
    ssl_ciphers 'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';

    # Prefer server cipher suites
    ssl_prefer_server_ciphers on;

    # ECDH curve for ECDHE ciphers
    ssl_ecdh_curve secp384r1;

    # Enable OCSP stapling
    ssl_stapling on;
    ssl_stapling_verify on;
    ssl_trusted_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;

    # SSL session configuration
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;

    # SSL buffer size (optimized for TLS 1.3)
    ssl_buffer_size 4k;

    # Disable SSL renegotiation
    ssl_early_data off;
${CLIENT_MAX_BODY_SIZE_CONF}

    # WebSocket support - handles both /ws/ and /socket.io/ paths
    location ~ ^/(ws|socket\.io)/ {
        ${PROXY_CMD}_pass http://backend;
        ${PROXY_CMD}_http_version 1.1;

        ${PROXY_CMD}_set_header Upgrade \$http_upgrade;
        ${PROXY_CMD}_set_header Connection "upgrade";

        ${PROXY_CMD}_set_header Host \$host;
        ${PROXY_CMD}_set_header X-Real-IP \$remote_addr;
        ${PROXY_CMD}_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        ${PROXY_CMD}_set_header X-Forwarded-Proto \$scheme;

        ${PROXY_CMD}_cache_bypass \$http_upgrade;

        # Socket.IO optimized timeouts
        ${PROXY_CMD}_read_timeout 3600;    # 1 hour
        ${PROXY_CMD}_send_timeout 3600;    # 1 hour
        ${PROXY_CMD}_connect_timeout 600;  # 20 minute
    }

    # Regular HTTP requests
    location / {
        ${PROXY_CMD}_pass http://backend;
        ${PROXY_CMD}_set_header Host \$host;
        ${PROXY_CMD}_set_header X-Real-IP \$remote_addr;
        ${PROXY_CMD}_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        ${PROXY_CMD}_set_header X-Forwarded-Proto \$scheme;
    }

    location /evidences/ {
        alias /evidences/;
        autoindex on;
    }
}
EOF
