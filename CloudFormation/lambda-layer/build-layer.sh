#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Building pymysql Lambda layer in $SCRIPT_DIR..."
BUILD_DIR=$(mktemp -d)
mkdir -p "$BUILD_DIR/python/lib/python3.9/site-packages"
pip3 install pymysql -t "$BUILD_DIR/python/lib/python3.9/site-packages/" --no-cache-dir --quiet

cd "$BUILD_DIR"
zip -r pymysql-layer.zip python/ -q
mv pymysql-layer.zip "$SCRIPT_DIR/pymysql-layer.zip"
rm -rf "$BUILD_DIR"
echo "Layer built: $SCRIPT_DIR/pymysql-layer.zip ($(du -h "$SCRIPT_DIR/pymysql-layer.zip" | cut -f1))"
