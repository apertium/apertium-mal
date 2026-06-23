#!/usr/bin/env bash
set -euo pipefail

echo "==> Running autogen.sh..."
cd /workspace
bash autogen.sh --prefix=/usr/local

echo "==> Building apertium-mal..."
make -j"$(nproc)"

echo ""
echo "✓ apertium-mal dev container is ready."
echo "  Run 'make' to rebuild, or 'echo hello | apertium -d . mal-morph' to test."
