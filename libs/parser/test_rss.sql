-- rss.lua 回归（duckdb-luajit）—— RSS2 / RSS1.0(RDF) / Atom
-- fixture 文件经 file 参数读取（库内 io.open）。
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'rss',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/rss.lua'')');

-- 1. detect（三种 feed 类型）
SELECT luajit_s('rss',{op:'detect', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_rss2.xml'})  AS t2,
       luajit_s('rss',{op:'detect', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_rss10.xml'}) AS t10,
       luajit_s('rss',{op:'detect', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_atom.xml'})  AS ta
FROM (SELECT 1);
-- "rss2" | "rss10" | "atom"

-- 2. RSS2：count + 条目字段（CDATA / 实体 / dc:creator / link）
SELECT luajit_s('rss',{op:'count', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_rss2.xml'})  AS n2,
       json_extract(luajit_s('rss',{op:'items', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_rss2.xml'}), '$[0].title')       AS r2t1,
       json_extract(luajit_s('rss',{op:'items', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_rss2.xml'}), '$[0].description') AS r2d1,
       json_extract(luajit_s('rss',{op:'items', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_rss2.xml'}), '$[0].author')      AS r2a1,
       json_extract(luajit_s('rss',{op:'items', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_rss2.xml'}), '$[1].author')      AS r2a2,
       json_extract(luajit_s('rss',{op:'items', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_rss2.xml'}), '$[0].link')        AS r2l1
FROM (SELECT 1);
-- 2 | "First Post & More" | "Hello <b>world</b> &amp; friends" (CDATA: 原样保留 <b> 与 &amp;) | "alice@example.com (Alice)" | "Bob" | "https://example.com/p1"

-- 3. RSS2 feed 元数据
SELECT json_extract(luajit_s('rss',{op:'feed', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_rss2.xml'}), '$.title')          AS f2t,
       json_extract(luajit_s('rss',{op:'feed', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_rss2.xml'}), '$.link')           AS f2l,
       json_extract(luajit_s('rss',{op:'feed', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_rss2.xml'}), '$.items[1].title') AS f2i2
FROM (SELECT 1);
-- "DuckDB News" | "https://example.com" | "Second Post"

-- 4. Atom：count + link(alternate 优先) + published + author/name
SELECT luajit_s('rss',{op:'count', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_atom.xml'})  AS na,
       json_extract(luajit_s('rss',{op:'items', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_atom.xml'}), '$[0].link')    AS a1l,
       json_extract(luajit_s('rss',{op:'items', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_atom.xml'}), '$[0].pubDate') AS a1d,
       json_extract(luajit_s('rss',{op:'items', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_atom.xml'}), '$[0].author')  AS a1a,
       json_extract(luajit_s('rss',{op:'items', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_atom.xml'}), '$[1].link')    AS a2l,
       json_extract(luajit_s('rss',{op:'items', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_atom.xml'}), '$[1].pubDate') AS a2d
FROM (SELECT 1);
-- 2 | "https://example.com/e1" | "2026-08-22T08:00:00Z" | "Alice A." | "https://example.com/e2" | "2026-08-21T12:00:00Z"

-- 5. Atom feed 元数据（link 取 alternate 而非 self）
SELECT json_extract(luajit_s('rss',{op:'feed', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_atom.xml'}), '$.link')    AS af_l,
       json_extract(luajit_s('rss',{op:'feed', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_atom.xml'}), '$.updated') AS af_u
FROM (SELECT 1);
-- "https://example.com/" | "2026-08-23T10:00:00Z"

-- 6. RSS1.0(RDF)：count + dc:creator / dc:date
SELECT luajit_s('rss',{op:'count', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_rss10.xml'})  AS nr,
       json_extract(luajit_s('rss',{op:'items', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_rss10.xml'}), '$[0].title')  AS r1t,
       json_extract(luajit_s('rss',{op:'items', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_rss10.xml'}), '$[0].author') AS r1a,
       json_extract(luajit_s('rss',{op:'items', file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_rss10.xml'}), '$[1].pubDate') AS r1d2
FROM (SELECT 1);
-- 2 | "Item One" | "Rita" | "2026-08-21T07:00:00Z"

-- 7. 错误处理（非 feed / 空 / 文件不存在）
SELECT luajit_s('rss',{op:'detect', v: '<html><body>hi</body></html>'})            AS unk,
       luajit_s('rss',{op:'feed'})                                                 AS empty,
       luajit_s('rss',{op:'feed', file:'/tmp/no_such_feed_xyz.xml'})                AS nofile
FROM (SELECT 1);
-- "unknown" | (error json) | (error json)
