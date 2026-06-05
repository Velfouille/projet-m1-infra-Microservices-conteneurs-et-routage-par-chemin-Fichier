#!/bin/bash
set -e

echo "Building pymysql Lambda layer..."
BUILD_DIR=$(mktemp -d)
mkdir -p "$BUILD_DIR/python/lib/python3.9/site-packages"
pip3 install pymysql -t "$BUILD_DIR/python/lib/python3.9/site-packages/" --no-cache-dir --quiet

cd "$BUILD_DIR"
zip -r pymysql-layer.zip python/ -q
mv pymysql-layer.zip "$(dirname "$0")/pymysql-layer.zip"
rm -rf "$BUILD_DIR"
echo "Layer built: $(dirname "$0")/pymysql-layer.zip ($(du -h "$(dirname "$0")/pymysql-layer.zip" | cut -f1))"
