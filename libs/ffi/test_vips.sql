-- test_vips.sql: DuckDB E2E（全部断言「应为 0」）
-- 跑法：cp libs/ffi/vips.lua ~/.duckdb/luajit-libs/ && \
--       LD_LIBRARY_PATH=<libvips dir> duckdb -unsigned < libs/ffi/test_vips.sql
--
-- 测试数据：4x3 RGB PNG（含 eXIf）的 BLOB 字面量 —— 由 `vips black` + `vips pngsave`
-- 合成，脱敏、无真实图像、不进 git 的二进制文件。
--
-- 断言策略：不用魔数比对（依赖 libvips 版本），改用「解码回去看属性」——
-- 输出的 BLOB 再喂给 info/sniff，尺寸与 loader 对上才算真·可解码的图像。
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'install', sql_name := 'vips');

CREATE OR REPLACE TEMP TABLE vimg AS
SELECT from_hex('89504e470d0a1a0a0000000d49484452000000040000000308020000003b963991000000b46558496649492a000800000006001201030001000000010000001a01050001000000560000001b010500010000005e0000002801030001000000020000001302030001000000010000006987040001000000660000000000000038630000e803000038630000e8030000060000900700040000003032313001910700040000000102030000a00700040000003031303001a0030001000000ffff000002a00400010000000400000003a0040001000000030000000000000040ee9d4e0000000970485973000003e8000003e801b57b526b0000000c4944415408996360200a0000002700019f5a3c1c0000000049454e44ae426082') AS data;

-- A0: 装载成功（BLOB 长度 282）
SELECT CASE WHEN octet_length(data) = 282 THEN 0 ELSE 1 END AS a0_fixture_must_be_0 FROM vimg;

-- A1: probe（字符串形态，无数据 op）
SELECT CASE WHEN luajit_s('vips', '{"op":"probe"}') LIKE '%"ok":true%' THEN 0 ELSE 1 END
    AS a1_probe_must_be_0;

-- A2: ★ BLOB 经 struct 字面量进 Lua（v0.32.6 前该键被静默丢弃 → 这里只是 error 串）
WITH x AS (SELECT luajit_s('vips', {'op': 'info', 'data': data}) AS j FROM vimg)
SELECT CASE WHEN j LIKE 'error:%' THEN 1
            WHEN json_extract_string(j, '$.width') = '4'
             AND json_extract_string(j, '$.height') = '3'
             AND json_extract_string(j, '$.bands') = '3'
             AND json_extract_string(j, '$.format') = 'uchar'
             AND json_extract_string(j, '$.bytes_in') = '282'
            THEN 0 ELSE 2 END AS a2_blob_in_struct_must_be_0
FROM x;

-- A3: sniff —— 识别为 PNG buffer loader
WITH x AS (SELECT luajit_s('vips', {'op': 'sniff', 'data': data}) AS j FROM vimg)
SELECT CASE WHEN json_extract_string(j, '$.loader') = 'VipsForeignLoadPngBuffer' THEN 0 ELSE 1 END
    AS a3_sniff_must_be_0 FROM x;

-- A4: thumb → BLOB（luajit_blob），产物再解码回来尺寸应为 64x48（4:3）
WITH x AS (
    SELECT luajit_blob('vips', {'op': 'thumb', 'data': data, 'width': 64,
                                'suffix': '.webp[Q=75]'}) AS b FROM vimg),
     y AS (SELECT luajit_s('vips', {'op': 'sniff', 'data': b}) AS sn,
                  luajit_s('vips', {'op': 'info', 'data': b}) AS j FROM x)
SELECT CASE WHEN json_extract_string(sn, '$.loader') LIKE '%Webp%'
             AND json_extract_string(j, '$.width') = '64'
             AND json_extract_string(j, '$.height') = '48'
            THEN 0 ELSE 1 END AS a4_thumb_webp_must_be_0
FROM y;

-- A5: thumb → JPEG
WITH x AS (
    SELECT luajit_blob('vips', {'op': 'thumb', 'data': data, 'width': 32,
                                'suffix': '.jpg[Q=80]'}) AS b FROM vimg),
     y AS (SELECT luajit_s('vips', {'op': 'sniff', 'data': b}) AS sn,
                  luajit_s('vips', {'op': 'info', 'data': b}) AS j FROM x)
