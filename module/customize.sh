#!/system/bin/sh
# Magisk module installer customization.
# Sourced (not executed) by Magisk installer after unzip.
# $ARCH is set by Magisk: arm | arm64 | x86 | x64 | riscv64
# $IS64BIT is true/false.
#
# IMPORTANT: at this point $MODPATH is /data/adb/modules_update/beszel-agent,
# while the currently installed module is still /data/adb/modules/beszel-agent.
# On the next boot Magisk runs upgrade_modules(), which does remove_all() on
# /data/adb/modules/beszel-agent BEFORE moving the pending install into place.
# So anything stored *inside* the module directory is destroyed by an update,
# and anything written there during install is what ends up live after reboot.
# Config and agent state therefore live in /data/adb/beszel-agent, outside the
# module directory.

# We only ship ARM binaries (arm + arm64).
case "$ARCH" in
  arm|arm64) ;;
  *)
    abort "! Unsupported architecture: $ARCH (need arm or arm64)"
    ;;
esac

ui_print "- Device architecture: $ARCH (IS64BIT=$IS64BIT)"

# Magisk $ARCH already maps:
#   arm64-v8a / aarch64  -> arm64
#   armeabi-v7a / armv7l / armv8l (32-bit userspace) -> arm
# Pick matching binary, install as a single name, drop the other.
BINDIR="$MODPATH/bin"
if [ "$ARCH" = "arm64" ]; then
  SELECTED="beszel-agent-arm64"
  REMOVED="beszel-agent-arm"
else
  SELECTED="beszel-agent-arm"
  REMOVED="beszel-agent-arm64"
fi

if [ ! -f "$BINDIR/$SELECTED" ]; then
  abort "! Missing binary: bin/$SELECTED"
fi

ui_print "- Installing $SELECTED as bin/beszel-agent"
mv -f "$BINDIR/$SELECTED" "$BINDIR/beszel-agent"
rm -f "$BINDIR/$REMOVED"

set_perm "$BINDIR/beszel-agent" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755

# --- persistent paths (outside /data/adb/modules, survive updates) ---
CONFIG_DIR=/data/adb/beszel-agent
CONFIG_FILE="$CONFIG_DIR/beszel-agent.env"
BACKUP_FILE="$CONFIG_DIR/beszel-agent.env.bak"
STATE_DIR="$CONFIG_DIR/data"
INSTALLED_DIR=/data/adb/modules/beszel-agent

mkdir -p "$STATE_DIR" 2>/dev/null || mkdir -p "$CONFIG_DIR" || abort "! Failed to create $CONFIG_DIR"

# --- config: never silently overwrite what the user already has ---
# Precedence:
#   1. .env shipped in the zip (personal build) -> always applied, old one backed up
#   2. $CONFIG_FILE from a previous install -> preserved
#   3. .env of the currently installed module -> migrated
#   4. .env.example -> fresh template
SHIPPED="$MODPATH/.env"
LEGACY="$INSTALLED_DIR/.env"

if [ -f "$SHIPPED" ]; then
  if [ -f "$CONFIG_FILE" ] && ! cmp -s "$SHIPPED" "$CONFIG_FILE"; then
    cp -f "$CONFIG_FILE" "$BACKUP_FILE" 2>/dev/null &&
      ui_print "- Previous config backed up to $BACKUP_FILE"
  fi
  cp -f "$SHIPPED" "$CONFIG_FILE" &&
    ui_print "- Config applied from the zip"
elif [ -f "$CONFIG_FILE" ]; then
  ui_print "- Keeping existing $CONFIG_FILE"
elif [ -f "$LEGACY" ]; then
  cp -f "$LEGACY" "$CONFIG_FILE" &&
    ui_print "- Migrated config from $LEGACY"
elif [ -f "$MODPATH/.env.example" ]; then
  cp -f "$MODPATH/.env.example" "$CONFIG_FILE" &&
    ui_print "- Created $CONFIG_FILE from .env.example (edit it before reboot)"
else
  ui_print "! No .env.example found; create $CONFIG_FILE manually"
fi

# Persistent agent state (fingerprint). Required on Android — default
# /var/lib/beszel-agent is not usable / not writable.
if [ -z "$(ls -A "$STATE_DIR" 2>/dev/null)" ] && [ "$INSTALLED_DIR/data" != "$STATE_DIR" ]; then
  if [ -n "$(ls -A "$INSTALLED_DIR/data" 2>/dev/null)" ]; then
    cp -a "$INSTALLED_DIR/data/." "$STATE_DIR/" 2>/dev/null &&
      ui_print "- Migrated agent state from $INSTALLED_DIR/data"
  fi
fi

# Keep the documented in-module paths working: they are symlinks to the
# persistent location, so editing them edits the file that actually survives.
rm -f "$MODPATH/.env"
ln -s "$CONFIG_FILE" "$MODPATH/.env"
rm -rf "$MODPATH/data"
ln -s "$STATE_DIR" "$MODPATH/data"

# Ensure DATA_DIR is set for configs that predate this field.
if [ -f "$CONFIG_FILE" ] && ! grep -q '^DATA_DIR=' "$CONFIG_FILE" 2>/dev/null; then
  printf '\nDATA_DIR=%s\n' "$STATE_DIR" >> "$CONFIG_FILE"
fi

set_perm "$CONFIG_FILE" 0 0 0600
set_perm "$STATE_DIR" 0 0 0700

ui_print "- Done. Edit $CONFIG_FILE then reboot."