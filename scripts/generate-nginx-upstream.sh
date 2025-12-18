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

# Rate limiting configuration
# RATE_LIMIT_ENABLED: enable/disable rate limiting (default: false)
# RATE_LIMIT_RATE: requests per second (default: 10r/s)
# RATE_LIMIT_BURST: burst size (default: 20)
# RATE_LIMIT_PATHS: comma-separated paths to rate limit
#   If set, rate limiting is applied only to these paths. If not set and RATE_LIMIT_ENABLED=true,
#   rate limiting is applied to all requests (location /)
RATE_LIMIT_ENABLED="${RATE_LIMIT_ENABLED:-false}"
RATE_LIMIT_BURST="${RATE_LIMIT_BURST:-20}"
RATE_LIMIT_RATE="${RATE_LIMIT_RATE:-10r/s}"
RATE_LIMIT_PATHS="${RATE_LIMIT_PATHS:-}"
RATE_LIMIT_LOCATION_CONF=""
RATE_LIMIT_PATH_BLOCKS=""
RATE_LIMIT_ZONE_CONF=""

if [ "${RATE_LIMIT_ENABLED,,}" = "true" ]; then
	# Rate limiting zone (must be in http context, which conf.d files are included in)
	RATE_LIMIT_ZONE_CONF="# Rate limiting zone - IP-based rate limiting
limit_req_zone \$binary_remote_addr zone=ip_limit:10m rate=${RATE_LIMIT_RATE};
"

	# If RATE_LIMIT_PATHS is set, create specific location blocks for those paths
	if [ -n "$RATE_LIMIT_PATHS" ]; then
		# Split comma-separated paths and create location blocks
		IFS=',' read -ra PATHS <<< "$RATE_LIMIT_PATHS"
		for path in "${PATHS[@]}"; do
			# Trim whitespace
			path=$(echo "$path" | xargs)
			if [ -n "$path" ]; then
				RATE_LIMIT_PATH_BLOCKS="${RATE_LIMIT_PATH_BLOCKS}
    # Rate-limited path: ${path}
    location ${path} {
        limit_req zone=ip_limit burst=${RATE_LIMIT_BURST} nodelay;
        ${PROXY_CMD}_pass http://backend;
        ${PROXY_CMD}_set_header Host \$host;
        ${PROXY_CMD}_set_header X-Real-IP \$remote_addr;
        ${PROXY_CMD}_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        ${PROXY_CMD}_set_header X-Forwarded-Proto \$scheme;

        # Timeout configuration
        ${PROXY_CMD}_read_timeout 600;
        ${PROXY_CMD}_send_timeout 600;
        ${PROXY_CMD}_connect_timeout 10;

        # Retry on another backend for connection errors and 5XX responses
        ${PROXY_CMD}_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;
        ${PROXY_CMD}_next_upstream_tries 2;
        ${PROXY_CMD}_next_upstream_timeout 30s;
    }"
			fi
		done
	else
		# Apply rate limiting to general location / if no specific paths are set
		RATE_LIMIT_LOCATION_CONF="        limit_req zone=ip_limit burst=${RATE_LIMIT_BURST} nodelay;"
	fi
fi

# Generate the full nginx configuration
cat <<EOF
${RATE_LIMIT_ZONE_CONF}
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

        # Retry on another backend if this one fails (connection errors only for WebSocket)
        ${PROXY_CMD}_next_upstream error timeout invalid_header;
        ${PROXY_CMD}_next_upstream_tries 2;
    }
${RATE_LIMIT_PATH_BLOCKS}
    # Regular HTTP requests
    location / {
${RATE_LIMIT_LOCATION_CONF}
        ${PROXY_CMD}_pass http://backend;
        ${PROXY_CMD}_set_header Host \$host;
        ${PROXY_CMD}_set_header X-Real-IP \$remote_addr;
        ${PROXY_CMD}_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        ${PROXY_CMD}_set_header X-Forwarded-Proto \$scheme;

        # Timeout configuration for long-running requests
        ${PROXY_CMD}_read_timeout 600;     # 10 minutes
        ${PROXY_CMD}_send_timeout 600;     # 10 minutes
        ${PROXY_CMD}_connect_timeout 10;   # 10 seconds

        # Retry on another backend for connection errors and 5XX responses
        ${PROXY_CMD}_next_upstream error timeout invalid_header http_500 http_502 http_503 http_504;
        ${PROXY_CMD}_next_upstream_tries 2;
        ${PROXY_CMD}_next_upstream_timeout 30s;
    }

    location /evidences/ {
        alias /evidences/;
        autoindex on;
    }
}
EOF