SELECT CASE WHEN json_extract_string(sn, '$.loader') LIKE '%Jpeg%'
             AND json_extract_string(j, '$.width') = '32'
            THEN 0 ELSE 1 END AS a5_thumb_jpg_must_be_0
FROM y;

-- A6: transcode 保尺寸 → PNG 4x3
WITH x AS (SELECT luajit_blob('vips', {'op': 'transcode', 'data': data,
                                       'suffix': '.png'}) AS b FROM vimg),
     y AS (SELECT luajit_s('vips', {'op': 'info', 'data': b}) AS j FROM x)
SELECT CASE WHEN json_extract_string(j, '$.width') = '4'
             AND json_extract_string(j, '$.height') = '3'
            THEN 0 ELSE 1 END AS a6_transcode_png_must_be_0
FROM y;

-- A7–A10: 错误作为数据返回（不得抛错、不得静默 NULL）
SELECT CASE WHEN luajit_s('vips', {'op': 'info', 'data': ''::BLOB}) LIKE 'error:%'
            THEN 0 ELSE 1 END AS a7_empty_blob_must_be_0;
SELECT CASE WHEN luajit_s('vips', {'op': 'info', 'data': 'junk'::BLOB}) LIKE 'error:%'
            THEN 0 ELSE 1 END AS a8_junk_must_be_0;
SELECT CASE WHEN luajit_s('vips', {'op': 'thumb', 'data': data, 'width': -1}) LIKE 'error:%'
            THEN 0 ELSE 1 END AS a9_bad_width_must_be_0 FROM vimg;
SELECT CASE WHEN luajit_s('vips', {'op': 'nope'}) LIKE 'error:%'
            THEN 0 ELSE 1 END AS a10_unknown_op_must_be_0;

-- A11: 批量化（10 行 × 同一 BLOB）——UDF 被真正调用（列被引用）、无泄漏崩溃
WITH src AS (SELECT data FROM vimg, range(10)),
     x AS (SELECT luajit_blob('vips', {'op': 'thumb', 'data': data, 'width': 16}) AS b FROM src)
SELECT CASE WHEN count(*) = 10 AND min(octet_length(b)) > 0 AND max(octet_length(b)) > 0
            THEN 0 ELSE 1 END AS a11_batch_must_be_0 FROM x;

-- A12: 链式（thumb 输出再喂 info）——BLOB 闭环可组合
WITH t1 AS (SELECT luajit_blob('vips', {'op': 'thumb', 'data': data, 'width': 8,
                                        'suffix': '.png'}) AS b FROM vimg),
     t2 AS (SELECT luajit_s('vips', {'op': 'info', 'data': b}) AS j FROM t1)
SELECT CASE WHEN json_extract_string(j, '$.width') = '8' THEN 0 ELSE 1 END
    AS a12_chain_must_be_0 FROM t2;

-- A13: LIST(BLOB) 进 Lua（LIST 子类型 BLOB 曾同样被丢成 nil）——一次调用多张图
WITH x AS (
    SELECT luajit_blob('vips', {'op': 'thumb', 'data': [data, data], 'width': 8}) AS b
    FROM vimg),
     y AS (SELECT luajit_s('vips', {'op': 'info', 'data': b}) AS j FROM x)
SELECT CASE WHEN json_extract_string(j, '$.width') = '8' THEN 0 ELSE 1 END
    AS a13_list_blob_must_be_0 FROM y;

-- A14: MATERIALIZED CTE + BLOB 进 struct（同样的 BLOB 键在物化作用域里走一遍）
WITH x AS MATERIALIZED (SELECT data FROM vimg),
     y AS MATERIALIZED (SELECT luajit_s('vips', {'op': 'info', 'data': data}) AS j FROM x)
SELECT CASE WHEN j LIKE 'error:%' THEN 1
            WHEN json_extract_string(j, '$.width') = '4' THEN 0 ELSE 2 END
    AS a14_materialized_blob_must_be_0 FROM y;

-- A15: 截断图像（20 字节 = 签名 + 半截 IHDR）走 SQL → 必须是 error 串（不崩、不 NULL）
SELECT CASE WHEN luajit_s('vips', {'op': 'transcode',
                                  'data': from_hex('89504e470d0a1a0a0000000d4948445200000004'),
                                  'suffix': '.png'}) LIKE 'error:%'
            THEN 0 ELSE 1 END AS a15_truncated_must_be_0;