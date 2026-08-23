#!/bin/bash
# 构造一个最小但合法的 EPUB（EPUB2 + NCX，中文多作者/多章节），供 epub.lua 测试。
# 运行：bash make_epub.sh  →  生成 /tmp/test.epub
set -e
W=/tmp/epubwork
rm -rf "$W"; mkdir -p "$W/OEBPS/text" "$W/META-INF"

cat > "$W/META-INF/container.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
EOF

cat > "$W/OEBPS/content.opf" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="isbn">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>EPUB 测试书</dc:title>
    <dc:creator>张三</dc:creator>
    <dc:creator>李四</dc:creator>
    <dc:language>zh-CN</dc:language>
    <dc:identifier id="isbn">978-7-111-40701-0</dc:identifier>
    <dc:publisher>测试出版社</dc:publisher>
    <dc:date>2026-08-23</dc:date>
    <dc:source>urn:uuid:1234</dc:source>
    <meta name="cover-id" content="cover"/>
  </metadata>
  <manifest>
    <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover" href="text/cover.svg" media-type="image/svg+xml"/>
    <item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="toc">
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>
EOF

cat > "$W/OEBPS/toc.ncx" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:1234"/></head>
  <navMap>
    <navPoint id="np1" playOrder="1">
      <navLabel><text>第一章 你好</text></navLabel>
      <content src="text/ch1.xhtml"/>
    </navPoint>
    <navPoint id="np2" playOrder="2">
      <navLabel><text>第二章 再见</text></navLabel>
      <content src="text/ch2.xhtml"/>
    </navPoint>
  </navMap>
</ncx>
EOF

cat > "$W/OEBPS/text/ch1.xhtml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head>
<body><h1>第一章 你好</h1><p>这是第一段。</p><p>这是第二段。</p></body></html>
EOF

cat > "$W/OEBPS/text/ch2.xhtml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第二章</title></head>
<body><h1>第二章 再见</h1><p>结尾段落。</p></body></html>
EOF

cat > "$W/OEBPS/text/cover.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100" fill="red"/></svg>
EOF

cd "$W"
printf 'application/epub+zip' > mimetype   # 规范首条目，无换行
rm -f /tmp/test.epub
zip -X -0 /tmp/test.epub mimetype          # stored（EPUB 规范）
zip -rX -9 /tmp/test.epub META-INF OEBPS
echo "EPUB built: $(wc -c < /tmp/test.epub) bytes → /tmp/test.epub"
