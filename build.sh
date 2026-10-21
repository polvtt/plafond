#!/bin/bash
# =============================================================================
# Build de Plafond : compile l'app + le helper, empaquette Plafond.app, signe
# les deux avec une exigence (DR) épinglée sur le certificat, et vérifie.
#
# Identité de signature : lue dans .signing.env (non versionné), créé par
#   ./Tools/setup_signing.sh
# Variables : SIGN_CN (nom du certificat), KC (trousseau), KCPASS (son mot de passe).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Plafond"
BUNDLE_ID="com.polat.plafond"
HELPER_ID="com.polat.plafond.helper"
VERSION="1.0.1"
MIN_OS="14.0"

[ -f .signing.env ] && source .signing.env
SIGN_CN="${SIGN_CN:-Plafond Dev}"
KC="${KC:-$HOME/Library/Keychains/plafond-signing.keychain-db}"
: "${KCPASS:?KCPASS manquant : lance ./Tools/setup_signing.sh (ou renseigne .signing.env)}"

BUILD="build"
# Le Bureau est synchronisé par iCloud : son File Provider recolle
# com.apple.FinderInfo sur le .app pendant la signature et codesign refuse alors
# de signer le bundle. On assemble et signe donc HORS iCloud, puis on copie.
STAGE="$HOME/Library/Caches/com.polat.plafond.build"
APP="$STAGE/$APP_NAME.app"
FINAL="$BUILD/$APP_NAME.app"
GEN="$BUILD/gen"

# --- Identité + empreinte du certificat ------------------------------------
security find-identity "$KC" 2>/dev/null | grep -q "\"$SIGN_CN\"" || {
    echo "✗ Identité « $SIGN_CN » absente de $KC. Lance ./Tools/setup_signing.sh" >&2; exit 1; }
security unlock-keychain -p "$KCPASS" "$KC" 2>/dev/null || true
CERT_SHA1=$(security find-certificate -c "$SIGN_CN" -Z "$KC" | awk '/SHA-1/{print tolower($3)}')
CTL_ID="com.polat.plafond.ctl"
APP_REQ="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$CERT_SHA1\""
CTL_REQ="identifier \"$CTL_ID\" and certificate leaf = H\"$CERT_SHA1\""
# Clients autorisés à parler au helper : l'app et plafondctl, signés par NOTRE certificat.
CLIENT_REQ="(identifier \"$BUNDLE_ID\" or identifier \"$CTL_ID\") and certificate leaf = H\"$CERT_SHA1\""
HELPER_REQ="identifier \"$HELPER_ID\" and certificate leaf = H\"$CERT_SHA1\""
echo "→ Certificat « $SIGN_CN » (SHA-1 $CERT_SHA1)"

rm -rf "$APP" "$FINAL" "$GEN"; mkdir -p "$BUILD" "$GEN" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchServices"

# Exigences de signature injectées dans le code (validation XPC dans les 2 sens)
cat > "$GEN/BuildConfig.swift" <<EOF
// Généré par build.sh — ne pas modifier.
enum BuildConfig {
    static let clientRequirement = #"$CLIENT_REQ"#
    static let helperRequirement = #"$HELPER_REQ"#
}
EOF

SWIFTC=(swiftc -O -target "arm64-apple-macos$MIN_OS")

echo "→ Compilation du helper…"
"${SWIFTC[@]}" Sources/Shared/*.swift Sources/Helper/main.swift "$GEN/BuildConfig.swift" \
    -o "$APP/Contents/Library/LaunchServices/$HELPER_ID"

echo "→ Compilation de l'app…"
"${SWIFTC[@]}" -parse-as-library Sources/Shared/*.swift Sources/App/*.swift "$GEN/BuildConfig.swift" \
    -o "$APP/Contents/MacOS/$APP_NAME"

echo "→ Compilation de plafondctl…"
"${SWIFTC[@]}" Sources/Shared/*.swift Sources/App/NativeChargeLimit.swift Tools/plafondctl/main.swift "$GEN/BuildConfig.swift" \
    -o "$APP/Contents/MacOS/plafondctl"

echo "→ Compilation de la sonde SMC…"
"${SWIFTC[@]}" Sources/Shared/SMC.swift Tools/smcprobe/main.swift -o "$BUILD/smcprobe"

# --- Ressources ----------------------------------------------------------------
sed "s|__HELPER_REQUIREMENT__|$HELPER_REQ|" Resources/helper-install.sh > "$APP/Contents/Resources/helper-install.sh"
chmod 755 "$APP/Contents/Resources/helper-install.sh"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleDevelopmentRegion</key><string>fr</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Plafond</string>
</dict></plist>
PLIST

# --- Signature -----------------------------------------------------------------
echo "→ Nettoyage xattr (com.apple.provenance)…"
xattr -cr "$APP" 2>/dev/null || true

sign() {  # $1 = cible, $2 = identifiant, $3 = exigence désignée
    local args=(--force --keychain "$KC" --sign "$SIGN_CN" --identifier "$2" --requirements "=designated => $3")
    codesign "${args[@]}" "$1" 2>/dev/null || { find "$1" -exec xattr -c {} \; 2>/dev/null; codesign "${args[@]}" "$1"; }
}
echo "→ Signature du helper puis de l'app…"
sign "$APP/Contents/Library/LaunchServices/$HELPER_ID" "$HELPER_ID" "$HELPER_REQ"
sign "$APP/Contents/MacOS/plafondctl" "$CTL_ID" "$CTL_REQ"
sign "$APP" "$BUNDLE_ID" "$APP_REQ"

codesign --verify --strict --verbose=1 "$APP/Contents/Library/LaunchServices/$HELPER_ID" 2>&1 | tail -1
codesign --verify --strict --verbose=1 "$APP/Contents/MacOS/plafondctl" 2>&1 | tail -1
# Le Bureau est synchronisé par iCloud : le File Provider recolle com.apple.FinderInfo
# sur le dossier .app en quelques secondes, ce que --strict refuse. Sans effet à
# l'exécution (la validation XPC passe) → vérification normale pour le bundle.
codesign --verify --strict --verbose=1 "$APP" 2>&1 | tail -1
ditto "$APP" "$FINAL"
codesign --verify -R="$APP_REQ" "$FINAL" || { echo "✗ signature du bundle invalide après copie" >&2; exit 1; }
APP="$FINAL"
echo "✓ Construit : $APP"
echo "  Lancer : open \"$APP\"   (jamais le binaire interne)"
