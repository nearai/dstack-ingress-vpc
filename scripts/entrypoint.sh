#!/bin/bash

set -e

PORT=${PORT:-443}
TXT_PREFIX=${TXT_PREFIX:-"_dstack-app-address"}
PROXY_CMD="proxy"
if [[ "${TARGET_ENDPOINT}" == grpc://* ]]; then
	PROXY_CMD="grpc"
fi

setup_py_env() {
	if [ ! -d /opt/app-venv ]; then
		echo "Creating application virtual environment"
		python3 -m venv --system-site-packages /opt/app-venv
	fi

	# Activate venv for subsequent steps
	# shellcheck disable=SC1091
	source /opt/app-venv/bin/activate

	if [ ! -f /.venv_bootstrapped ]; then
		echo "Bootstrapping certbot dependencies"
		pip install --upgrade pip
		pip install certbot requests
		touch /.venv_bootstrapped
	fi

	ln -sf /opt/app-venv/bin/certbot /usr/local/bin/certbot
	echo 'source /opt/app-venv/bin/activate' >/etc/profile.d/app-venv.sh
}

setup_certbot_env() {
	# Ensure the virtual environment is active for certbot configuration
	# shellcheck disable=SC1091
	source /opt/app-venv/bin/activate

	# Use the unified certbot manager to install plugins and setup credentials
	echo "Installing DNS plugins and setting up credentials"
	certman.py setup
	if [ $? -ne 0 ]; then
		echo "Error: Failed to setup certbot environment"
		exit 1
	fi
}

setup_py_env

setup_nginx_conf() {
	local client_max_body_size_conf=""
	if [ -n "$CLIENT_MAX_BODY_SIZE" ]; then
		client_max_body_size_conf="    client_max_body_size ${CLIENT_MAX_BODY_SIZE};"
	fi

	# Rate limiting configuration
	# RATE_LIMIT_ENABLED: enable/disable rate limiting (default: false)
	# RATE_LIMIT_RATE: requests per second (default: 10r/s)
	# RATE_LIMIT_BURST: burst size (default: 20)
	# RATE_LIMIT_PATHS: comma-separated paths to rate limit
	#   If set, rate limiting is applied only to these paths. If not set and RATE_LIMIT_ENABLED=true,
	#   rate limiting is applied to all requests (location /)
	local rate_limit_enabled="${RATE_LIMIT_ENABLED:-false}"
	local rate_limit_burst="${RATE_LIMIT_BURST:-20}"
	local rate_limit_rate="${RATE_LIMIT_RATE:-10r/s}"
	local rate_limit_paths="${RATE_LIMIT_PATHS:-}"
	local rate_limit_location_conf=""
	local rate_limit_path_blocks=""
	local rate_limit_zone_conf=""

	# Setup rate limiting zone if rate limiting is enabled
	if [ "$rate_limit_enabled" = "true" ]; then
		# Rate limiting zone (must be in http context, which conf.d files are included in)
		rate_limit_zone_conf="# Rate limiting zone - IP-based rate limiting
    limit_req_zone \$binary_remote_addr zone=ip_limit:10m rate=${rate_limit_rate};
"

		# If RATE_LIMIT_PATHS is set, create specific location blocks for those paths
		if [ -n "$rate_limit_paths" ]; then
			# Split comma-separated paths and create location blocks
			IFS=',' read -ra PATHS <<< "$rate_limit_paths"
			for path in "${PATHS[@]}"; do
				# Trim whitespace
				path=$(echo "$path" | xargs)
				if [ -n "$path" ]; then
					rate_limit_path_blocks="${rate_limit_path_blocks}
    # Rate-limited path: ${path}
    location ${path} {
        limit_req zone=ip_limit burst=${rate_limit_burst} nodelay;
        ${PROXY_CMD}_pass ${TARGET_ENDPOINT};
        ${PROXY_CMD}_set_header Host \$host;
        ${PROXY_CMD}_set_header X-Real-IP \$remote_addr;
        ${PROXY_CMD}_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        ${PROXY_CMD}_set_header X-Forwarded-Proto \$scheme;

        # Timeout configuration
        ${PROXY_CMD}_read_timeout 600;
        ${PROXY_CMD}_send_timeout 600;
        ${PROXY_CMD}_connect_timeout 10;
    }"
				fi
			done
		else
			# Apply rate limiting to general location / if no specific paths are set
			rate_limit_location_conf="        limit_req zone=ip_limit burst=${rate_limit_burst} nodelay;"
		fi
	fi

	cat <<EOF >/etc/nginx/conf.d/default.conf
${rate_limit_zone_conf}
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
${client_max_body_size_conf}

    # WebSocket support - handles both /ws/ and /socket.io/ paths
    location ~ ^/(ws|socket\.io)/ {
        ${PROXY_CMD}_pass ${TARGET_ENDPOINT};
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
        ${PROXY_CMD}_connect_timeout 60;   # 1 minute
    }
${rate_limit_path_blocks}
    # Regular HTTP requests
    location / {
${rate_limit_location_conf}
        ${PROXY_CMD}_pass ${TARGET_ENDPOINT};
        ${PROXY_CMD}_set_header Host \$host;
        ${PROXY_CMD}_set_header X-Real-IP \$remote_addr;
        ${PROXY_CMD}_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        ${PROXY_CMD}_set_header X-Forwarded-Proto \$scheme;

        # Timeout configuration for long-running requests
        ${PROXY_CMD}_read_timeout 600;     # 10 minutes
        ${PROXY_CMD}_send_timeout 600;     # 10 minutes
        ${PROXY_CMD}_connect_timeout 10;   # 10 seconds
    }

    location /evidences/ {
        alias /evidences/;
        autoindex on;
    }
}
EOF
}

set_alias_record() {
	local domain="$1"
	echo "Setting alias record for $domain"
	dnsman.py set_alias \
		--domain "$domain" \
		--content "$GATEWAY_DOMAIN"

	if [ $? -ne 0 ]; then
		echo "Error: Failed to set alias record for $domain"
		exit 1
	fi
	echo "Alias record set for $domain"
}

set_txt_record() {
	local domain="$1"
	local APP_ID

	if [[ -S /var/run/dstack.sock ]]; then
		DSTACK_APP_ID=$(curl -s --unix-socket /var/run/dstack.sock http://localhost/Info | jq -j .app_id)
		export DSTACK_APP_ID
	else
		DSTACK_APP_ID=$(curl -s --unix-socket /var/run/tappd.sock http://localhost/prpc/Tappd.Info | jq -j .app_id)
		export DSTACK_APP_ID
	fi
	APP_ID=${APP_ID:-"$DSTACK_APP_ID"}

	dnsman.py set_txt \
		--domain "${TXT_PREFIX}.${domain}" \
		--content "$APP_ID:$PORT"

	if [ $? -ne 0 ]; then
		echo "Error: Failed to set TXT record for $domain"
		exit 1
	fi
}

set_caa_record() {
	local domain="$1"
	if [ "$SET_CAA" != "true" ]; then
		echo "Skipping CAA record setup"
		return
	fi
	echo "Adding CAA record for $domain"
	dnsman.py set_caa \
		--domain "$domain" \
		--caa-tag "issue" \
		--caa-value "letsencrypt.org;validationmethods=dns-01"

	if [ $? -ne 0 ]; then
		echo "Warning: Failed to set CAA record for $domain"
		echo "This is not critical - certificates can still be issued without CAA records"
		echo "Consider disabling CAA records by setting SET_CAA=false if this continues to fail"
		# Don't exit - CAA records are optional for certificate generation
	fi
}

process_domain() {
	local domain="$1"
	echo "Processing domain: $domain"

	set_alias_record "$domain"
	set_txt_record "$domain"
	renew-certificate.sh "$domain" || echo "First certificate renewal failed for $domain, will retry after set CAA record"
	set_caa_record "$domain"
	renew-certificate.sh "$domain"
}

bootstrap() {
	echo "Bootstrap: Setting up domains"

	local all_domains
	all_domains=$(get-all-domains.sh)

	if [ -z "$all_domains" ]; then
		echo "Error: No domains found. Set either DOMAIN or DOMAINS environment variable"
		exit 1
	fi

	echo "Found domains:"
	echo "$all_domains"

	while IFS= read -r domain; do
		[[ -n "$domain" ]] || continue
		process_domain "$domain"
	done <<<"$all_domains"

	# Generate evidences after all certificates are obtained
	echo "Generating evidence files for all domains..."
	generate-evidences.sh

	touch /.bootstrapped
}

enter_tailscale_network() {
	# Construct registration URL (for initial API call only)
	REGISTRATION_URL="https://${VPC_SERVER_APP_ID}-443s.${GATEWAY_SUBDOMAIN}"
	echo "Registration URL: ${REGISTRATION_URL}"

	# Get instance_id from the appropriate socket
	if [[ -S /var/run/dstack.sock ]]; then
		INSTANCE_ID=$(curl -s --unix-socket /var/run/dstack.sock http://localhost/Info | jq -r .instance_id)
	else
		INSTANCE_ID=$(curl -s --unix-socket /var/run/tappd.sock http://localhost/prpc/Tappd.Info | jq -r .instance_id)
	fi

	if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "null" ]; then
		echo "Error: Failed to obtain instance_id from socket"
		exit 1
	fi

	echo "Instance ID: ${INSTANCE_ID}"

	# Get app_id
	if [[ -S /var/run/dstack.sock ]]; then
		APP_ID=$(curl -s --unix-socket /var/run/dstack.sock http://localhost/Info | jq -r .app_id)
	else
		APP_ID=$(curl -s --unix-socket /var/run/tappd.sock http://localhost/prpc/Tappd.Info | jq -r .app_id)
	fi

	if [ -z "$APP_ID" ] || [ "$APP_ID" = "null" ]; then
		echo "Error: Failed to obtain app_id from socket"
		exit 1
	fi

	REGISTER_URI="/api/register?instance_id=${INSTANCE_ID}&node_name=dstack-ingress-vpc"
	echo "Registering with VPC server to obtain pre-auth key..."
	RESPONSE=$(curl -s -k \
		--cert /etc/ssl/certs/server.crt \
		--key /etc/ssl/private/server.key \
		--cacert /etc/ssl/certs/ca.crt \
		-H "x-dstack-target-app: ${VPC_SERVER_APP_ID}" \
		-H "Host: vpc-server" \
		-H "x-dstack-app-id: ${APP_ID}" \
		"${REGISTRATION_URL}${REGISTER_URI}")

	PRE_AUTH_KEY=$(jq -r .pre_auth_key <<<"$RESPONSE")
	VPC_SERVER_URL=$(jq -r .server_url <<<"$RESPONSE")

	if [ -z "$PRE_AUTH_KEY" ]; then
		echo "Error: Failed to obtain pre-auth key from VPC server"
		echo "Response: $RESPONSE"
		exit 1
	fi

	if [ -z "$VPC_SERVER_URL" ] || [ "$VPC_SERVER_URL" = "null" ]; then
		echo "Error: Failed to obtain server_url from VPC server"
		echo "Response: $RESPONSE"
		exit 1
	fi

	echo "VPC Server URL (from registration response): ${VPC_SERVER_URL}"

	tailscaled --tun=tailscale1 --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
	sleep 3

	echo "Joining Tailscale network..."

	tailscale up \
		--login-server="$VPC_SERVER_URL" \
		--authkey="$PRE_AUTH_KEY" \
		--hostname="ingress" \
		--reset \
		--accept-dns \
		--netfilter-mode=off

}

echo "Getting certificates"
CERT_URL="http://localhost/GetTlsKey?subject=localhost&usage_server_auth=true&usage_client_auth=true"
if ! curl -s --unix-socket /var/run/dstack.sock $CERT_URL >/tmp/server_response.json; then
	echo "Failed to generate certificates - dstack.sock may not be available"
	# Debug output
	echo "Debug info - attempting to query dstack.sock directly:"
	curl -s --unix-socket /var/run/dstack.sock http://localhost/Info
	echo "Contents of /tmp/server_response.json:"
	cat /tmp/server_response.json
	exit 1
fi
mkdir -p /etc/ssl/certs /etc/ssl/private

echo "Extracting server key and certificates..."
jq -r '.key' /tmp/server_response.json >/etc/ssl/private/server.key
jq -r '.certificate_chain[]' /tmp/server_response.json >/etc/ssl/certs/server.crt
jq -r '.certificate_chain[-1]' /tmp/server_response.json >/etc/ssl/certs/ca.crt

echo "Setting file permissions..."
chmod 644 /etc/ssl/private/server.key /etc/ssl/certs/server.crt /etc/ssl/certs/ca.crt

echo "Certificate generation completed!"
rm -f /tmp/server_response.json

echo "installing tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh

echo "Entering Tailscale network..."
enter_tailscale_network

# Credentials are now handled by certman.py setup

echo "Setting up certbot environment"

# Setup certbot environment (venv is already created in Dockerfile)
setup_certbot_env

# Check if it's the first time the container is started
if [ ! -f "/.bootstrapped" ]; then
	bootstrap
else
	echo "Certificate for $DOMAIN already exists"
	generate-evidences.sh
fi

renewal-daemon.sh &

mkdir -p /var/log/nginx

# Setup nginx configuration
if [ -n "$TARGET_NODE_PREFIX" ]; then
	# Load balancing mode: nginx config will be managed by update-backends daemon
	echo "Load balancing mode enabled with prefix: ${TARGET_NODE_PREFIX}"

	# Validate required variables
	if [ -z "$TARGET_PORT" ]; then
		echo "Error: TARGET_PORT must be set when using TARGET_NODE_PREFIX"
		exit 1
	fi

	# Make scripts executable
	chmod +x "$(dirname "${BASH_SOURCE[0]}")/discover-nodes.sh"
	chmod +x "$(dirname "${BASH_SOURCE[0]}")/generate-nginx-upstream.sh"
	chmod +x "$(dirname "${BASH_SOURCE[0]}")/update-backends.sh"

	# Start the backend update daemon
	# This will discover nodes, generate initial config, and keep it updated
	echo "Starting backend update daemon..."
	update-backends.sh &

elif [ -n "$DOMAIN" ] && [ -n "$TARGET_ENDPOINT" ]; then
	# Single target mode: use existing static configuration
	echo "Single target mode: ${TARGET_ENDPOINT}"
	setup_nginx_conf
fi

exec "$@"
