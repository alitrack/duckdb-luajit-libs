-- epub.lua 回归测试套件（duckdb-luajit）
-- 运行前：bash libs/parser/make_epub.sh 生成 /tmp/test.epub
-- 运行：duckdb -unsigned < test_epub.sql
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'epub',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/epub.lua'')');

-- 1. metadata：title / creators / language / identifier
SELECT json_extract(r, '$.title')           AS title,
       json_extract(r, '$.language')        AS lang,
       json_extract(r, '$.identifier')      AS id,
       json_array_length(json_extract(r, '$.creators')) AS n_creators
FROM (SELECT luajit_s('epub', {file: '/tmp/test.epub', op: 'metadata'}) AS r);
-- "EPUB 测试书" | zh-CN | 978-7-111-40701-0 | 2

-- 2. metadata：两个 creator 值
SELECT json_extract(r, '$.creators[0]') AS c0,
       json_extract(r, '$.creators[1]') AS c1,
       json_extract(r, '$.publisher')   AS pub,
       json_extract(r, '$.date')        AS date
FROM (SELECT luajit_s('epub', {file: '/tmp/test.epub', op: 'metadata'}) AS r);
-- "张三" | "李四" | "测试出版社" | 2026-08-23

-- 3. toc：2 个 navPoint（EPUB2 NCX）
SELECT json_array_length(r)              AS n,
       json_extract(r, '$[0].label')     AS l0,
       json_extract(r, '$[0].href')      AS h0,
       json_extract(r, '$[1].label')     AS l1,
       json_extract(r, '$[1].play_order') AS po1
FROM (SELECT luajit_s('epub', {file: '/tmp/test.epub', op: 'toc'}) AS r);
-- 2 | "第一章 你好" | text/ch1.xhtml | "第二章 再见" | 2

-- 4. text：抽 ch1 纯文本（去标签）
SELECT luajit_s('epub', {file: '/tmp/test.epub', op: 'text', href: 'text/ch1.xhtml'}) AS ch1
FROM (SELECT 1);
-- 含 "第一章 你好" 与 "这是第一段" 与 "这是第二段"

-- 5. info：OPF 路径 + 版本 + spine 文档数
SELECT json_extract(r, '$.opf_path')  AS opf,
       json_extract(r, '$.version')   AS ver,
       json_extract(r, '$.doc_count') AS docs
FROM (SELECT luajit_s('epub', {file: '/tmp/test.epub', op: 'info'}) AS r);
-- OEBPS/content.opf | 2.0 | 2

-- 6. 错误处理：不存在的文件 → error
SELECT luajit_s('epub', {file: '/tmp/nope.epub', op: 'metadata'}) LIKE '%error%' AS is_err
FROM (SELECT 1);
-- true
