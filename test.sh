#!/bin/bash
# BatchUnzip 自动化回归测试（CLI 模式驱动 GUI 共用的核心逻辑）
# 用法: ./test.sh          （需要已执行过 build.sh，测试 /Applications 里的版本）
#       APP=path ./test.sh （指定被测可执行文件）
set -u
APP="${APP:-/Applications/批量解压.app/Contents/MacOS/BatchUnzip}"
T="$(mktemp -d /tmp/bztest.XXXXXX)"
PASS=0; FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); say "  ✅ $1"; }
bad()  { FAIL=$((FAIL+1)); say "  ❌ $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# 用法: run_check "名称" 期望退出码 工作目录 -p 密码 文件...
run_check() {
    local name="$1" want_code="$2" dir="$3"; shift 3
    (cd "$dir" && "$APP" "$@" >"$T/last.out" 2>&1)
    local got=$?
    if [ "$got" = "$want_code" ]; then ok "$name"; else bad "$name (exit=$got 期望 $want_code)"; cat "$T/last.out"; fi
}

expect_fail_msg() { # 名称 关键字（在最近一次输出里）
    if grep -q "$2" "$T/last.out"; then ok "$1"; else bad "$1"; say "     输出里没有「$2」："; cat "$T/last.out"; fi
}

if [ ! -x "$APP" ]; then say "❌ 被测程序不存在：$APP（先跑 ./build.sh）"; exit 1; fi
SEVENZZ="$(command -v 7zz || echo /opt/homebrew/bin/7zz)"
command -v zip >/dev/null || { say "❌ 需要 zip 命令"; exit 1; }

say "== 1. 基础格式 =="
mkdir -p "$T/src/sub"; echo hello > "$T/src/a.txt"; echo nested > "$T/src/sub/b.txt"
ditto -c -k "$T/src" "$T/plain.zip"
(cd "$T" && zip -qrP 1234 zc.zip src)
(cd "$T" && "$SEVENZZ" a -tzip -mem=AES256 -p1234 aes.zip src >/dev/null)
(cd "$T" && "$SEVENZZ" a -psecret -mhe=on mhe.7z src >/dev/null)
tar czf "$T/t.tar.gz" -C "$T/src" .
run_check "普通 zip" 0 "$T" plain.zip
check "解压内容正确" "[ \"\$(cat \"$T/plain/a.txt\")\" = hello ]"
run_check "tar.gz + 输入无关密码" 0 "$T" -p 1234 t.tar.gz
check "tar.gz 走 bsdtar 解出完整结构" "[ -f \"$T/t/sub/b.txt\" ]"
run_check "AES-256 zip 正确密码" 0 "$T" -p 1234 aes.zip
check "AES zip 内容正确" "[ -f \"$T/aes/src/sub/b.txt\" ]"
run_check "加密文件名 7z 正确密码" 0 "$T" -p secret mhe.7z
check "7z 内容正确" "[ -f \"$T/mhe/src/a.txt\" ]"
run_check "ZipCrypto 正确密码" 0 "$T" -p 1234 zc.zip

say "== 2. 密码错误场景 =="
run_check "错误密码退出码 1" 1 "$T" -p wrongpw aes.zip
expect_fail_msg "提示密码错误" "密码错误"
run_check "加密包不给密码退出码 1" 1 "$T" mhe.7z
expect_fail_msg "提示需要密码" "需要密码"

say "== 3. 过滤与路径 =="
run_check "非压缩包/不存在文件全部忽略" 2 "$T" src a.txt 不存在.zip
run_check "相对路径可用" 0 "$T" plain.zip
cp "$T/plain.zip" "$T/UPPER.ZIP"
run_check "大写扩展名" 0 "$T" UPPER.ZIP

say "== 4. 分卷 =="
(cd "$T" && "$SEVENZZ" a -v10k split.7z src >/dev/null)
run_check ".7z.001 首卷可解（002 跳过）" 0 "$T" -p1234 split.7z.001 split.7z.002
check "分卷解出完整内容" "[ -f \"$T/split.7z/src/sub/b.txt\" ]"
cp "$T/t.tar.gz" "$T/movie.part1.rar"; cp "$T/t.tar.gz" "$T/movie.part2.rar"
run_check "part2 自动跳过" 0 "$T" movie.part1.rar movie.part2.rar
grep -q "跳过分卷：movie.part2.rar" "$T/last.out" && ok "输出含跳过分卷" || bad "输出含跳过分卷"

say "== 5. 嵌套递归 =="
mkdir -p "$T/pkg/docs"; echo deep > "$T/pkg/docs/deep.txt"
(cd "$T/pkg" && zip -qr "$T/inner.zip" .)
mkdir "$T/m"; cp "$T/inner.zip" "$T/m/"; echo loose > "$T/m/loose.txt"
(cd "$T/m" && zip -qr "$T/mid.zip" .)
mkdir "$T/o"; cp "$T/mid.zip" "$T/o/"; echo top > "$T/o/note.txt"
(cd "$T/o" && zip -qr "$T/outer.zip" .)
run_check "三层嵌套一次解完" 0 "$T" outer.zip
check "最终内容可达" "[ \"\$(cat \"$T/outer/mid/inner/docs/deep.txt\")\" = deep ]"
check "内部中间包已删除" "[ ! -e \"$T/outer/mid.zip\" ] && [ ! -e \"$T/outer/mid/inner.zip\" ]"
check "顶层原始 zip 保留" "[ -f \"$T/outer.zip\" ]"
# 加密嵌套（同密码）
mkdir "$T/o2"; cp "$T/mid.zip" "$T/o2/"
(cd "$T/o2" && zip -qrP 1234 "$T/enc_outer.zip" .)
(cd "$T/pkg" && zip -qrP 1234 "$T/inner_e.zip" .)
mkdir "$T/m2"; cp "$T/inner_e.zip" "$T/m2/"
(cd "$T/m2" && zip -qrP 1234 "$T/mid_e.zip" .)
mkdir "$T/o3"; cp "$T/mid_e.zip" "$T/o3/"
(cd "$T/o3" && zip -qrP 1234 "$T/enc_outer2.zip" .)
run_check "加密嵌套同密码一次解完" 0 "$T" -p 1234 enc_outer.zip enc_outer2.zip
check "加密嵌套内容可达" "[ -f \"$T/enc_outer2/mid_e/inner_e/docs/deep.txt\" ]"
# 内层不同密码 → 报错并保留内层包
mkdir "$T/only"; echo secretdata > "$T/only/s.txt"
(cd "$T/only" && zip -qrP 9999 "$T/diff_inner.zip" .)
mkdir "$T/o4"; cp "$T/diff_inner.zip" "$T/o4/"
(cd "$T/o4" && zip -qrP 1234 "$T/diff_outer.zip" .)
run_check "内层密码不同时顶层部分成功" 0 "$T" -p 1234 diff_outer.zip
grep -q "diff_inner.zip：密码错误" "$T/last.out" && ok "警告中指出内层包" || bad "警告中指出内层包"
check "失败内层包被保留" "[ -f \"$T/diff_outer/diff_inner.zip\" ]"

say "== 6. 路径穿越（zip-slip）防护 =="
python3 - "$T/evil.zip" <<'PYEOF' 2>/dev/null || echo "PYFAIL"
import zipfile, sys
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("../evil_escaped.txt", "x")
PYEOF
if [ -f "$T/evil.zip" ]; then
    (cd "$T" && "$APP" evil.zip >"$T/last.out" 2>&1)
    check "恶意 zip 不允许逃逸到上级目录" "[ ! -f \"$T/evil_escaped.txt\" ]"
else
    say "  ⚠️ 无 python3，跳过 zip-slip 用例"
fi

say "== 7. 日志检查 =="
check "日志文件存在" "[ -f \"$HOME/Library/Logs/BatchUnzip.log\" ]"
check "日志不含密码明文" "! grep -q 'wrongpw\|secret\b\|9999' \"$HOME/Library/Logs/BatchUnzip.log\""

say "== 8. 并行批量 =="
for i in 1 2 3 4 5 6; do
    mkdir -p "$T/par$i"; echo "content-$i" > "$T/par$i/file.txt"
    ditto -c -k "$T/par$i" "$T/par$i.zip"
done
run_check "6 包并行解压全部成功" 0 "$T" par1.zip par2.zip par3.zip par4.zip par5.zip par6.zip
allok=1
for i in 1 2 3 4 5 6; do
    [ "$(cat "$T/par$i/file.txt")" = "content-$i" ] || allok=0
done
check "并行结果内容逐个正确" "[ $allok = 1 ]"
# 同名压缩包在不同目录并行解压，输出目录不能串
mkdir -p "$T/d1" "$T/d2"; cp "$T/plain.zip" "$T/d1/a.zip"; cp "$T/plain.zip" "$T/d2/a.zip"
run_check "不同目录同名包" 0 "$T" d1/a.zip d2/a.zip
check "各自解到各自目录" "[ -f \"$T/d1/a/a.txt\" ] && [ -f \"$T/d2/a/a.txt\" ]"

say "== 9. GBK 编码中文文件名 zip（unar 解码）==="
python3 - "$T/gbk_test.zip" <<'PYEOF' 2>/dev/null || echo "PYFAIL"
# 手工构造一个文件名为 GBK 字节、无 UTF-8 标志位的 zip（国内老压缩工具的典型产物）
import struct, sys, binascii
name = "中文测试文件.txt".encode("gbk")
data = "gbk 内容测试".encode("utf-8")
size = len(data)
crc = binascii.crc32(data) & 0xffffffff
local = b"PK\x03\x04" + struct.pack("<HHHHHIIIHH", 20, 0, 0, 0, 0, crc, size, size, len(name), 0) + name + data
central = b"PK\x01\x02" + struct.pack("<HHHHHHIIIHHHHHII", 20, 20, 0, 0, 0, 0, crc, size, size, len(name), 0, 0, 0, 0, 0, 0) + name
eocd = b"PK\x05\x06" + struct.pack("<HHHHIIH", 0, 0, 1, 1, len(central), len(local), 0)
open(sys.argv[1], "wb").write(local + central + eocd)
PYEOF
if [ -f "$T/gbk_test.zip" ]; then
    run_check "GBK zip 解压" 0 "$T" gbk_test.zip
    check "中文文件名正确恢复" "[ -f \"$T/gbk_test/中文测试文件.txt\" ]"
    check "文件内容正确" "[ \"\$(cat \"$T/gbk_test/中文测试文件.txt\")\" = \"gbk 内容测试\" ]"
else
    say "  ⚠️ 无 python3，跳过 GBK 用例"
fi

say "== 10. CLI SIGTERM 不留孤儿解压进程 =="
# 生成大文件拉长解压窗口，杀掉 app 后子进程应一并退出
dd if=/dev/urandom bs=1048576 count=400 2>/dev/null | base64 | gzip -6 > "$T/orphan.gz"
"$APP" "$T/orphan.gz" >/dev/null 2>&1 &
APP_PID=$!
sleep 1
CHILDREN="$(pgrep -P $APP_PID | tr '\n' ' ')"
kill -TERM $APP_PID 2>/dev/null
sleep 1
alive=0
for cpid in $CHILDREN; do kill -0 $cpid 2>/dev/null && alive=$((alive+1)); done
if [ -n "$CHILDREN" ]; then
    check "SIGTERM 后解压子进程已终止" "[ $alive = 0 ]"
else
    say "  ⚠️ 采样窗口没抓到子进程，跳过（打包机过快）"
fi
wait $APP_PID 2>/dev/null

say "== 11. 细粒度进度与极端输入 =="
# 7zz 大文件应输出「· N%」进度
dd if=/dev/urandom bs=1048576 count=120 2>/dev/null | base64 | gzip -6 > "$T/prog.gz"
run_check "大 gz 解压成功" 0 "$T" prog.gz
grep -q "· [0-9]\+%" "$T/last.out" && ok "输出含百分比进度" || bad "输出含百分比进度"
rm -rf "$T/prog"
# 损坏包 2000 条 CRC 错误（stderr 超 64KB）不得挂起
python3 - "$T/badcrc.zip" <<'PYEOF' 2>/dev/null || echo "PYFAIL"
import struct, sys
out = b""; central = b""; offset = 0
for i in range(2000):
    nm = ("file%04d.txt" % i).encode()
    d = b"x" * 40
    local = b"PK\x03\x04" + struct.pack("<HHHHHIIIHH", 20, 0, 0, 0, 0, 0xDEADBEEF, len(d), len(d), len(nm), 0) + nm + d
    central += b"PK\x01\x02" + struct.pack("<HHHHHHIIIHHHHHII", 20, 20, 0, 0, 0, 0, 0xDEADBEEF, len(d), len(d), len(nm), 0, 0, 0, 0, 0, offset) + nm
    offset += len(local); out += local
eocd = b"PK\x05\x06" + struct.pack("<HHHHIIH", 0, 0, 2000, 2000, len(central), offset, 0)
open(sys.argv[1], "wb").write(out + central + eocd)
PYEOF
if [ -f "$T/badcrc.zip" ]; then
    "$APP" "$T/badcrc.zip" >/dev/null 2>&1 &
    BPID=$!
    hung=0
    for i in $(seq 1 60); do
        sleep 0.5
        kill -0 $BPID 2>/dev/null || break
        [ $i = 60 ] && hung=1
    done
    if [ $hung = 1 ]; then bad "大体积 stderr 未挂起"; kill -9 $BPID 2>/dev/null; else ok "大体积 stderr 未挂起"; fi
    wait $BPID 2>/dev/null
else
    say "  ⚠️ 无 python3，跳过损坏包用例"
fi
# 同目录同名不同格式并行解压 → 输出目录必须错开且内容不串
mkdir -p "$T/collide"
(cd "$T/collide" && echo m1 > m1.txt && zip -q a.zip m1.txt && rm m1.txt \
    && echo m2 > m2.txt && "$SEVENZZ" a -t7z a.7z m2.txt >/dev/null && rm m2.txt)
run_check "同目录同名 a.zip + a.7z 并行" 0 "$T" collide/a.zip collide/a.7z
check "两个输出目录内容不串" "[ -n \"$(find "$T/collide/a" "$T/collide/a 2" -name m1.txt 2>/dev/null)\" ] && [ -n \"$(find "$T/collide/a" "$T/collide/a 2" -name m2.txt 2>/dev/null)\" ]"

say "== 12. 镜像与新容器格式 =="
mkdir -p "$T/dmgsrc" && echo dmg内容 > "$T/dmgsrc/d.txt"
hdiutil create -srcfolder "$T/dmgsrc" -volname T1 -format UDZO -ov "$T/mirror.dmg" >/dev/null 2>&1
run_check "普通 DMG 解压" 0 "$T" mirror.dmg
check "DMG 内容正确" "[ \"\$(cat \"$T/mirror/d.txt\")\" = dmg内容 ]"
printf 'dmgpass' | hdiutil create -srcfolder "$T/dmgsrc" -volname T2 -format UDZO -encryption AES-256 -stdinpass -ov "$T/enc.dmg" >/dev/null 2>&1
if [ -f "$T/enc.dmg" ]; then
    run_check "加密 DMG + 正确密码" 0 "$T" -p dmgpass enc.dmg
    check "加密 DMG 内容正确" "[ \"\$(cat \"$T/enc/d.txt\")\" = dmg内容 ]"
    run_check "加密 DMG 无密码报错" 1 "$T" enc.dmg
    expect_fail_msg "提示可能加密" "可能已加密"
else
    say "  ⚠️ 加密 DMG 创建失败，跳过"
fi
mkdir -p "$T/wimsrc" && echo w内容 > "$T/wimsrc/w.txt"
"$SEVENZZ" a -twim "$T/vol.wim" "$T/wimsrc" >/dev/null 2>&1 && [ -f "$T/vol.wim" ] && run_check "WIM 解压（内置 7zz）" 0 "$T" vol.wim && check "WIM 内容正确" "[ \"\$(cat \"$T/vol/wimsrc/w.txt\")\" = w内容 ]"
mkdir -p "$T/isosrc" && echo i内容 > "$T/isosrc/i.txt"
hdiutil makehybrid -iso -joliet -o "$T/disc.iso" "$T/isosrc" >/dev/null 2>&1 && [ -f "$T/disc.iso" ] && run_check "ISO 解压（内置 7zz）" 0 "$T" disc.iso && check "ISO 内容正确" "[ \"\$(cat \"$T/disc/i.txt\")\" = i内容 ]"
mkdir -p "$T/jarsrc" && echo j内容 > "$T/jarsrc/j.txt"
(cd "$T/jarsrc" && zip -q app.zip j.txt) && cp "$T/jarsrc/app.zip" "$T/app.ipa" && cp "$T/jarsrc/app.zip" "$T/prog.jar"
run_check "ipa/jar（zip 容器）" 0 "$T" app.ipa prog.jar
check "ipa/jar 内容正确" "[ \"\$(cat \"$T/app/j.txt\")\" = j内容 ] && [ \"\$(cat \"$T/prog/j.txt\")\" = j内容 ]"

say ""
say "========== 结果: 通过 $PASS / $((PASS+FAIL)) =========="
rm -rf "$T"
[ "$FAIL" = 0 ] && exit 0 || exit 1
