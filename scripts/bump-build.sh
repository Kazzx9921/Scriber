#!/bin/sh
# Increments the build number (CURRENT_PROJECT_VERSION) in project.yml and regenerates the project.
# App Store Connect rejects an upload whose build number is not higher than the previous one.
# Usage: scripts/bump-build.sh            -> build + 1
#        scripts/bump-build.sh 1.0.0      -> also sets the marketing version
set -e
cd "$(dirname "$0")/.."
current=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\{0,1\}\([0-9][0-9]*\)"\{0,1\}.*/\1/p' project.yml | head -1)
[ -n "$current" ] || { echo "CURRENT_PROJECT_VERSION not found in project.yml" >&2; exit 1; }
next=$((current + 1))
sed -i '' "s/^\( *CURRENT_PROJECT_VERSION: *\).*/\1\"$next\"/" project.yml
if [ -n "$1" ]; then
  sed -i '' "s/^\( *MARKETING_VERSION: *\).*/\1\"$1\"/" project.yml
fi
xcodegen generate >/dev/null
echo "version $(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' project.yml | head -1) build $next"
