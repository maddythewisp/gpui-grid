#!/bin/bash
set -e

# Configuration
DURATION_SECONDS=5
BUILD_MODE="${1:-release}"  # release or debug
LOG_LEVEL="${2:-debug}"     # debug, trace, or info

# Create logs directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGS_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOGS_DIR"

# Generate timestamp
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOGS_DIR/bench_${BUILD_MODE}_${LOG_LEVEL}_${TIMESTAMP}.log"

echo "===================================="
echo "GPUI Grid Benchmark Runner"
echo "===================================="
echo "Build mode:    $BUILD_MODE"
echo "Log level:     $LOG_LEVEL"
echo "Duration:      ${DURATION_SECONDS}s"
echo "Log file:      $LOG_FILE"
echo "===================================="
echo

# Build the project
echo "Building project..."
BUILD_LOG=$(mktemp)
if [ "$BUILD_MODE" = "release" ]; then
    BINARY="target/release/gpui-grid"
    if cargo build --release --features fiber > "$BUILD_LOG" 2>&1; then
        echo "✓ Build succeeded"
    else
        echo "✗ Build failed. Last 20 lines:"
        tail -20 "$BUILD_LOG"
        rm "$BUILD_LOG"
        exit 1
    fi
else
    BINARY="target/debug/gpui-grid"
    if cargo build --features fiber > "$BUILD_LOG" 2>&1; then
        echo "✓ Build succeeded"
    else
        echo "✗ Build failed. Last 20 lines:"
        tail -20 "$BUILD_LOG"
        rm "$BUILD_LOG"
        exit 1
    fi
fi
rm "$BUILD_LOG"

# Verify binary exists and was just built
if [ ! -f "$BINARY" ]; then
    echo "✗ Error: Binary not found at $BINARY"
    exit 1
fi

BINARY_AGE=$(($(date +%s) - $(stat -f %m "$BINARY")))
if [ $BINARY_AGE -gt 60 ]; then
    echo "⚠ Warning: Binary is $BINARY_AGE seconds old (may be stale)"
    echo "  Binary modified: $(stat -f %Sm "$BINARY")"
fi

echo "✓ Using binary: $BINARY"
echo

# Run the benchmark with timeout and log everything
export RUST_LOG="gpui=$LOG_LEVEL"
timeout ${DURATION_SECONDS}s "$BINARY" > "$LOG_FILE" 2>&1 || true

# Show log file info
LOG_SIZE=$(wc -l < "$LOG_FILE" | xargs)
LOG_SIZE_KB=$(du -k "$LOG_FILE" | cut -f1)

echo
echo "===================================="
echo "Benchmark Complete"
echo "===================================="
echo "Log lines:     $LOG_SIZE"
echo "Log size:      ${LOG_SIZE_KB}KB"
echo "Log location:  $LOG_FILE"
echo "===================================="
echo

# Auto-analyze the results
echo "Running analysis..."
echo
"$SCRIPT_DIR/analyze_logs.sh" "$LOG_FILE"
