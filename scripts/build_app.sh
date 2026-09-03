#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/swiftpm-module-cache"
export SWIFTPM_CONFIG_DIR="$PROJECT_DIR/.swiftpm-config"
export XDG_CACHE_HOME="$PROJECT_DIR/.build/xdg-cache"

swift build --disable-sandbox -c release --product MailDigestDesktop
BIN_DIR="$(swift build --disable-sandbox -c release --show-bin-path)"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/邮件摘要.app"
STAGE_DIR="$(mktemp -d /private/tmp/MailDigestDesktop-build.XXXXXX)"
STAGE_APP="$STAGE_DIR/邮件摘要.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Config/Info.plist")"
ARCHIVE="$DIST_DIR/邮件摘要-$VERSION.zip"
SIGNING_IDENTITY="${MAIL_BRIEF_SIGNING_IDENTITY:--}"
trap 'rm -rf "$STAGE_DIR"' EXIT

if [[ "$SIGNING_IDENTITY" != "-" ]] && ! security find-identity -v -p codesigning | rg -Fq "\"$SIGNING_IDENTITY\""; then
    echo "找不到可用的固定签名证书：$SIGNING_IDENTITY" >&2
    echo "请在 Xcode > Settings > Apple Accounts > Personal Team > Manage Certificates 中创建 Apple Development 证书。" >&2
    exit 1
fi

mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"
cp "$BIN_DIR/MailDigestDesktop" "$STAGE_APP/Contents/MacOS/MailDigestDesktop"
cp "$PROJECT_DIR/Config/Info.plist" "$STAGE_APP/Contents/Info.plist"
for localization in en.lproj zh-Hans.lproj; do
    if [[ -d "$PROJECT_DIR/Config/$localization" ]]; then
        cp -R "$PROJECT_DIR/Config/$localization" "$STAGE_APP/Contents/Resources/$localization"
    fi
done

ICON_SOURCE="$PROJECT_DIR/Assets/AppIcon-1024.png"
ICON_FILE="$PROJECT_DIR/Assets/AppIcon.icns"
if [[ -f "$ICON_SOURCE" && -f "$ICON_FILE" ]]; then
    cp "$ICON_FILE" "$STAGE_APP/Contents/Resources/AppIcon.icns"
    sips -z 1024 1024 "$ICON_SOURCE" --out "$STAGE_APP/Contents/Resources/AppIcon-1024.png" >/dev/null
fi

verified=false
for attempt in 1 2 3; do
    xattr -cr "$STAGE_APP"
    if codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" "$STAGE_APP"; then
        if codesign --verify --deep --strict "$STAGE_APP"; then
            verified=true
            break
        fi
    fi
    sleep 0.2
done

if [[ "$verified" != true ]]; then
    echo "无法清理文件同步附加的属性并验证应用签名。" >&2
    exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$APP_DIR"
rm -f "$ARCHIVE"
ditto --norsrc "$STAGE_APP" "$APP_DIR"
ditto -c -k --norsrc --keepParent "$STAGE_APP" "$ARCHIVE"
echo "$APP_DIR"
echo "$ARCHIVE"
