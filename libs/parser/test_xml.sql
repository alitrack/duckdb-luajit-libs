-- xml.lua 回归测试套件（duckdb-luajit）
-- 运行：duckdb -unsigned < test_xml.sql
-- load 输出以根元素名为键（xml2js 风格）：属性 → @名，重复子标签 → 数组，叶子文本 → 字符串。
LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';

SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'xml',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/parser/xml.lua'')');

-- 1. 重复子标签 → 数组
SELECT luajit_s('xml', {v: '<a><b>1</b><b>2</b></a>', op: 'load'}) AS t1;  -- {"a":{"b":["1","2"]}}

-- 2. json_extract 穿透（含属性 @id 与文本）
SELECT json_extract(luajit_s('xml', {v: '<root><item id="1"><name>x</name></item><item id="2"><name>y</name></item></root>', op: 'load'}), '$.root.item[1].name') AS t2;  -- y

-- 3. 属性 → @
SELECT luajit_s('xml', {v: '<book id="b1" lang="en"><title>T</title></book>', op: 'load'}) AS t3;  -- {"book":{"@id":"b1","@lang":"en","title":"T"}}

-- 4. find //descendant
SELECT luajit_s('xml', {v: '<shelf><book id="1"><title>A</title></book><book id="2"><title>B</title></book></shelf>', op: 'find', path: '//book/title'}) AS t4;  -- ["A","B"]

-- 5. attr
SELECT luajit_s('xml', {v: '<root><book id="b7"><title>T</title></book></root>', op: 'attr', path: '//book', name: 'id'}) AS t5;  -- b7

-- 6. text 去标签（保序）
SELECT luajit_s('xml', {v: '<p>hi <b>bold</b> ok</p>', op: 'text'}) AS t6;  -- "hi bold ok"

-- 7. CDATA
SELECT luajit_s('xml', {v: '<x><![CDATA[<raw> & ]]></x>', op: 'load'}) AS t7;  -- {"x":"<raw> &"}

-- 8. 实体解码
SELECT luajit_s('xml', {v: '<m>5 &lt; 10 &amp; 3</m>', op: 'text'}) AS t8;  -- "5 < 10 & 3"

-- 9. 注释 + 声明
SELECT luajit_s('xml', {v: '<?xml version="1.0"?><a><!-- c --><b>1</b></a>', op: 'load'}) AS t9;  -- {"a":{"b":"1"}}

-- 10. 深嵌套 + 属性 + 文本
SELECT luajit_s('xml', {v: '<r><mid><deep id="z">7</deep></mid></r>', op: 'load'}) AS t10;  -- {"r":{"mid":{"deep":{"@id":"z","#text":"7"}}}}
