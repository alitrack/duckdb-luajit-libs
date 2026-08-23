-- markdown.lua 回归测试套件（duckdb-luajit）
-- 运行：duckdb -unsigned < test_markdown.sql
-- 注意：md 文本用真实换行（多行 SQL 字符串）；struct 用 `key:`。
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'markdown',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/markdown.lua'')');

-- 复用同一段文档（多行字符串）
CREATE OR REPLACE TEMP VIEW doc AS
SELECT '
# 标题一
## 小节
正文含**加粗**与`code`，以及[链接](https://ex.com/a)。
- 列表甲
- 列表乙
  - 嵌套
1. 有序一
2. 有序二
> 这是引用
```python
def f():
    return [1,2,3]  # 不应被当作标题/链接
```
' AS md;

-- 1. toc：2 个标题，level 1/2
SELECT json_extract(luajit_s('markdown', {v: md, op: 'toc'}), '$[0].level') AS l0,
       json_extract(luajit_s('markdown', {v: md, op: 'toc'}), '$[0].text')  AS t0,
       json_extract(luajit_s('markdown', {v: md, op: 'toc'}), '$[1].text')  AS t1
FROM doc;   -- 1 | 标题一 | 小节

-- 2. links：抽到 https://ex.com/a
SELECT json_extract(luajit_s('markdown', {v: md, op: 'links'}), '$[0].href') AS href,
       json_extract(luajit_s('markdown', {v: md, op: 'links'}), '$[0].text') AS text
FROM doc;   -- https://ex.com/a | 链接

-- 3. code：1 个 python 代码块，内含 def f
SELECT json_extract(luajit_s('markdown', {v: md, op: 'code'}), '$[0].lang') AS lang,
       json_extract(luajit_s('markdown', {v: md, op: 'code'}), '$[0].text') AS txt
FROM doc;   -- python | def f():\n    return [1,2,3]  # 不应被当作标题/链接

-- 4. lists：5 项（甲/乙/嵌套 无序 + 有序一/二）
SELECT json_array_length(luajit_s('markdown', {v: md, op: 'lists'})) AS n_lists,
       json_extract(luajit_s('markdown', {v: md, op: 'lists'}), '$[0].text') AS first,
       json_extract(luajit_s('markdown', {v: md, op: 'lists'}), '$[3].text') AS ordered_first
FROM doc;   -- 5 | 列表甲 | 有序一

-- 5. quotes：1 条
SELECT json_extract(luajit_s('markdown', {v: md, op: 'quotes'}), '$[0].text') AS q
FROM doc;   -- 这是引用

-- 6. stats：headings=2 links=1 code=1 lists=5 quotes=1
SELECT json_extract(luajit_s('markdown', {v: md, op: 'stats'}), '$.headings') AS h,
       json_extract(luajit_s('markdown', {v: md, op: 'stats'}), '$.links')    AS lk,
       json_extract(luajit_s('markdown', {v: md, op: 'stats'}), '$.code')     AS cd,
       json_extract(luajit_s('markdown', {v: md, op: 'stats'}), '$.lists')    AS ls,
       json_extract(luajit_s('markdown', {v: md, op: 'stats'}), '$.quotes')   AS qt
FROM doc;   -- 2 | 1 | 1 | 5 | 1

-- 7. plain：含 标题一/列表甲/这是引用，不含 #/**/``
SELECT
  luajit_s('markdown', {v: md, op: 'plain'}) LIKE '%标题一%'     AS has_h,
  luajit_s('markdown', {v: md, op: 'plain'}) LIKE '%列表甲%'     AS has_list,
  luajit_s('markdown', {v: md, op: 'plain'}) LIKE '%这是引用%'   AS has_quote,
  luajit_s('markdown', {v: md, op: 'plain'}) NOT LIKE '%**%'     AS no_boldmark,
  luajit_s('markdown', {v: md, op: 'plain'}) NOT LIKE '%```%'    AS no_fence
FROM doc;   -- true true true true true
