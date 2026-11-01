#!/bin/zsh
# Moves the gptk submodule to a release tag (default: latest), rebuilds the bridge bundle.
# Review the WebBridge.js diff and commit the submodule bump together with the bundle.
set -euo pipefail
cd "$(dirname "$0")/../third_party/gptk"
git fetch --tags origin
tag="${1:-$(git tag --list 'v*' --sort=-version:refname | grep -v -- - | head -1)}"
echo "Checking out gptk ${tag}"
git checkout "$tag"
cd ../..
tools/build-webbridge.sh
echo "gptk is at ${tag}; review 'git diff' (bundle + submodule) before committing."
