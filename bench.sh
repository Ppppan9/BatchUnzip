#!/bin/bash
# 性能基准：测量批量解压在典型场景下的墙钟耗时
# 用法: APP=<可执行文件路径> ./bench.sh
set -u
APP="${APP:-/Applications/批量解压.app/Contents/MacOS/BatchUnzip}"
SEVENZZ="${SEVENZZ:-/opt/homebrew/bin/7zz}"
T=$(mktemp -d /tmp/bzbench.XXXXXX)
PY=python3

now() { $PY -c 'import time; print(time.time())'; }
elapsed() { $PY -c "print(f'{$2-$1:.2f}')"; }
run() { "$APP" "$@" >/dev/null 2>&1; }

echo "== 生成测试数据 =="
mkdir -p "$T/small_src"; echo small > "$T/small_src/s.txt"
for i in $(seq 1 30); do ditto -c -k "$T/small_src" "$T/s$i.zip"; done
# 混合场景：20 个 2MB 小包 + 1 个 800MB 大包（小包在前 = FIFO 调度的最差情况）
for i in $(seq 1 20); do
    dd if=/dev/urandom bs=1048576 count=2 2>/dev/null > "$T/m$i.bin"
    (cd "$T" && "$SEVENZZ" a -tzip -mx=0 "m$i.zip" "m$i.bin" >/dev/null)
    rm "$T/m$i.bin"
done
dd if=/dev/urandom bs=1048576 count=800 2>/dev/null > "$T/mbig.bin"
(cd "$T" && "$SEVENZZ" a -tzip -mx=0 "m99big.zip" "mbig.bin" >/dev/null)
rm "$T/mbig.bin"
for i in 1 2 3 4 5 6 7 8; do
    dd if=/dev/urandom bs=1048576 count=40 2>/dev/null > "$T/L$i.bin"
    (cd "$T" && "$SEVENZZ" a -tzip -mx=0 "L$i.zip" "L$i.bin" >/dev/null)
    rm "$T/L$i.bin"
done
du -sh "$T" | awk '{print "测试数据: " $1}'

echo ""
echo "== 场景 S：30 个小包（进程调度开销敏感）=="
t0=$(now); run "$T"/s*.zip; t1=$(now); echo "耗时 $(elapsed $t0 $t1) 秒"

echo "== 场景 M：20 个 2MB + 1 个 800MB（长作业调度敏感，小包在前）=="
t0=$(now); run "$T"/m*.zip; t1=$(now); echo "耗时 $(elapsed $t0 $t1) 秒"

echo "== 场景 L：8 × 40MB 同等大小（纯并行度）=="
t0=$(now); run "$T"/L*.zip; t1=$(now); echo "耗时 $(elapsed $t0 $t1) 秒"

rm -rf "$T"
echo "完成"
