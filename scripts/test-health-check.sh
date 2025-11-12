#!/bin/bash

set -e

# Test script for parallel health checking functionality
# This script simulates multiple nodes and tests the health check performance

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_CHECK_SCRIPT="${SCRIPT_DIR}/health-check.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test configuration
TEST_NODES=10
TEST_PORT=8080
TEST_HEALTH_PATH="/health"

# Logging functions
log_info() {
	echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
	echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
	echo -e "${RED}[ERROR]${NC} $*"
}

# Create test nodes file
create_test_nodes() {
	local count="$1"
	local nodes_file="/tmp/test_nodes.txt"

	log_info "Creating test nodes file with $count nodes..."

	>"$nodes_file"
	for i in $(seq 1 "$count"); do
		echo "test-node-$i.example.com" >>"$nodes_file"
	done

	echo "$nodes_file"
}

# Test health check configuration
test_config() {
	log_info "Testing health check configuration..."

	if [ ! -f "$HEALTH_CHECK_SCRIPT" ]; then
		log_error "Health check script not found: $HEALTH_CHECK_SCRIPT"
		return 1
	fi

	if [ ! -x "$HEALTH_CHECK_SCRIPT" ]; then
		log_error "Health check script is not executable"
		return 1
	fi

	# Test config command
	log_info "Checking health check script configuration..."
	"$HEALTH_CHECK_SCRIPT" config

	log_info "✓ Health check script configuration is valid"
}

# Test parallel health checking with mock nodes
test_parallel_health_check() {
	local node_count="$1"
	local max_parallel="$2"

	log_info "Testing parallel health check with $node_count nodes (max parallel: $max_parallel)..."

	# Set environment variables
	export MAX_PARALLEL_HEALTH_CHECKS="$max_parallel"
	export HEALTH_CHECK_CONNECT_TIMEOUT=2
	export HEALTH_CHECK_TIMEOUT=5

	# Create test nodes
	local nodes_file
	nodes_file=$(create_test_nodes "$node_count")

	# Measure execution time
	local start_time
	start_time=$(date +%s)

	# Run health check (will fail since nodes don't exist, but we're testing parallelism)
	local output
	if output=$("$HEALTH_CHECK_SCRIPT" check-nodes "$nodes_file" "$TEST_PORT" "$TEST_HEALTH_PATH" 2>&1); then
		log_warn "Health check unexpectedly succeeded (nodes don't exist)"
	else
		log_info "Health check failed as expected (test nodes don't exist)"
	fi

	local end_time
	end_time=$(date +%s)
	local duration=$((end_time - start_time))

	log_info "Execution time: ${duration}s"

	# Check if parallel execution was used
	if echo "$output" | grep -q "Starting parallel health checks"; then
		log_info "✓ Parallel health checking was used"
	else
		log_warn "Parallel health checking may not have been used"
	fi

	# Check if max parallel setting was respected
	if echo "$output" | grep -q "max parallel: $max_parallel"; then
		log_info "✓ Max parallel setting was respected"
	else
		log_warn "Max parallel setting may not have been respected"
	fi

	# Cleanup
	rm -f "$nodes_file"

	log_info "✓ Parallel health check test completed"
}

# Test sequential fallback
test_sequential_fallback() {
	log_info "Testing sequential fallback mechanism..."

	# Create test nodes
	local nodes_file
	nodes_file=$(create_test_nodes 3)

	# Force sequential mode by setting max parallel to 1
	export MAX_PARALLEL_HEALTH_CHECKS=1

	local output
	if output=$("$HEALTH_CHECK_SCRIPT" check-nodes "$nodes_file" "$TEST_PORT" "$TEST_HEALTH_PATH" 2>&1); then
		log_warn "Health check unexpectedly succeeded"
	else
		log_info "Health check failed as expected"
	fi

	# Check if sequential mode was used
	if echo "$output" | grep -q "max parallel: 1"; then
		log_info "✓ Sequential mode was used"
	else
		log_warn "Sequential mode may not have been used"
	fi

	# Cleanup
	rm -f "$nodes_file"

	log_info "✓ Sequential fallback test completed"
}

