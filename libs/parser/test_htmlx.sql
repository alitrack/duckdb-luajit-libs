-- htmlx.lua 回归（duckdb-luajit）
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'hx',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/htmlx.lua'')');

-- 1. title（折叠空白）
SELECT json_extract(hx({file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_page.html', op:'title'}), '$') AS t1;  -- "My Test Page"

-- 2. links：数量 + 具体 href/text（跳过无 href 的 a；注释里的 a 不算）
SELECT json_extract(hx({file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_page.html', op:'links'}), '$[0].href') AS l0h,  -- https://example.com/a
       json_extract(hx({file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_page.html', op:'links'}), '$[0].text') AS l0t,  -- Link One
       json_extract(hx({file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_page.html', op:'links'}), '$[1].text') AS l1t,  -- Link Two
       json_extract(hx({file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_page.html', op:'links'}), '$[2].href') AS l2h,  -- https://example.com/c
       json_extract(hx({file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_page.html', op:'links'}), '$[2].text') AS l2t,  -- Multi line link text
       (json_array_length(hx({file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_page.html', op:'links'})))         AS ln;    -- 3

-- 3. tables：单元格矩阵（含 <th>）
SELECT json_extract(hx({file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_page.html', op:'tables'}), '$[0].rows[0][0]') AS c00,  -- Col A
       json_extract(hx({file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_page.html', op:'tables'}), '$[0].rows[0][1]') AS c01,  -- Col B
       json_extract(hx({file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_page.html', op:'tables'}), '$[0].rows[1][1]') AS c11,  -- two words
       json_array_length(json_extract(hx({file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_page.html', op:'tables'}), '$[0].rows')) AS rws;  -- 3

-- 4. text：剔除 head/script/style/注释
SELECT hx({file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_page.html', op:'text'}) AS txt4;  -- 含 Heading/Some visible text，不含 skip me/color:red/not a link

-- 5. 行内小样例（无 title → null；无 href 跳过；大小写/未闭合容错）
SELECT hx({v:'<div><A HREF="x.com">Up</a><P>Hi there</p>', op:'links'})  AS l5,  -- [{"href":"x.com","text":"Up"}]
       hx({v:'<P>no title here', op:'title'})                            AS t5,  -- null
       hx({v:'<table><tr><td>a</td><td>b</td></tr></table>', op:'tables'}) AS tb5;  -- [{"rows":[["a","b"]]}]

-- 6. feed 一次全取
SELECT json_extract(hx({file:'/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/fixture_page.html', op:'feed'}), '$.title') AS f1;  -- "My Test Page"

-- 7. 错误处理
SELECT hx({v:'', op:'feed'})  AS e1,   -- error: missing v or file
       hx({op:'feed'})          AS e2;   -- error: missing v or file
