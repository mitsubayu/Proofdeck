#!/bin/bash
# Prepares a fresh checkout: bundles the renderer page into Resources/web and
# generates Proofdeck.xcodeproj from project.yml. Neither is committed, so this
# must run before opening the project in Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "Installing XcodeGen…"
    brew install xcodegen
fi
command -v node >/dev/null 2>&1 || { echo "✘ Node.js is required (brew install node)"; exit 1; }

# The page is copied into both the app and the Quick Look extension as a
# folder reference, so it has to exist before the project is generated.
(cd web && npm install --ignore-scripts --no-audit --no-fund --loglevel=error >/dev/null && node build.mjs >/dev/null)

# Sign as whoever is building. An ad-hoc signature changes with every build,
# and macOS then treats each build as a new app and asks again for access to
# the Desktop and other protected folders. A stable Apple Development identity
# avoids that. Hardcoding the author's team in project.yml would only break
# everyone else's build, so take it from the environment, falling back to the
# team on the first codesigning identity in the keychain. With no identity at
# all the build is signed ad-hoc ("-"), which is also what CI does.
if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    identity=$(security find-identity -v -p codesigning 2>/dev/null |
        sed -n 's/.*"\(Apple Develop[^"]*\)".*/\1/p' | head -1)
    # The team id is the certificate's OU. The name's parenthetical looks like
    # one but is a different identifier — signing with it fails.
    if [[ -n "$identity" ]]; then
        DEVELOPMENT_TEAM=$(security find-certificate -c "$identity" -p 2>/dev/null |
            openssl x509 -noout -subject 2>/dev/null |
            sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p' | head -1)
    fi
fi
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
    CODE_SIGN_IDENTITY="Apple Development"
else
    DEVELOPMENT_TEAM=""
    CODE_SIGN_IDENTITY="-"
fi
export DEVELOPMENT_TEAM CODE_SIGN_IDENTITY

xcodegen generate --quiet
echo "Ready (signing: ${DEVELOPMENT_TEAM:-ad-hoc}): open Proofdeck.xcodeproj, or run ./build.sh"
