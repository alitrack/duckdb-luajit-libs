#!/usr/bin/env bash
# make_poc.sh — generate PoC-inv-ofd-output.txt (statcpp-style, one command reproducible).
# Produces: header (timestamp, duckdb version, exact commands) + raw duckdb -f output.
set -e
cd "$(dirname "$0")"   # libs/datasource
OUT="$(cd ../.. && pwd)/PoC-inv-ofd-output.txt"

# Step 1: build the desensitized fixture + run 13 assertions (side effect: /tmp/inv_ofd_probe.ofd)
rm -f /tmp/inv_ofd_probe.ofd
~/.local/bin/duckdb -unsigned -f test_inv_ofd.sql > /tmp/poc_ofd_a.txt 2>&1
[ -f /tmp/inv_ofd_probe.ofd ] || { echo "FATAL: fixture not generated"; exit 1; }

# Step 2: clear remote-install cache, run the one-SQL install + parse
rm -f ~/.duckdb/luajit-libs/INDEX ~/.duckdb/luajit-libs/inv_ofd.lua
~/.local/bin/duckdb -unsigned -f test_inv_ofd_install.sql > /tmp/poc_ofd_b.txt 2>&1

VER="$(~/.local/bin/duckdb --version)"
TS="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

{
  echo "# PoC: inv_ofd — 数电发票 OFD 解析（duckdb-luajit libs）"
  echo "# 生成时间: $TS"
  echo "# duckdb: $VER"
  echo "# 运行环境: WSL (linux x86-64), 扩展为本地构建 ELF (build/release/luajit.duckdb_extension)"
  echo "#"
  echo "# 复现（一条命令）:"
  echo "#   bash libs/datasource/make_poc.sh"
  echo "# 或手动:"
  echo "#   1) duckdb -unsigned -f libs/datasource/test_inv_ofd.sql        # 生成脱敏 fixture + 13 断言"
  echo "#   2) rm -f ~/.duckdb/luajit-libs/{INDEX,inv_ofd.lua}"
  echo "#      duckdb -unsigned -f libs/datasource/test_inv_ofd_install.sql  # 远程 install + 解析"
  echo "#"
  echo "# 能力: OFD(zip 容器) → FFI 内嵌 zlib raw-inflate → 元数据 JSON(发票号/金额/税号/日期)"
  echo "#       + 版面文本行(Content.xml TextObject 按 y 坐标聚类还原行, 行内按 x 排序)。零编译, 一条 SQL 安装。"
  echo "#"
  echo "========== PART A: 13 条断言（脱敏 fixture, quick_compile 同会话） =========="
  cat /tmp/poc_ofd_a.txt
  echo
  echo "========== PART B: 远程 install + 解析（清缓存强制走网络） =========="
  cat /tmp/poc_ofd_b.txt
  echo
} > "$OUT"

echo "wrote $OUT ($(wc -l < "$OUT") lines)"