# Test TCP vs HTTP health checks
test_health_check_types() {
	log_info "Testing TCP vs HTTP health check types..."

	# Create test nodes
	local nodes_file
	nodes_file=$(create_test_nodes 2)

	# Test TCP health check (no health path)
	log_info "Testing TCP health check..."
	local output
	if output=$("$HEALTH_CHECK_SCRIPT" check-nodes "$nodes_file" "$TEST_PORT" 2>&1); then
		log_warn "TCP health check unexpectedly succeeded"
	else
		log_info "TCP health check failed as expected"
	fi

	if echo "$output" | grep -q "Using TCP health checks"; then
		log_info "✓ TCP health check was used"
	else
		log_warn "TCP health check may not have been used"
	fi

	# Test HTTP health check (with health path)
	log_info "Testing HTTP health check..."
	if output=$("$HEALTH_CHECK_SCRIPT" check-nodes "$nodes_file" "$TEST_PORT" "$TEST_HEALTH_PATH" 2>&1); then
		log_warn "HTTP health check unexpectedly succeeded"
	else
		log_info "HTTP health check failed as expected"
	fi

	if echo "$output" | grep -q "Using HTTP health checks"; then
		log_info "✓ HTTP health check was used"
	else
		log_warn "HTTP health check may not have been used"
	fi

	# Cleanup
	rm -f "$nodes_file"

	log_info "✓ Health check types test completed"
}

# Performance comparison test
test_performance_comparison() {
	log_info "Running performance comparison test..."

	local node_count=15

	# Test with different parallelism levels
	for parallel in 1 5 10 15; do
		log_info "Testing with $parallel parallel workers..."

		local start_time
		start_time=$(date +%s.%N)

		# Create test nodes
		local nodes_file
		nodes_file=$(create_test_nodes "$node_count")

		# Set parallelism
		export MAX_PARALLEL_HEALTH_CHECKS="$parallel"
		export HEALTH_CHECK_CONNECT_TIMEOUT=1
		export HEALTH_CHECK_TIMEOUT=2

		# Run health check
		if "$HEALTH_CHECK_SCRIPT" check-nodes "$nodes_file" "$TEST_PORT" "$TEST_HEALTH_PATH" >/dev/null 2>&1; then
			log_warn "Health check unexpectedly succeeded"
		fi

		local end_time
		end_time=$(date +%s.%N)
		local duration
		duration=$(echo "$end_time - $start_time" | bc -l 2>/dev/null || echo "N/A")

		log_info "  Parallel $parallel: ${duration}s"

		# Cleanup
		rm -f "$nodes_file"
	done

	log_info "✓ Performance comparison test completed"
}

# Main test function
run_tests() {
	log_info "Starting health check functionality tests..."
	echo

	# Check dependencies
	if ! command -v bc >/dev/null 2>&1; then
		log_warn "bc not found, performance timing may be inaccurate"
	fi

	# Run tests
	test_config
	echo

	test_parallel_health_check 5 5
	echo

	test_parallel_health_check 10 10
	echo

	test_sequential_fallback
	echo

	test_health_check_types
	echo

	test_performance_comparison
	echo

	log_info "All tests completed!"
	log_info ""
	log_info "Note: Health checks failed as expected since test nodes don't exist."
	log_info "The tests validate parallel execution, configuration, and fallback mechanisms."
}

# Show usage
show_usage() {
	echo "Usage: $0 [options]"
	echo ""
	echo "Options:"
	echo "  -h, --help     Show this help message"
	echo "  -q, --quiet    Run tests with minimal output"
	echo ""
	echo "This script tests the parallel health checking functionality."
	echo "It creates mock nodes and validates the health check behavior."
}

# Parse command line arguments
QUIET=false
while [[ $# -gt 0 ]]; do
	case $1 in
	-h | --help)
		show_usage
		exit 0
		;;
	-q | --quiet)
		QUIET=true
		shift
		;;
	*)
		log_error "Unknown option: $1"
		show_usage
		exit 1
		;;
	esac
done

# Redirect output if quiet mode
if [ "$QUIET" = true ]; then
	exec >/dev/null 2>&1
fi

# Run tests
run_tests
