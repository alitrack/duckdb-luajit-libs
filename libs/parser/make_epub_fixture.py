#!/usr/bin/env python3
"""验证：Python zipfile 造 EPUB（匿名 fixture），epub.lua 可解析。
- mimetype 必须 stored 且为第一个条目（EPUB 规范）
- zipfile.ZipFile 按写入顺序存条目 → 先写 mimetype 即可
"""
import io, zipfile, struct, sys

def build_epub():
    buf = io.BytesIO()
    z = zipfile.ZipFile(buf, "w")
    z.writestr(zipfile.ZipInfo("mimetype"), b"application/epub+zip",
               compress_type=zipfile.ZIP_STORED)
    files = {
        "META-INF/container.xml": b'<?xml version="1.0" encoding="UTF-8"?>\n<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>\n</container>\n',
        "OEBPS/content.opf": b'''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Anonymous Test EPUB</dc:title>
    <dc:creator>Author One</dc:creator>
    <dc:creator>Author Two</dc:creator>
    <dc:language>en</dc:language>
    <dc:identifier id="id">urn:uuid:00000000-0000-0000-0000-000000000001</dc:identifier>
    <dc:publisher>Test Publisher</dc:publisher>
    <dc:date>2026-01-01</dc:date>
  </metadata>
  <manifest>
    <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="toc" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
  </manifest>
  <spine toc="toc">
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>''',
        "OEBPS/toc.ncx": b'''<?xml version="1.0" encoding="UTF-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head><meta name="dtb:uid" content="urn:uuid:00000000-0000-0000-0000-000000000001"/></head>
  <navMap>
    <navPoint id="np1" playOrder="1"><navLabel><text>Chapter One</text></navLabel><content src="text/ch1.xhtml"/></navPoint>
    <navPoint id="np2" playOrder="2"><navLabel><text>Chapter Two</text></navLabel><content src="text/ch2.xhtml"/></navPoint>
  </navMap>
</ncx>''',
        "OEBPS/text/ch1.xhtml": b'<?xml version="1.0" encoding="UTF-8"?>\n<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Ch1</title></head>\n<body><h1>Chapter One</h1><p>First para.</p><p>Second para.</p></body></html>\n',
        "OEBPS/text/ch2.xhtml": b'<?xml version="1.0" encoding="UTF-8"?>\n<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Ch2</title></head>\n<body><h1>Chapter Two</h1><p>Final para.</p></body></html>\n',
    }
    for name, data in files.items():
        z.writestr(name, data, compress_type=zipfile.ZIP_DEFLATED)
    z.close()
    raw = buf.getvalue()
    assert raw[:4] == b"PK\x03\x04", "not a zip"
    nlen = struct.unpack("<H", raw[26:28])[0]
    elen = struct.unpack("<H", raw[28:30])[0]
    first_name = raw[30:30 + nlen].decode()
    assert first_name == "mimetype", f"first entry is {first_name}"
    method = struct.unpack("<H", raw[8:10])[0]
    assert method == 0, f"mimetype not stored: method={method}"
    print(f"mimetype first+stored OK; size={len(raw)}; first={first_name}")
    return raw

if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/fixture.epub"
    raw = build_epub()
    open(out, "wb").write(raw)
    print(f"wrote {out} ({len(raw)} bytes)")
