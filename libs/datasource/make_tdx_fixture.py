#!/usr/bin/env python3
"""生成 tdx 测试 fixture：真实 32 字节/记录小端 .day / .lc5 文件。
输出：libs/datasource/fixture_sh000001.day（3 交易日）+ fixture_sz000002.lc5（3 分钟线）
记录格式（小端）：
  .day : date u32(YYYYMMDD) | open u32(*100) | high u32 | low u32 | close u32 | amount f32 | volume u32 | unused u32
  .lc5 : date u16((y-2004)*2048+m*100+d) | time u16(min) | open f32 | high f32 | low f32 | close f32 | amount f32 | volume u32 | unused u32
"""
import struct, os
OUT = os.path.dirname(os.path.abspath(__file__))

# .day: 3 records. close stored *100 → /100 = 10.0 / 12.5 / 11.0 (MAX=12.5)
day = []
for date, o, h, l, c, amt, vol in [
    (20260819, 980, 1050, 950, 1000, 1234567.0, 987654),   # close 1000→10.0
    (20260820, 1050, 1300, 1000, 1250, 2345678.0, 1111111),  # close 1250→12.5 = MAX
    (20260821, 1250, 1350, 1100, 1100, 3456789.0, 2222222),  # close 1100→11.0
]:
    day.append(struct.pack("<IIIIIfII", date, o, h, l, c, amt, vol, 0))
open(os.path.join(OUT, "fixture_sh000001.day"), "wb").write(b"".join(day))

# .lc5: 3 minute records (close f32 directly, no *100). closes 10.5 / 11.0 / 10.8
def lc_ts(y, m, d, hh, mm):
    return (y - 2004) * 2048 + m * 100 + d, hh * 60 + mm
lc = []
for (y, m, d, hh, mm), o, h, l, c, amt, vol in [
    ((2026, 8, 21, 9, 35), 10.0, 10.6, 9.9, 10.5, 111.0, 1000),
    ((2026, 8, 21, 9, 40), 10.5, 11.1, 10.4, 11.0, 222.0, 2000),
    ((2026, 8, 21, 9, 45), 11.0, 11.0, 10.7, 10.8, 333.0, 3000),
]:
    dt, tm = lc_ts(y, m, d, hh, mm)
    lc.append(struct.pack("<HHfffffII", dt, tm, o, h, l, c, amt, vol, 0))
open(os.path.join(OUT, "fixture_sz000002.lc5"), "wb").write(b"".join(lc))

print("wrote fixture_sh000001.day", len(b"".join(day)), "bytes,", len(day), "recs")
print("wrote fixture_sz000002.lc5", len(b"".join(lc)), "bytes,", len(lc), "recs")

# 错误用例 fixture：
# 1) 坏大小：16 字节（非 32 倍数）.day
open(os.path.join(OUT, "fixture_bad16.day"), "wb").write(b"\x00" * 16)
# 2) 错误扩展名：合法 .day 字节存成 .bin（能打开但扩展名不是 .lc1/.lc5/.day）
open(os.path.join(OUT, "fixture_sh000001.bin"), "wb").write(b"".join(day))
print("wrote fixture_bad16.day 16 bytes; fixture_sh000001.bin 96 bytes")
