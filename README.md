# dStack Ingress VPC

SSL/TLS ingress controller with automatic certificate management and Tailscale VPC integration for load balancing across backend nodes.

## Features

- **Automatic SSL/TLS certificates** via Let's Encrypt with DNS-01 challenge
- **Tailscale VPC integration** for secure private networking
- **Dynamic load balancing** with health checks across multiple backend nodes
- **DNS management** with support for Cloudflare and other providers
- **Certificate auto-renewal** with daemon monitoring

## Quick Start

### Single Backend Mode

Route traffic to a single backend service:

```yaml
services:
  dstack-ingress:
    image: dstacktee/dstack-ingress:latest
    ports:
      - "443:443"
    environment:
      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
      - DOMAIN=example.com
      - GATEWAY_DOMAIN=gateway.example.com
      - CERTBOT_EMAIL=admin@example.com
      - TARGET_ENDPOINT=http://app:80
    volumes:
      - /var/run/dstack.sock:/var/run/dstack.sock
      - cert-data:/etc/letsencrypt
```

### Load Balancing Mode

Automatically discover and load balance across multiple backend nodes:

```yaml
services:
  dstack-ingress:
    image: dstacktee/dstack-ingress:latest
    ports:
      - "443:443"
    environment:
      - CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
      - DOMAIN=api.example.com
      - GATEWAY_DOMAIN=gateway.example.com
      - CERTBOT_EMAIL=admin@example.com
      - VPC_SERVER_APP_ID=your-vpc-server-id
      - GATEWAY_SUBDOMAIN=your-gateway-subdomain
      - TARGET_NODE_PREFIX=api-server
      - TARGET_PORT=3000
      - NODE_HEALTH_CHECK=/health
    volumes:
      - /var/run/dstack.sock:/var/run/dstack.sock
      - cert-data:/etc/letsencrypt
```

## Environment Variables

### Required (All Modes)

- `DOMAIN` - Primary domain name for SSL certificate
- `CLOUDFLARE_API_TOKEN` - Cloudflare API token for DNS management
- `GATEWAY_DOMAIN` - Gateway domain for DNS alias
- `CERTBOT_EMAIL` - Email for Let's Encrypt notifications

### Single Backend Mode

- `TARGET_ENDPOINT` - Backend URL (e.g., `http://app:80` or `grpc://service:9090`)

### Load Balancing Mode

- `VPC_SERVER_APP_ID` - VPC server application ID
- `GATEWAY_SUBDOMAIN` - Gateway subdomain for VPC registration
- `TARGET_NODE_PREFIX` - Prefix to filter Tailscale nodes (e.g., `api-server`)
- `TARGET_PORT` - Backend service port
- `NODE_HEALTH_CHECK` - Health check endpoint path (optional, e.g., `/health`)

### Optional

- `PORT` - HTTPS port (default: 443)
- `SET_CAA` - Enable CAA DNS records (default: false)
- `CLIENT_MAX_BODY_SIZE` - Max request body size (e.g., `100m`)
- `PROTOCOL` - Set to `grpc` for gRPC backends
- `DOMAINS` - Multiple domains (newline-separated)

## How It Works

### Single Backend Mode
1. Obtains SSL certificate via Let's Encrypt DNS-01 challenge
2. Configures nginx to proxy traffic to the specified backend
3. Automatically renews certificates before expiration

### Load Balancing Mode
1. Joins Tailscale VPC network using VPC server registration
2. Discovers backend nodes matching `TARGET_NODE_PREFIX`
3. Performs health checks on discovered nodes
4. Dynamically updates nginx upstream configuration
5. Monitors node health every 60 seconds and updates backend pool

## DNS Provider Support

See [DNS_PROVIDERS.md](DNS_PROVIDERS.md) for configuration details.

Currently supported:
- Cloudflare
- Route53 (AWS)
- Google Cloud DNS
- And more...

## Building

```bash
./build-image.sh
```

## Health Checks

The load balancer performs two layers of health checking:

1. **Active checks** - HTTP/TCP health checks every 60 seconds
2. **Passive checks** - Nginx `max_fails=2` and `fail_timeout=30s`

Only healthy nodes are included in the backend pool.

## Evidence Files

Access certificate transparency evidence at: `https://your-domain/evidences/`
