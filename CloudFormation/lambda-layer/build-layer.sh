#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAYER_ZIP="$SCRIPT_DIR/pymysql-layer.zip"

# Si le zip existe déjà et qu'aucun pip n'est dispo, on garde l'existant
if ! command -v pip3 &>/dev/null && ! command -v pip &>/dev/null; then
    if [ -f "$LAYER_ZIP" ]; then
        echo "⚠️  pip non trouvé — utilisation du zip existant ($(du -h "$LAYER_ZIP" | cut -f1))"
        exit 0
    fi
    echo "❌ pip non trouvé et aucun zip existant. Installe Python/pip ou commit le zip."
    exit 1
fi

echo "Building pymysql Lambda layer in $SCRIPT_DIR..."
BUILD_DIR=$(mktemp -d)
mkdir -p "$BUILD_DIR/python/lib/python3.9/site-packages"

if command -v pip3 &>/dev/null; then
    pip3 install pymysql -t "$BUILD_DIR/python/lib/python3.9/site-packages/" --no-cache-dir --quiet
else
    pip install pymysql -t "$BUILD_DIR/python/lib/python3.9/site-packages/" --no-cache-dir --quiet
fi

cd "$BUILD_DIR"
zip -r "$SCRIPT_DIR/pymysql-layer.zip" python/ -q
rm -rf "$BUILD_DIR"
echo "Layer built: $LAYER_ZIP ($(du -h "$LAYER_ZIP" | cut -f1))"
