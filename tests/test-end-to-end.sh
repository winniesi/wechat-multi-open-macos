#!/bin/bash
# ============================================================
#  端到端测试：用一个「假微信」走完完整流程
#      复制 -> 改 BundleID -> 清 xattr -> 重新签名 -> 校验 -> 启动
#
#  特点：
#    · 不会读写 /Applications
#    · 不会启动任何真实的微信
#    · 不需要 sudo
#
#  用法：  bash tests/test-end-to-end.sh
# ============================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/../wechat-multi-fix.sh"

PASS=0
FAIL=0
check() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); printf '  \033[0;32m✅\033[0m %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  \033[0;31m❌\033[0m %s  期望=[%s] 实际=[%s]\n' "$1" "$2" "$3"
  fi
}

TMP="$HERE/.tmp-e2e"
rm -rf "$TMP"; mkdir -p "$TMP/apps"

# ---------- 1. 造一个假 WeChat.app ----------
FAKE_SRC="$TMP/apps/WeChat.app"
mkdir -p "$FAKE_SRC/Contents/MacOS" "$FAKE_SRC/Contents/Resources"
cp /bin/echo "$FAKE_SRC/Contents/MacOS/WeChat"
cat > "$FAKE_SRC/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.tencent.xinWeChat</string>
  <key>CFBundleExecutable</key><string>WeChat</string>
  <key>CFBundleName</key><string>WeChat</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>9.9.9-test</string>
</dict></plist>
PLIST
codesign --force --deep --sign - --timestamp=none "$FAKE_SRC" >/dev/null 2>&1 \
  || { echo "无法为假 App 签名，测试环境异常"; exit 1; }

# ---------- 2. 只加载被测脚本的函数（不执行 main） ----------
FUNCS="$TMP/funcs.sh"
sed '$ d' "$TARGET" > "$FUNCS"
# shellcheck disable=SC1090
source "$FUNCS"

# ---------- 3. 注入测试替身 ----------
ask() { local p="$1"; REPLY=""; read -r -p "$p" REPLY || true; }
wechat_pids() { :; }                       # 假装微信已经退出
QUIT_WAIT_RETRIES=0
OPENED="$TMP/opened.log"; : > "$OPENED"
open_instance() { echo "$1" >> "$OPENED"; } # 不真的启动

APPS_DIR="$TMP/apps"
SRC="$FAKE_SRC"

echo
echo "== 端到端：三开（COUNT=3） =="
COUNT=3
build_instances
check "生成 2 个分身" "2" "${#INSTANCES[@]}"

wait_for_wechat_quit >/dev/null 2>&1
check "假环境无进程 -> 直接继续" "0" "$?"

rebuild_instances >/dev/null 2>&1
RC=$?
check "rebuild_instances 执行成功" "0" "$RC"

# ---------- 4. 校验产物 ----------
for i in 2 3; do
  APP="$APPS_DIR/WeChat${i}.app"
  check "WeChat${i}.app 已生成" "存在" "$([ -d "$APP" ] && echo 存在)"
  check "WeChat${i}.app BundleID 正确" "com.tencent.xinWeChat${i}" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null)"
  check "WeChat${i}.app 签名 ID 与 BundleID 一致" "com.tencent.xinWeChat${i}" \
    "$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Identifier=/{print $2; exit}')"
  check "WeChat${i}.app 是 adhoc 签名" "adhoc" \
    "$(codesign -dvv "$APP" 2>&1 | awk -F= '/^Signature=/{print $2; exit}')"
  check "WeChat${i}.app 严格校验通过" "ok" \
    "$(codesign --verify --deep --strict "$APP" >/dev/null 2>&1 && echo ok)"
  check "WeChat${i}.app 显示名为微信${i}" "微信${i}" \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP/Contents/Info.plist" 2>/dev/null)"
  check "WeChat${i}.app 可执行文件已复制" "存在" \
    "$([ -x "$APP/Contents/MacOS/WeChat" ] && echo 存在)"
done

check "主程序 BundleID 未被改动" "com.tencent.xinWeChat" \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$FAKE_SRC/Contents/Info.plist" 2>/dev/null)"

echo
echo "== 端到端：签名校验函数 =="
verify_all >/dev/null 2>&1
check "3 个 App 全部校验通过" "0" "$?"

echo
echo "== 端到端：启动流程（替身，不真的启动） =="
for app in "${ALL_APPS[@]}"; do open_instance "$app"; done
check "启动命令覆盖 3 个实例" "3" "$(wc -l < "$OPENED" | tr -d ' ')"
check "启动列表包含 WeChat2.app" "yes" \
  "$(grep -q 'WeChat2.app' "$OPENED" && echo yes)"
check "启动列表包含 WeChat3.app" "yes" \
  "$(grep -q 'WeChat3.app' "$OPENED" && echo yes)"

echo
echo "== 端到端：重复运行应幂等 =="
rebuild_instances >/dev/null 2>&1
check "二次 rebuild 后仍校验通过" "0" "$(verify_all >/dev/null 2>&1; echo $?)"
check "二次 rebuild 后 BundleID 未变" "com.tencent.xinWeChat2" \
  "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APPS_DIR/WeChat2.app/Contents/Info.plist" 2>/dev/null)"

rm -rf "$TMP"
echo
echo "============================================"
echo "  通过 $PASS 项，失败 $FAIL 项"
echo "============================================"
[ "$FAIL" -eq 0 ] || exit 1
