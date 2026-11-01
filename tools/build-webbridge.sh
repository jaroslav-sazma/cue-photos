#!/bin/zsh
# Regenerates Photos/Resources/WebBridge.js from webbridge/ + the gptk submodule.
set -euo pipefail
cd "$(dirname "$0")/../webbridge"
[ -d node_modules ] || npm ci --no-audit --no-fund
npm run typecheck
npm run build
echo "WebBridge.js regenerated."
