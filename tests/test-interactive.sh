#!/bin/bash
# ============================================================
#  交互逻辑测试（不需要 sudo，不会修改 /Applications）
#
#  用法：  bash tests/test-interactive.sh
# ============================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/../wechat-multi-fix.sh"

PASS=0
FAIL=0
check() { # check "描述" "期望" "实际"
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); printf '  \033[0;32m✅\033[0m %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  \033[0;31m❌\033[0m %s  期望=[%s] 实际=[%s]\n' "$1" "$2" "$3"
  fi
}

[ -f "$TARGET" ] || { echo "找不到脚本：$TARGET"; exit 1; }

TMP="$HERE/.tmp-test"
rm -rf "$TMP"; mkdir -p "$TMP"

# 载入被测脚本的函数定义（去掉最后一行的 main 调用）
FUNCS="$TMP/funcs.sh"
sed '$ d' "$TARGET" > "$FUNCS"
# shellcheck disable=SC1090
source "$FUNCS"

# 测试环境下把 ask 改成从 stdin 读取（真实脚本从 /dev/tty 读）
ask() { local p="$1"; REPLY=""; read -r -p "$p" REPLY || true; }

fake_apps() {
  local d="$TMP/apps"
  rm -rf "$d"; mkdir -p "$d/WeChat.app" "$d/WeChat2.app" "$d/WeChat3.app" "$d/WeChat5.app"
  echo "$d"
}

echo
echo "== 1. 选择数量（回车默认 2） =="
COUNT=""; select_count <<< "" >/dev/null
check "直接回车 -> 默认 2" "2" "$COUNT"

COUNT=""; select_count <<< "3" >/dev/null
check "输入 3 -> 3" "3" "$COUNT"

COUNT=""; select_count <<< "9" >/dev/null
check "输入 9（上限）-> 9" "9" "$COUNT"

COUNT=""; select_count <<< $'10\n2' >/dev/null
check "输入 10 被拒绝后重输 2" "2" "$COUNT"

COUNT=""; select_count <<< $'abc\n4' >/dev/null
check "输入 abc 被拒绝后重输 4" "4" "$COUNT"

COUNT=""; select_count <<< $'1\n5' >/dev/null
check "输入 1 被拒绝（至少 2）后重输 5" "5" "$COUNT"

echo
echo "== 2. 分身清单生成 =="
COUNT=2; build_instances
check "双开 -> 1 个分身" "1" "${#INSTANCES[@]}"
check "双开 -> 共 2 个 App" "2" "${#ALL_APPS[@]}"
check "双开 -> BundleID 正确" "WeChat2.app:com.tencent.xinWeChat2:微信2" "${INSTANCES[0]}"

COUNT=4; build_instances
check "四开 -> 3 个分身" "3" "${#INSTANCES[@]}"
check "四开 -> 第 3 个分身是 WeChat4" "WeChat4.app:com.tencent.xinWeChat4:微信4" "${INSTANCES[2]}"
check "四开 -> ALL_APPS 含 4 项" "4" "${#ALL_APPS[@]}"

echo
echo "== 3. 旧副本清理（只删 App，不误删） =="
FAKE="$(fake_apps)"
APPS_DIR="$FAKE"; COUNT=2
build_instances
cleanup_leftovers <<< "n" >/dev/null
check "选 n -> WeChat3.app 保留" "保留" "$([ -d "$FAKE/WeChat3.app" ] && echo 保留)"
check "选 n -> WeChat5.app 保留" "保留" "$([ -d "$FAKE/WeChat5.app" ] && echo 保留)"

cleanup_leftovers <<< "y" >/dev/null
check "选 y -> WeChat3.app 被删" "已删" "$([ -d "$FAKE/WeChat3.app" ] || echo 已删)"
check "选 y -> WeChat5.app 被删" "已删" "$([ -d "$FAKE/WeChat5.app" ] || echo 已删)"
check "选 y -> 本次要用的 WeChat2.app 保留" "保留" "$([ -d "$FAKE/WeChat2.app" ] && echo 保留)"
check "选 y -> 主程序 WeChat.app 保留" "保留" "$([ -d "$FAKE/WeChat.app" ] && echo 保留)"

