#!/bin/bash

set -e

# Health check utility functions for parallel execution
# Supports both HTTP and TCP health checks with configurable timeouts

# Default configuration
DEFAULT_MAX_PARALLEL=10
DEFAULT_CONNECT_TIMEOUT=5
DEFAULT_TOTAL_TIMEOUT=10

# Configuration from environment
MAX_PARALLEL_HEALTH_CHECKS=${MAX_PARALLEL_HEALTH_CHECKS:-$DEFAULT_MAX_PARALLEL}
HEALTH_CHECK_CONNECT_TIMEOUT=${HEALTH_CHECK_CONNECT_TIMEOUT:-$DEFAULT_CONNECT_TIMEOUT}
HEALTH_CHECK_TIMEOUT=${HEALTH_CHECK_TIMEOUT:-$DEFAULT_TOTAL_TIMEOUT}

# Logging function
log_health() {
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# Check single node health via HTTP
check_node_health_http() {
	local node="$1"
	local port="$2"
	local health_path="$3"
	local health_url="http://${node}:${port}${health_path}"

	if curl -sf --connect-timeout "$HEALTH_CHECK_CONNECT_TIMEOUT" --max-time "$HEALTH_CHECK_TIMEOUT" "$health_url" >/dev/null 2>&1; then
		echo "HEALTHY:$node"
		return 0
	else
		echo "UNHEALTHY:$node"
		return 1
	fi
}

# Check single node health via TCP
check_node_health_tcp() {
	local node="$1"
	local port="$2"

	if timeout "$HEALTH_CHECK_CONNECT_TIMEOUT" bash -c "cat < /dev/null > /dev/tcp/${node}/${port}" 2>/dev/null; then
		echo "HEALTHY:$node"
		return 0
	else
		echo "UNHEALTHY:$node"
		return 1
	fi
}

# Calculate optimal parallelism based on node count and system resources
calculate_optimal_parallelism() {
	local node_count="$1"
	local cpu_cores

	# Get CPU core count (fallback to 4 if unavailable)
	cpu_cores=$(nproc 2>/dev/null || echo "4")

	# Respect user's MAX_PARALLEL_HEALTH_CHECKS setting as the absolute maximum
	# Use 2x CPU cores as a reasonable upper bound, but never exceed user setting
	local cpu_max=$((cpu_cores * 2))
	local system_max=$((node_count < cpu_max ? node_count : cpu_max))
	local optimal=$((system_max > MAX_PARALLEL_HEALTH_CHECKS ? MAX_PARALLEL_HEALTH_CHECKS : system_max))

	echo "$optimal"
}

# Check multiple nodes in parallel using xargs
check_nodes_parallel() {
	local nodes="$1"
	local port="$2"
	local health_path="$3"
	local use_tcp="${4:-false}"

	if [ -z "$nodes" ] || [ -z "$port" ]; then
		log_health "Error: nodes and port are required"
		return 1
	fi

	local node_count
	node_count=$(echo "$nodes" | wc -l | tr -d ' ')

	if [ "$node_count" -eq 0 ]; then
		log_health "Warning: No nodes to check"
		return 0
	fi

	local max_parallel
	max_parallel=$(calculate_optimal_parallelism "$node_count")

	log_health "Starting parallel health checks for ${node_count} nodes (max parallel: $max_parallel)"

	local health_check_function
	if [ "$use_tcp" = "true" ] || [ -z "$health_path" ]; then
		health_check_function="check_node_health_tcp"
		log_health "Using TCP health checks on port $port"
	else
		health_check_function="check_node_health_http"
		log_health "Using HTTP health checks on port $port${health_path}"
	fi

	# Export variables and functions for subshell
	export HEALTH_CHECK_CONNECT_TIMEOUT HEALTH_CHECK_TIMEOUT
	export -f "$health_check_function" log_health

	# Execute health checks in parallel
	local results
	results=$(echo "$nodes" | xargs -I {} -P "$max_parallel" bash -c '
        node="{}"
        if [ "'"$health_check_function"'" = "check_node_health_http" ]; then
            check_node_health_http "$node" "'"$port"'" "'"$health_path"'"
        else
            check_node_health_tcp "$node" "'"$port"'"
        fi
    ')

	# Process results
	local healthy_nodes=""
	local unhealthy_nodes=""
	local healthy_count=0
	local unhealthy_count=0

	while IFS= read -r result; do
		if [ -n "$result" ]; then
			if [[ "$result" == HEALTHY:* ]]; then
				node="${result#HEALTHY:}"
				healthy_nodes="${healthy_nodes}${node}"$'\n'
				((healthy_count++))
				log_health "  - $node [HEALTHY]"
			elif [[ "$result" == UNHEALTHY:* ]]; then
				node="${result#UNHEALTHY:}"
				unhealthy_nodes="${unhealthy_nodes}${node}"$'\n'
				((unhealthy_count++))
				log_health "  - $node [UNHEALTHY] - removing from pool"
			fi
		fi
	done <<<"$results"

	# Clean up trailing newlines
	healthy_nodes=$(echo "$healthy_nodes" | sed '/^$/d')
	unhealthy_nodes=$(echo "$unhealthy_nodes" | sed '/^$/d')

	log_health "Health check completed: ${healthy_count}/${node_count} nodes healthy, ${unhealthy_count} unhealthy"

	# Output healthy nodes for consumption by caller
	if [ -n "$healthy_nodes" ]; then
		echo "$healthy_nodes"
	fi

	# Return success if we have at least one healthy node
	[ "$healthy_count" -gt 0 ]
}

# Fallback sequential health check (used if parallel fails)
check_nodes_sequential() {
	local nodes="$1"
	local port="$2"
	local health_path="$3"
	local use_tcp="${4:-false}"

	log_health "Warning: Falling back to sequential health checks"

	local healthy_nodes=""
	local node_count=0
	local healthy_count=0

	while read -r node; do
		if [ -z "$node" ]; then
			continue
		fi

		((node_count++))

		local result
		if [ "$use_tcp" = "true" ] || [ -z "$health_path" ]; then
			result=$(check_node_health_tcp "$node" "$port")
		else
			result=$(check_node_health_http "$node" "$port" "$health_path")
		fi

		if [[ "$result" == HEALTHY:* ]]; then
			healthy_nodes="${healthy_nodes}${node}"$'\n'
			((healthy_count++))
			log_health "  - $node [HEALTHY]"
		else
			log_health "  - $node [UNHEALTHY] - removing from pool"
		fi
	done <<<"$nodes"

	# Clean up trailing newline
	healthy_nodes=$(echo "$healthy_nodes" | sed '/^$/d')

	log_health "Sequential health check completed: ${healthy_count}/${node_count} nodes healthy"

	# Output healthy nodes for consumption by caller
	if [ -n "$healthy_nodes" ]; then
		echo "$healthy_nodes"
	fi

	# Return success if we have at least one healthy node
	[ "$healthy_count" -gt 0 ]
}

# Main health check function with automatic fallback
check_nodes() {
	local nodes="$1"
	local port="$2"
	local health_path="$3"
	local use_tcp="${4:-false}"

	# Try parallel first, fallback to sequential if it fails
	if ! check_nodes_parallel "$nodes" "$port" "$health_path" "$use_tcp"; then
		log_health "Parallel health check failed, trying sequential mode"
		check_nodes_sequential "$nodes" "$port" "$health_path" "$use_tcp"
	fi
}

# Show configuration and help
show_config() {
	echo "Health Check Configuration:"
	echo "  MAX_PARALLEL_HEALTH_CHECKS: $MAX_PARALLEL_HEALTH_CHECKS"
	echo "  HEALTH_CHECK_CONNECT_TIMEOUT: ${HEALTH_CHECK_CONNECT_TIMEOUT}s"
	echo "  HEALTH_CHECK_TIMEOUT: ${HEALTH_CHECK_TIMEOUT}s"
	echo ""
	echo "Usage: $0 [command] [options]"
	echo ""
	echo "Commands:"
	echo "  check-nodes <nodes_file> <port> [health_path]  Check nodes from file"
	echo "  check-stdin <port> [health_path]              Check nodes from stdin"
	echo "  config                                         Show current configuration"
	echo ""
	echo "Environment Variables:"
	echo "  MAX_PARALLEL_HEALTH_CHECKS    Maximum parallel checks (default: 10)"
	echo "  HEALTH_CHECK_CONNECT_TIMEOUT  Connect timeout in seconds (default: 5)"
	echo "  HEALTH_CHECK_TIMEOUT          Total timeout in seconds (default: 10)"
}

# Command line interface
case "${1:-}" in
"check-nodes")
	if [ $# -lt 3 ]; then
		echo "Error: check-nodes requires nodes_file and port" >&2
		exit 1
	fi

	nodes_file="$2"
	port="$3"
	health_path="$4"

	if [ ! -f "$nodes_file" ]; then
		echo "Error: Nodes file '$nodes_file' not found" >&2
		exit 1
	fi

	nodes=$(cat "$nodes_file")
	check_nodes "$nodes" "$port" "$health_path"
	;;
"check-stdin")
	if [ $# -lt 2 ]; then
		echo "Error: check-stdin requires port" >&2
		exit 1
	fi

	port="$2"
	health_path="$3"
	nodes=$(cat)
	check_nodes "$nodes" "$port" "$health_path"
	;;
"config")
	show_config
	;;
*)
	show_config
	exit 1
	;;
esac
