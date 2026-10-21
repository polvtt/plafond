#!/bin/bash
# =============================================================================
# Installe / désinstalle le helper root de Plafond (LaunchDaemon).
# Exécuté en root, soit par l'app (« do shell script … with administrator
# privileges »), soit à la main :
#   sudo ./helper-install.sh install /chemin/vers/Plafond.app
#   sudo ./helper-install.sh uninstall
# =============================================================================
set -euo pipefail

LABEL="com.polat.plafond.helper"
DEST="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
STATE="/Library/Application Support/Plafond"
# Injecté par build.sh : exigence de signature du helper (certificat épinglé).
REQUIREMENT='__HELPER_REQUIREMENT__'

[ "$(id -u)" -eq 0 ] || { echo "À lancer en root (sudo)." >&2; exit 1; }

case "${1:-}" in
install)
    APP="${2:?chemin de Plafond.app attendu}"
    SRC="$APP/Contents/Library/LaunchServices/$LABEL"
    [ -f "$SRC" ] || { echo "Helper introuvable : $SRC" >&2; exit 1; }

    # On n'installe en root qu'un binaire signé par NOTRE certificat.
    /usr/bin/codesign --verify --strict -R="$REQUIREMENT" "$SRC"

    # Arrêt de l'ancienne version (SIGTERM → elle rétablit adaptateur et LED).
    /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true

    /bin/mkdir -p /Library/PrivilegedHelperTools
    /usr/bin/install -o root -g wheel -m 0755 "$SRC" "$DEST"

    /bin/cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$DEST</string></array>
    <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
EOF
    /usr/sbin/chown root:wheel "$PLIST"
    /bin/chmod 0644 "$PLIST"
    /bin/launchctl bootstrap system "$PLIST"
    echo "✓ Helper installé et démarré ($DEST)"
    ;;
uninstall)
    /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
    /bin/rm -f "$DEST" "$PLIST"
    /bin/rm -rf "$STATE"
    echo "✓ Helper désinstallé"
    ;;
*)
    echo "Usage : $0 install <Plafond.app> | uninstall" >&2
    exit 2
    ;;
esac
