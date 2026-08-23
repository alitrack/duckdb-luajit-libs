LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'epub',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/epub.lua'')');
SELECT json_extract(r, '$.title') AS title, json_extract(r, '$.language') AS lang,
       json_extract(r, '$.identifier') AS id,
       json_extract(r, '$.creators[0]') AS c0, json_extract(r, '$.creators[1]') AS c1,
       json_extract(r, '$.publisher') AS pub, json_extract(r, '$.date') AS dt
FROM (SELECT luajit_s('epub', {file: '/tmp/fixture.epub', op: 'metadata'}) AS r);
SELECT json_array_length(r) AS n, json_extract(r, '$[0].label') AS l0,
       json_extract(r, '$[1].label') AS l1, json_extract(r, '$[0].href') AS h0
FROM (SELECT luajit_s('epub', {file: '/tmp/fixture.epub', op: 'toc'}) AS r);
SELECT luajit_s('epub', {file: '/tmp/fixture.epub', op: 'text', href: 'text/ch1.xhtml'}) AS ch1
FROM (SELECT 1);
SELECT json_extract(r, '$.opf_path') AS opf, json_extract(r, '$.version') AS ver,
       json_extract(r, '$.doc_count') AS docs
FROM (SELECT luajit_s('epub', {file: '/tmp/fixture.epub', op: 'info'}) AS r);