echo
echo "== 4. 等待用户手动退出（默认不杀进程） =="
QUIT_WAIT_RETRIES=1          # 测试时不要真的等 20 秒
COUNTER="$TMP/calls"
KILL_LOG="$TMP/kill.log"

# 4a. 微信本来就没开
wechat_pids() { :; }
wait_for_wechat_quit >/dev/null 2>&1
check "微信已退出 -> 直接继续" "0" "$?"

# 4b. 一直有微信在运行，输入 q 放弃
wechat_pids() { echo 99999; }
( wait_for_wechat_quit <<< "q" >/dev/null 2>&1 ); rc=$?
check "输入 q -> 放弃并以 0 退出" "0" "$rc"

( wait_for_wechat_quit <<< $'x\nQ' >/dev/null 2>&1 ); rc=$?
check "无效输入后仍可 q 放弃" "0" "$rc"

# 4c. 第一次检测到运行中，之后进程消失 -> 用户回车后继续
wechat_pids() {
  local n
  n=$(cat "$COUNTER" 2>/dev/null || echo 0)
  n=$((n + 1)); echo "$n" > "$COUNTER"
  [ "$n" -le 1 ] && echo 99999
}
echo 0 > "$COUNTER"
( wait_for_wechat_quit <<< "" >/dev/null 2>&1 ); rc=$?
check "用户退出后回车 -> 继续执行" "0" "$rc"
check "确实重新检测过进程（调用 >= 3 次）" "yes" "$([ "$(cat "$COUNTER")" -ge 3 ] && echo yes)"

# 4d. 用户主动退出的路径下，脚本绝不能调用 kill
: > "$KILL_LOG"
(
  kill() { echo "kill $*" >> "$KILL_LOG"; }
  wechat_pids() { :; }
  wait_for_wechat_quit >/dev/null 2>&1
)
check "用户已退出的路径未调用 kill" "0" "$(wc -l < "$KILL_LOG" | tr -d ' ')"

# 4e. 只有明确输入 k 并二次确认 y，才会强制退出（opt-in）
(
  kill() { echo "kill $*" >> "$KILL_LOG"; }
  wechat_pids() { echo 99999; }
  wait_for_wechat_quit <<< $'k\ny\nq' >/dev/null 2>&1
)
check "输入 k + 确认 y 才调用 kill（需显式选择）" "yes" "$([ "$(wc -l < "$KILL_LOG" | tr -d ' ')" -ge 1 ] && echo yes)"

echo
echo "== 5. 校验函数行为 =="
ALL_APPS=("$TMP/NotExist.app")
verify_all >/dev/null 2>&1
check "缺失的 App -> 校验失败(非 0)" "1" "$?"

BROKEN="$TMP/Broken.app"
mkdir -p "$BROKEN/Contents"
cat > "$BROKEN/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.broken</string>
</dict></plist>
PLIST
ALL_APPS=("$BROKEN")
verify_all >/dev/null 2>&1
check "未签名的 App -> 校验失败(非 0)" "1" "$?"

# 伪造一个「签名与 BundleID 一致」的合法应用，校验应通过
GOOD="$TMP/Good.app"
mkdir -p "$GOOD/Contents/MacOS"
cp /bin/echo "$GOOD/Contents/MacOS/Good"
cat > "$GOOD/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.example.good</string>
  <key>CFBundleExecutable</key><string>Good</string>
</dict></plist>
PLIST
codesign --force --deep --sign - --timestamp=none "$GOOD" >/dev/null 2>&1
ALL_APPS=("$GOOD")
verify_all >/dev/null 2>&1
check "正确签名的 App -> 校验通过(0)" "0" "$?"

echo
echo "== 6. 真实环境只读自检（不改动任何文件） =="
if [ -d /Applications/WeChat.app ]; then
  APPS_DIR=/Applications
  COUNT=2
  build_instances
  echo "  当前机器实际签名状态："
  verify_all 2>&1 | sed 's/^/  /'
else
  echo "  未安装微信，跳过"
fi

rm -rf "$TMP"
echo
echo "============================================"
echo "  通过 $PASS 项，失败 $FAIL 项"
echo "============================================"
[ "$FAIL" -eq 0 ] || exit 1
