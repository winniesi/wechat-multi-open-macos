# macOS 微信多开脚本（支持微信 4.x）

一个单文件 shell 脚本，在 macOS 上实现微信**双开 / 多开**（同时登录多个微信号）。

- 交互式选择开几个（**直接回车 = 双开**）
- 会**提示你手动退出微信**，不会偷偷杀掉你的进程
- 自动改 `Bundle Identifier` + 重新签名，并**逐个校验签名**后才启动
- **不会丢聊天记录**，重建后无需重新登录
- 兼容 macOS 自带的 bash 3.2，无需安装任何依赖

```
============================================================
            macOS 微信多开 / 修复脚本  (微信 4.x)
============================================================
[信息] 已检测到微信版本：4.1.11

要同时运行几个微信？
  · 数量包含原版主程序：输入 2 = 双开（主程序 + 1 个分身）
  · 允许范围 2-9，直接按回车 = 2

请输入数量 [默认 2]: 
[信息] 本次计划：共启动 2 个微信（原版主程序 + 1 个分身）
       WeChat.app       原版主程序（保持原样）
       WeChat2.app      微信2  (com.tencent.xinWeChat2)
```

---

## 为什么需要"改 ID + 重新签名"

macOS 版微信对每个实例做**单实例检测**，检测依据是应用的 `Bundle Identifier`；
同时 macOS 系统会校验应用签名，一旦你改过 `Info.plist`，原厂签名就失效了。

所以缺任何一步都会失败：

| 只做了 | 现象 |
| --- | --- |
| 复制 App | 打开第二个时提示"另一个实例正在运行"，或第二个窗口一闪而过 |
| 复制 + 改 Bundle ID | 提示"应用已损坏，移到废纸篓"，或直接打不开 |
| 复制 + 改 Bundle ID + **重新签名** | ✅ 正常多开 |

用 `codesign --verify` 可以清楚地看到前两种情况的报错：

```
WeChat2.app: invalid Info.plist (plist or signature have been modified)
```

## 数据存放在哪里

微信 macOS 版把数据放在以 `Bundle Identifier` 命名的容器里，**和 App 本体完全分离**：

```
/Applications/WeChat.app    ->  ~/Library/Containers/com.tencent.xinWeChat/
/Applications/WeChat2.app   ->  ~/Library/Containers/com.tencent.xinWeChat2/
/Applications/WeChat3.app   ->  ~/Library/Containers/com.tencent.xinWeChat3/
```

因此：

- 删除 / 重建 `WeChat2.app` **不会**删除 `com.tencent.xinWeChat2` 容器
- 聊天记录、登录状态都保留，重建后打开即是已登录状态
- 想彻底删除某个分身，需要同时删掉 App 和对应的容器目录

---

## 使用方法

### 环境要求

- macOS（Apple Silicon / Intel 均可）
- 已安装官方微信（`/Applications/WeChat.app`）
- 微信 4.x 及以上版本

### 运行

```bash
sudo bash wechat-multi-fix.sh
```

或者先下载再运行：

```bash
curl -fsSLO https://raw.githubusercontent.com/winniesi/wechat-multi-open-macos/main/wechat-multi-fix.sh
sudo bash wechat-multi-fix.sh
```

> 必须用 `sudo`：脚本要写入 `/Applications`，并调用 `codesign` 重新签名。

### 运行时的交互

1. **输入要开几个微信**（含原版主程序），直接回车就是双开。
   - 输入 `2` = 双开（主程序 + 1 个分身）
   - 输入 `3` = 三开（主程序 + 2 个分身）
   - 范围 2-9
