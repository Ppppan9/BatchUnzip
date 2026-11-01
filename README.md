# 批量解压（BatchUnzip）

**English**: BatchUnzip is a native macOS batch archive extractor (single-file Swift/AppKit, no external dependencies in the app itself). Select multiple archives in Finder → Open With → BatchUnzip → enter the password once. Supports zip / rar / 7z / tar.gz and more, extracts nested archives recursively, runs extractions in parallel (adaptive to CPU cores, longest-job-first scheduling). See [使用方法](#使用方法) and [下载安装](#下载安装) below. UI is in Chinese.

---

macOS 上的批量解压工具：在 Finder 里**选中多个压缩包 → 右键「打开方式」→ 批量解压 → 输一次密码**，全部解压完成。

支持格式：zip、rar、7z、tar、gz、tgz、bz2、tbz、xz、txz、Z、lzma、cab、**dmg**（含 AES 加密镜像）、**iso**、**wim**、**apk / ipa / jar**（zip 容器）。

## 下载安装

两种方式任选：

1. **直接下载**（推荐）：到 [Releases](../../releases) 下载 `BatchUnzip-vX.X-macOS-arm64.zip`，解压得到「批量解压.app」，拖进「应用程序」文件夹。**应用内置 7-Zip 解压引擎，下载即用、全格式支持，无需安装任何依赖。** 应用使用 ad-hoc 签名（无 Apple 开发者公证），首次打开需在终端执行：

   ```bash
   xattr -cr /Applications/批量解压.app
   ```

   或者：右键点击应用 →「打开」→ 再点「打开」。

2. **自己构建**：克隆本仓库后运行 `./build.sh`（需要 Xcode Command Line Tools），脚本会自动编译、生成图标、嵌入内置引擎并安装到 /Applications。仅支持 Apple Silicon（arm64）。

> 内置引擎说明：应用打包了 7-Zip 官方命令行引擎 `7zz`（未修改的官方 arm64 二进制），解压优先使用它；系统里装有 unar 时 zip 会优先走 unar（GBK 乱码修复更强）。引擎许可见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

## 使用方法

1. Finder 中选中一个或多个压缩包（不同格式混选也可以）
2. 右键 → **打开方式** → **其他…** → 选择「批量解压」（在"应用程序"文件夹里，首次选择后就会常驻列表）
3. 弹出密码框：有密码就输入，没密码直接点「开始解压」
4. 结束后弹出汇总（成功/失败原因），可一键在 Finder 中打开所有解压结果

也可以把文件直接**拖到 Dock 上的应用图标**解压；双击应用会弹出文件选择框。

## 解压规则

- 每个压缩包解压到**它所在目录下、以它名字命名的文件夹**（`a.zip` → `a/`），重名自动加序号（`a 2`），绝不覆盖已有内容
- **完全解压（嵌套递归）**：压缩包里还有压缩包时，用同一密码逐层解到只剩最终文件/文件夹；解压成功的内部压缩包会被删除（顶层你选中的原文件永不删除），最多递归 8 层；内部包解压失败只作警告，主体内容照常使用
- 分卷自动去重：`.part1.rar … .partN.rar`、`.zip.001 … .NNN` 这类分卷只解第一卷（`.001` 首卷直接可解），其余跳过
- **智能免密**：启动解压前自动探测（并行读取压缩包头），确认所选包全部未加密时直接开解、不弹密码框；有加密包才询问
- **密码只对加密的压缩包生效**：每个包先带密码试一轮、再不带密码试一轮，避免误报「密码错误」；与密码无关的失败不会浪费第二轮重试
- 密码框支持 ⌘V 粘贴（应用带有标准「编辑」菜单），并有「显示密码」开关可核对输入
- **失败可重试**：汇总弹窗提供「用新密码重试失败项」，适合一批文件里有多个不同密码的情况
- 内层压缩包密码与外层不同时会在警告中明确指出是哪个包失败，且**保留该内层包**，可单独重解
- 解压过程中按 ⌘Q 会先弹确认，确认退出会终止解压子进程，不会留下孤儿进程

## 界面与进度

- 进度窗口：应用图标 + 「正在解压（3/12）」+ 当前文件名 + 数字进度条 + 解压中转轮指示；后台时 Dock 图标角标同步显示进度，完成后切走会弹跳提醒；批量开始前有「检查加密状态」短暂过渡
- **大文件细粒度进度**：7zz 解压时解析其百分比输出，当前文件实时显示「· 45%」（每 5% 刷新）
- **取消立即生效**：点取消会终止正在进行的解压子进程，且不会继续启动新的解压进程；CLI 模式收到 SIGTERM/SIGINT 同样先终止子进程再退出，不留孤儿
- **并行解压**：多个压缩包并发解压（嵌套树内部保持串行），并行度按 CPU 核数自适应（2~6 路），并采用**长作业优先调度**（大包先启动、小包填充空隙，混合批次实测比先来先解快约 36%）；实测 8×40MB 包从串行 8.4s 提速到并行 2.5s（约 3.4 倍）
- **GBK 中文文件名自动修复**：unar 自动探测把 GBK 误判为其他编码时（典型特征是解出西里尔字母乱码名），自动改用 GBK 编码重解一次（仅 zip、仅中文系统环境；交换全程带备份与回滚，失败保留原结果）
- 汇总弹窗显示总耗时，失败/警告项列出原因，可一键在 Finder 中打开所有输出目录

## 已知限制

- 密码通过命令行参数传给解压引擎（unar/7zz/unzip 均只支持这种方式），理论上同机的其他用户可用 `ps` 看到；日志中已刻意不记录密码
- GBK 文件名修复是启发式：zh 系统环境下，文件名本身是西里尔字母（俄语等）的 zip 也会被误判为 GBK 乱码而重解（内容无损、文件名会被改写）；这是「GBK 误判」与「真俄语」在信息上无法完美区分的固有限制
- Zstandard（.zst）暂不支持：内置的 7zz 与 unar 均不含 Zstandard 解码器
- DMG 解压只读挂载后拷贝内容，不支持转换格式；带许可协议（EULA）的镜像会在汇总中提示失败

## 排查问题

每次解压的详细过程（用了哪个后端、退出码、错误信息，**不含密码内容**）会追加到日志：

```
~/Library/Logs/BatchUnzip.log
```

失败的汇总弹窗里也会提示这个日志路径。

## 解压后端

应用按格式自动选择引擎，失败自动降级。**应用内置 7-Zip 官方引擎（`7zz`），开箱即支持全部格式**；系统里另装的引擎会作为补充：

| 格式 | 优先顺序 |
|---|---|
| rar / 7z / cab | **内置 7zz** → unar → unrar |
| zip | unar（自动修复 GBK 文件名乱码）→ **内置 7zz** → unzip |
| tar / gz / bz2 / xz 等 | bsdtar（系统自带）→ unar → **内置 7zz** |
| dmg | hdiutil 挂载拷贝（支持 AES 加密镜像密码） |
| iso / wim | **内置 7zz** |

若都没有内置引擎（自行构建且未 vendor），首次解压 rar/7z 时会弹窗询问是否通过 Homebrew 自动安装。

## 命令行模式

可执行文件也可以当 CLI 用（用于脚本/测试）：

```bash
/Applications/批量解压.app/Contents/MacOS/BatchUnzip [-p 密码] 文件1.zip 文件2.rar ...
```

## 修改与重新构建

源码就在本目录（`main.swift` + `Info.plist` + `make_icon.swift`），改完运行：

```bash
./build.sh    # 编译 → 生成图标 → 签名 → 安装到 /Applications → 注册 LaunchServices
./test.sh     # 自动化回归测试（32 个用例：格式/密码/分卷/嵌套/路径穿越/日志）
```

构建产物在 `build/批量解压.app`。图标由 `make_icon.swift` 用 CoreGraphics 程序化绘制（渐变圆角板 + 拉链 + 箭头），经 `iconutil` 转成 .icns。

## 技术说明

- 纯 Swift + AppKit 单文件实现，无需 Xcode 工程
- 通过 `CFBundleDocumentTypes` 声明压缩包类型（`LSHandlerRank=Alternate`，不抢占默认打开方式），Finder 多选时「打开方式」才会出现本应用
- 接收 Finder 的 `odoc` Apple Event（`application(_:openFiles:)`）拿到多文件列表
- 密码判定：先带密码再不带密码双轮尝试；`Wrong password`/`Break signaled`（7zz 无密码遇加密包的 stdin EOF 表现）等特征判为密码类错误
- 嵌套解压：`processFiles` 用队列逐层处理，每个成功的解压结果目录都会被扫描（`findArchivesRecursively`），发现的压缩包继续入队；主菜单由代码构建（`installMainMenu`），提供编辑菜单以支持密码框 ⌘V 粘贴
