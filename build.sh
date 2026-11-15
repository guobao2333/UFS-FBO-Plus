#!/bin/sh
set -eu

# Build the module zip. Single source of content: module/. Single source of
# version: module/module.prop. The upstream repository is fixed on purpose.
#
# Env var (optional):
#   ZIP_NAME=x.zip    output file name (default FBOPlus.zip)

REPO=guobao2333/UFS-FBO-Plus
ROOT="$(cd "$(dirname "$0")" && pwd)"
MODULE_DIR="$ROOT/module"
BUILD_DIR="$ROOT/build"
ZIP_NAME="${ZIP_NAME:-FBOPlus.zip}"
OUT_ZIP="$BUILD_DIR/$ZIP_NAME"

# Stage outside the repo: some Android paths (/sdcard) cannot keep file modes,
# and update-binary must be executable inside the zip.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/fbo-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT INT TERM

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cp -R "$MODULE_DIR/." "$STAGE/"

# /sdcard 之类路径保存不了执行位，统一在暂存区修好
for f in "$STAGE"/*.sh; do
    [ -f "$f" ] && chmod 755 "$f"
done

prop() { sed -n "s/^$1=//p" "$STAGE/module.prop" | head -n 1; }
MODID="$(prop id)"
VERSION="$(prop version)"
VERSION_CODE="$(prop versionCode)"
[ -n "$VERSION" ] && [ -n "$VERSION_CODE" ] || {
  echo "! module.prop is missing version/versionCode" >&2
  exit 1
}

########### META-INF ###########
# Magisk-compatible installer, also understood by KernelSU/MMRL.
META="$STAGE/META-INF/com/google/android"
mkdir -p "$META"

printf '#MAGISK\n' > "$META/updater-script"

cat > "$META/update-binary" <<'EOF'
#!/sbin/sh

#################
# Initialization
#################

umask 022

# echo before loading util_functions
ui_print() { echo "$1"; }

require_new_magisk() {
  ui_print "*******************************"
  ui_print " Please install Magisk v20.4+! "
  ui_print "*******************************"
  exit 1
}

#########################
# Load util_functions.sh
#########################

OUTFD=$2
ZIPFILE=$3

mount /data 2>/dev/null

[ -f /data/adb/magisk/util_functions.sh ] || require_new_magisk
. /data/adb/magisk/util_functions.sh
[ $MAGISK_VER_CODE -lt 20400 ] && require_new_magisk

install_module
exit 0

EOF

chmod 755 "$META/update-binary"
########## META-INF END ###########

(cd "$STAGE" && zip -qr "$OUT_ZIP" . -x '.*')
echo "zip: $OUT_ZIP ($MODID $VERSION)"

# update.json is a release asset, not part of the zip.
cat > "$BUILD_DIR/update.json" <<EOF
{
  "version": "$VERSION",
  "versionCode": $VERSION_CODE,
  "zipUrl": "https://github.com/$REPO/releases/latest/download/$ZIP_NAME",
  "changelog": "https://raw.githubusercontent.com/$REPO/main/CHANGELOG.md"
}
EOF
echo "update.json: $BUILD_DIR/update.json"
