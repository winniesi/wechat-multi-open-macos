#!/bin/bash
# ============================================================
#  macOS 微信多开 / 修复脚本  (支持微信 4.x)
#
#  用法：
#      sudo bash wechat-multi-fix.sh
#
#  它做三件事，缺一不可：
#      1. 复制 WeChat.app      ->  /Applications/WeChatN.app
#      2. 改 CFBundleIdentifier ->  com.tencent.xinWeChatN（必须唯一）
#      3. codesign 重新 ad-hoc 签名
#  少第 2 步：会提示「另一个实例正在运行」或第二个微信闪退
#  少第 3 步：macOS 直接拒绝启动，提示「已损坏」或打开失败
#
#  数据安全：
#      聊天记录存在 ~/Library/Containers/<BundleID>/，与 App 本体分离，
#      删除 / 重建 App 都不会影响聊天记录，也不会掉登录状态。
#
#  兼容：macOS 自带 bash 3.2（不使用 bash 4+ 语法）
# ============================================================

set -uo pipefail

APPS_DIR="${APPS_DIR:-/Applications}"          # 可覆盖，便于测试
SRC="${SRC:-${APPS_DIR}/WeChat.app}"           # 可覆盖，便于测试
APP_PREFIX="WeChat"
BUNDLE_PREFIX="com.tencent.xinWeChat"
MIN_COUNT=2
MAX_COUNT=9
DEFAULT_COUNT=2
QUIT_WAIT_RETRIES="${QUIT_WAIT_RETRIES:-20}"   # 用户回车后最多再等几秒确认已退出

# 匹配所有微信主进程（WeChat.app / WeChat2.app / ... 及其 Helper）
PROC_PATTERN="${APPS_DIR}/WeChat[0-9]*\.app/Contents/MacOS/WeChat"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info() { echo -e "${BLUE}[信息]${NC} $*"; }
ok()   { echo -e "${GREEN}[成功]${NC} $*"; }
warn() { echo -e "${YELLOW}[注意]${NC} $*"; }
die()  { echo -e "${RED}[失败]${NC} $*" >&2; exit 1; }

# 从终端读入（脚本用 sudo 运行，仍从用户终端读取）
ask() {
  local prompt="$1"
  REPLY=""
  if [ -r /dev/tty ]; then
    read -r -p "$prompt" REPLY < /dev/tty || { echo; die "未获取到输入，已退出。"; }
  else
    read -r -p "$prompt" REPLY || { echo; die "未获取到输入，已退出。"; }
  fi
}

# sudo 会把 $HOME 改成 /var/root，必须还原成真实用户的家目录
real_home() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    eval echo "~${SUDO_USER}"
  else
    echo "$HOME"
  fi
}

wechat_pids() { pgrep -f "$PROC_PATTERN" 2>/dev/null || true; }

# ------------------------------------------------------------
# 1. 选择要开几个微信
# ------------------------------------------------------------
select_count() {
  local input
  echo
  echo -e "${BOLD}要同时运行几个微信？${NC}"
  echo "  · 数量包含原版主程序：输入 2 = 双开（主程序 + 1 个分身）"
  echo "  · 允许范围 ${MIN_COUNT}-${MAX_COUNT}，直接按回车 = ${DEFAULT_COUNT}"
  echo
  while :; do
    ask "请输入数量 [默认 ${DEFAULT_COUNT}]: "
    input="${REPLY:-}"
    [ -z "$input" ] && input="$DEFAULT_COUNT"
    if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge "$MIN_COUNT" ] && [ "$input" -le "$MAX_COUNT" ]; then
      COUNT="$input"
      return 0
    fi
    warn "无效输入「${input}」，请输入 ${MIN_COUNT}-${MAX_COUNT} 之间的数字。"
  done
}

# ------------------------------------------------------------
# 2. 根据数量生成清单
# ------------------------------------------------------------
build_instances() {
  local i
  INSTANCES=()   # 每项格式：App 文件名:BundleID:显示名
  ALL_APPS=("$SRC")
  for i in $(seq 2 "$COUNT"); do
    INSTANCES+=("${APP_PREFIX}${i}.app:${BUNDLE_PREFIX}${i}:微信${i}")
    ALL_APPS+=("${APPS_DIR}/${APP_PREFIX}${i}.app")
  done
}

