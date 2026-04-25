#!/usr/bin/env bash
# Setup script for redin development.
# Installs system dependencies, pulls submodules, and builds.

set -euo pipefail

echo "=== redin development setup ==="

# --- System packages ---
echo ""
echo "Installing system packages..."
if command -v apt-get &>/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y luajit libluajit-5.1-dev libssl-dev
elif command -v dnf &>/dev/null; then
  sudo dnf install -y luajit luajit-devel openssl-devel
elif command -v pacman &>/dev/null; then
  sudo pacman -S --needed luajit openssl
elif command -v brew &>/dev/null; then
  brew install luajit openssl
else
  echo "WARNING: Unknown package manager. Install LuaJIT, libluajit-5.1-dev, and libssl-dev manually."
fi

# --- Tool checks ---
echo ""
missing=()

if ! command -v odin &>/dev/null; then
  missing+=("odin — https://odin-lang.org/docs/install/")
fi

if ! command -v luajit &>/dev/null; then
  missing+=("luajit — apt: luajit / brew: luajit")
fi

if ! command -v bb &>/dev/null; then
  missing+=("bb (Babashka) — https://github.com/babashka/babashka#installation")
fi

if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing required tools:"
  for tool in "${missing[@]}"; do
    echo "  - $tool"
  done
  exit 1
fi

echo "All required tools found:"
echo "  odin:   $(odin version 2>/dev/null || echo 'unknown')"
echo "  luajit: $(luajit -v 2>&1 | head -1)"
echo "  bb:     $(bb --version 2>/dev/null)"

# --- Git submodules ---
echo ""
echo "Pulling git submodules..."
git submodule update --init --recursive

# --- Build ---
echo ""
echo "Building redin..."
mkdir -p build
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin

echo ""
echo "=== Setup complete ==="
echo "  ./build/redin --dev examples/kitchen-sink.fnl"