2. 如果 `/Applications` 里还有本次用不到的旧副本，脚本会**询问**是否删除（默认保留，只删 App 不删数据）。
3. **脚本会列出正在运行的微信进程，并请你手动退出**：
   ```
   [注意] 检测到微信仍在运行（脚本不会自动结束进程）：
          PID 83948   /Applications/WeChat.app/Contents/MacOS/WeChat
          PID 83965   /Applications/WeChat2.app/Contents/MacOS/WeChat

     请手动退出全部微信，任选一种方式：
       · 切到微信窗口，按 ⌘Q
       · 菜单栏「微信」→「退出微信」
       · 右键 Dock 里的微信图标 →「退出」

     全部退出后按【回车】继续（输入 k 强制退出 / 输入 q 放弃）：
   ```
   - 按 **回车**：脚本确认进程确实退干净了才继续
   - 输入 **q**：放弃并退出，不改动任何东西
   - 输入 **k**：仅在你明确二次确认后才会强制结束进程（微信卡死时用）
4. 脚本逐个重建分身、重新签名，并打印校验结果：

   ```
   ================ 签名校验 ================
     WeChat.app       BundleID=com.tencent.xinWeChat        签名有效  ID一致
     WeChat2.app      BundleID=com.tencent.xinWeChat2       签名有效  ID一致
   ```
   **任何一项不通过，脚本会中止且不启动微信**，避免你拿到一个打不开的副本。

---

## 微信升级之后又失效了？

微信升级会覆盖 App 并还原原厂签名，分身通常会失效。**重新运行一次脚本即可**，
聊天记录不会丢，也不需要重新登录。

想一劳永逸，可以用 [WeChatTweak](https://github.com/sunnyyoung/WeChatTweak) 的「阻止自动更新」：

```bash
brew install sunnyyoung/tap/wechattweak
sudo wechattweak patch
```

## 卸载

```bash
# 只删分身 App（保留聊天记录）
sudo rm -rf /Applications/WeChat2.app /Applications/WeChat3.app

# 连聊天记录一起删掉（谨慎！）
rm -rf ~/Library/Containers/com.tencent.xinWeChat2 ~/Library/Containers/com.tencent.xinWeChat3
```

---

## 测试

仓库自带两套测试，**不需要 sudo，也不会改动 `/Applications`**：

```bash
bash tests/test-interactive.sh    # 交互逻辑（数量选择 / 退出等待 / 旧副本清理 / 校验函数）
bash tests/test-end-to-end.sh     # 端到端（用假 App 走完复制->改ID->签名->校验->启动）
```

`test-interactive.sh` 的第 6 节会在**只读**模式下打印本机真实的签名状态，方便排查问题。

## 常见问题

**Q：会封号吗？**
不会。脚本只是复制 App 并重新签名，不修改微信本体、不注入任何代码、没有防撤回或抢红包之类的行为。

**Q：提示"应用已损坏，移到废纸篓"？**
重新运行脚本即可，脚本会自动执行 `xattr -cr` 清除隔离属性。

**Q：能开几个？**
脚本允许 2-9 个。每个分身约占 650MB 磁盘（各自还有独立的数据目录）。

**Q：为什么一定要我自己退出微信？**
脚本在替换 `/Applications` 下的 App 时，如果进程还在运行，可能读到被替换到一半的文件。
交给你手动退出最安全，也避免脚本误杀你正在编辑的消息。

**Q：Intel Mac 能用吗？**
可以，脚本不区分架构（`ditto` + `codesign` 对通用二进制同样有效）。

## 其它方案

| 方案 | 优点 | 缺点 |
| --- | --- | --- |
| 本脚本 | 免费、可重复运行、数据不丢 | 微信升级后需重跑一次 |
| [WeChatTweak](https://github.com/sunnyyoung/WeChatTweak) | 多开 + 阻止自动更新 + 防撤回 | 需要 patch，跟随微信版本更新 |
| 虚拟机（Parallels / VMware / UTM） | 完全隔离，最稳 | 占资源，需另装系统 |
| 多用户账户 + 快速用户切换 | 系统级隔离，零风险 | 切换麻烦 |
| [PlayCover](https://github.com/PlayCover/PlayCover) 跑 iPad 版 | 独立于 Mac 版 | 需要 iPad 版 ipa |

## 免责声明

本项目仅供学习与研究使用。请在遵守微信软件许可协议的前提下自行评估风险，
因使用本脚本造成的任何账号异常、数据丢失或系统问题，由使用者自行承担。

## License

[MIT](LICENSE)