# 清理本次用不到的旧副本（只删 App，不删数据）
cleanup_leftovers() {
  local f base idx
  local extras=()
  for f in "$APPS_DIR"/${APP_PREFIX}[0-9]*.app; do
    [ -d "$f" ] || continue
    base="$(basename "$f" .app)"
    idx="${base#$APP_PREFIX}"
    [[ "$idx" =~ ^[0-9]+$ ]] || continue
    [ "$idx" -ge 2 ] || continue
    [ "$idx" -le "$COUNT" ] && continue
    extras+=("$f")
  done

  [ "${#extras[@]}" -gt 0 ] || return 0

  echo
  warn "检测到本次用不到的旧副本："
  printf '       %s\n' "${extras[@]}"
  ask "  要删除它们吗？（只删 App，不影响聊天记录）(y/N) "
  if [[ "${REPLY:-}" =~ ^[Yy]$ ]]; then
    for f in "${extras[@]}"; do
      case "$f" in
        "$APPS_DIR"/"${APP_PREFIX}"[0-9]*.app) rm -rf "$f" && info "已删除 $f" ;;
        *) warn "跳过异常路径：$f" ;;
      esac
    done
    ok "旧副本已清理"
  else
    info "保留旧副本（本次不使用）"
  fi
}

# ------------------------------------------------------------
# 3. 等用户手动退出微信 —— 脚本不会替你杀进程
# ------------------------------------------------------------
wait_for_wechat_quit() {
  local pids pid i
  while :; do
    pids="$(wechat_pids)"
    if [ -z "$pids" ]; then
      ok "微信已全部退出，继续下一步"
      sleep 1
      return 0
    fi

    echo
    warn "检测到微信仍在运行（脚本不会自动结束进程）："
    for pid in $pids; do
      printf '       PID %-7s %s\n' "$pid" "$(ps -p "$pid" -o comm= 2>/dev/null)"
    done
    cat <<'EOF'

  请手动退出全部微信，任选一种方式：
    · 切到微信窗口，按 ⌘Q
    · 菜单栏「微信」→「退出微信」
    · 右键 Dock 里的微信图标 →「退出」
EOF
    echo
    ask "  全部退出后按【回车】继续（输入 k 强制退出 / 输入 q 放弃）："

    case "${REPLY:-}" in
      q|Q)
        echo
        info "已取消，未对系统做任何改动。"
        exit 0
        ;;
      k|K)
        ask "  强制退出可能让微信来不及保存数据，仍要继续？(y/N) "
        if [[ "${REPLY:-}" =~ ^[Yy]$ ]]; then
          warn "正在强制退出微信…"
          kill $pids 2>/dev/null || true
          sleep 2
          kill -9 $pids 2>/dev/null || true
          sleep 1
        fi
        continue
        ;;
    esac

    # 给进程一点真正退出的时间，避免误报（最多等 QUIT_WAIT_RETRIES 秒）
    for i in $(seq 1 "$QUIT_WAIT_RETRIES"); do
      [ -z "$(wechat_pids)" ] && break
      sleep 1
    done
  done
}

# ------------------------------------------------------------
# 4. 逐个重建分身
# ------------------------------------------------------------
rebuild_instances() {
  local entry APPNAME BUNDLEID DISPNAME DEST CONTAINER HOME_DIR SIZE SIGN_OUT
  HOME_DIR="$(real_home)"

  for entry in "${INSTANCES[@]}"; do
    IFS=':' read -r APPNAME BUNDLEID DISPNAME <<< "$entry"
    DEST="${APPS_DIR}/$APPNAME"

    echo
    info "=========== 处理 ${APPNAME}  (BundleID: ${BUNDLEID}) ==========="

    CONTAINER="${HOME_DIR}/Library/Containers/${BUNDLEID}"
    if [ -d "$CONTAINER" ]; then
      SIZE="$(du -sh "$CONTAINER" 2>/dev/null | cut -f1)"
      info "已有数据目录（${SIZE:-未知大小}），聊天记录会保留，无需重新登录"
    else
      warn "暂无数据目录，首次启动需要扫码登录"
    fi

    if [ -d "$DEST" ]; then
      info "[1/5] 删除旧副本 ${APPNAME}"
      rm -rf "$DEST" || die "删除 $DEST 失败"
    else
      info "[1/5] 首次创建 ${APPNAME}"
    fi

    info "[2/5] 复制主程序（ditto，保留完整结构与资源）"
    ditto "$SRC" "$DEST" || die "复制 $SRC -> $DEST 失败"

    info "[3/5] 修改 Bundle Identifier -> ${BUNDLEID}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${BUNDLEID}" "$DEST/Contents/Info.plist" \
      || die "PlistBuddy 修改 CFBundleIdentifier 失败"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${DISPNAME}" "$DEST/Contents/Info.plist" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${DISPNAME}" "$DEST/Contents/Info.plist" 2>/dev/null \
      || true

    info "[4/5] 清除 quarantine 隔离属性"
    xattr -cr "$DEST" 2>/dev/null || true

    info "[5/5] 重新 ad-hoc 签名（最容易漏掉的一步）"
    rm -rf "$DEST/Contents/_CodeSignature" 2>/dev/null || true
    if ! SIGN_OUT="$(codesign --force --deep --sign - --timestamp=none "$DEST" 2>&1)"; then
      echo "$SIGN_OUT" | sed 's/^/       /'
      die "codesign 签名失败"
    fi

    ok "${APPNAME} 处理完成"
  done
}

# ------------------------------------------------------------
# 5. 校验签名
# ------------------------------------------------------------
verify_all() {
  local p label pid sigid st idst fail=0
  echo
  info "================ 签名校验 ================"
  for p in "${ALL_APPS[@]}"; do
    label="$(basename "$p")"
    if [ ! -d "$p" ]; then
      printf '  %-16s %s\n' "$label" "不存在"
      fail=1
      continue
    fi
    pid="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$p/Contents/Info.plist" 2>/dev/null)"
    sigid="$(codesign -dvv "$p" 2>&1 | awk -F= '/^Identifier=/{print $2; exit}')"
    if codesign --verify --deep --strict "$p" >/dev/null 2>&1; then st="签名有效"; else st="签名无效"; fail=1; fi
    if [ "$pid" = "$sigid" ]; then idst="ID一致"; else idst="ID不一致"; fail=1; fi
    printf '  %-16s BundleID=%-28s %s  %s\n' "$label" "$pid" "$st" "$idst"
  done
  echo
  return "$fail"
}

# ------------------------------------------------------------
# 6. 以真实用户身份启动（避免以 root 身份运行微信）
# ------------------------------------------------------------
open_instance() {
  local app="$1" u
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    if sudo -u "$SUDO_USER" open -n "$app" 2>/dev/null; then return 0; fi
    u="$(id -u "$SUDO_USER" 2>/dev/null || true)"
    if [ -n "$u" ] && launchctl asuser "$u" sudo -u "$SUDO_USER" open -n "$app" 2>/dev/null; then
      return 0
    fi
  fi
  open -n "$app"
}

# ============================================================
main() {
  echo "============================================================"
  echo "            macOS 微信多开 / 修复脚本  (微信 4.x)"
  echo "============================================================"

  [ "$(id -u)" -eq 0 ] || die "需要管理员权限，请用：sudo bash $0"
  [ -d "$SRC" ] || die "找不到微信主程序：$SRC（请先安装官方微信）"

  local c
  for c in ditto codesign xattr /usr/libexec/PlistBuddy; do
    command -v "$c" >/dev/null 2>&1 || die "缺少系统命令：$c"
  done

  VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SRC/Contents/Info.plist" 2>/dev/null || echo "未知")"
  info "已检测到微信版本：${VER}"

  select_count
  build_instances
  cleanup_leftovers

  echo
  info "本次计划：共启动 ${COUNT} 个微信（原版主程序 + $((COUNT - 1)) 个分身）"
  printf '       %-16s %s\n' "$(basename "$SRC")" "原版主程序（保持原样）"
  local entry APPNAME BUNDLEID DISPNAME
  for entry in "${INSTANCES[@]}"; do
    IFS=':' read -r APPNAME BUNDLEID DISPNAME <<< "$entry"
    printf '       %-16s %s  (%s)\n' "$APPNAME" "$DISPNAME" "$BUNDLEID"
  done

  wait_for_wechat_quit
  rebuild_instances

  if ! verify_all; then
    die "有副本未通过校验，请不要使用它们，并把上面的输出反馈给作者。"
  fi
  ok "全部通过校验"

  echo
  info "依次启动微信…"
  local app
  for app in "${ALL_APPS[@]}"; do
    open_instance "$app"
    sleep 2
  done

  echo
  ok "完成！应该能看到 ${COUNT} 个微信登录窗口。"
  echo
  info "数据目录（删除 App 不会影响这里）："
  local HOME_DIR; HOME_DIR="$(real_home)"
  printf '       %s\n' "${HOME_DIR}/Library/Containers/${BUNDLE_PREFIX}"
  for entry in "${INSTANCES[@]}"; do
    IFS=':' read -r APPNAME BUNDLEID DISPNAME <<< "$entry"
    printf '       %s\n' "${HOME_DIR}/Library/Containers/${BUNDLEID}"
  done

  cat <<'TIP'

小提示：
  · 微信升级后分身会失效（升级会还原原厂签名），重新运行本脚本即可，
    聊天记录不会丢，也不需要重新登录。
  · 想让分身彻底不再自动升级，可以用 WeChatTweak 的「阻止自动更新」：
        brew install sunnyyoung/tap/wechattweak && sudo wechattweak patch
TIP
}

main "$@"
