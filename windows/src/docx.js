const zlib = require("node:zlib");

/**
 * Builds a .docx file from text extracted from a PDF.
 * `document` is { pageWidth, pageHeight, pages: [{ paragraphs: [{ runs: [{ text, bold, italic, size }] }] }] }
 * with sizes in points.
 */
function buildDocx(document) {
  return zip([
    ["[Content_Types].xml", CONTENT_TYPES],
    ["_rels/.rels", ROOT_RELS],
    ["word/_rels/document.xml.rels", DOCUMENT_RELS],
    ["word/styles.xml", STYLES],
    ["word/document.xml", documentXML(document)],
  ]);
}

// MARK: - XML

const CONTENT_TYPES = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
</Types>`;

const ROOT_RELS = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>`;

const DOCUMENT_RELS = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>`;

const STYLES = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:docDefaults>
<w:rPrDefault><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial" w:eastAsia="Arial" w:cs="Arial"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="sq-AL"/></w:rPr></w:rPrDefault>
<w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault>
</w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
</w:styles>`;

function documentXML({ pageWidth, pageHeight, pages }) {
  const body = [];
  pages.forEach((page, index) => {
    const pageBreak = index > 0 ? "<w:pageBreakBefore/>" : "";
    if (!page.paragraphs.length) {
      body.push(`<w:p><w:pPr>${pageBreak}</w:pPr></w:p>`);
      return;
    }
    page.paragraphs.forEach((paragraph, i) => {
      const runs = paragraph.runs.map(runXML).join("");
      body.push(`<w:p><w:pPr>${i === 0 ? pageBreak : ""}</w:pPr>${runs}</w:p>`);
    });
  });

  // Word measures in twentieths of a point
  const width = Math.round((pageWidth || 612) * 20);
  const height = Math.round((pageHeight || 792) * 20);
  const orientation = width > height ? ' w:orient="landscape"' : "";
  return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
${body.join("\n")}
<w:sectPr><w:pgSz w:w="${width}" w:h="${height}"${orientation}/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>
</w:body>
</w:document>`;
}

function runXML({ text, bold, italic, size }) {
  const halfPoints = Math.round(Math.min(Math.max(size || 11, 6), 72) * 2);
  const properties = `${bold ? "<w:b/>" : ""}${italic ? "<w:i/>" : ""}<w:sz w:val="${halfPoints}"/><w:szCs w:val="${halfPoints}"/>`;
  return `<w:r><w:rPr>${properties}</w:rPr><w:t xml:space="preserve">${escapeXML(text)}</w:t></w:r>`;
}

function escapeXML(text) {
  return String(text)
    // Characters XML does not allow; PDFs sometimes contain them
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/g, "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

// MARK: - Zip

/** Minimal zip writer (deflate, no zip64), enough for a .docx package. */
function zip(entries) {
  const locals = [];
  const centrals = [];
  let offset = 0;

  for (const [name, content] of entries) {
    const nameBytes = Buffer.from(name, "utf8");
    const data = Buffer.from(content, "utf8");
    const compressed = zlib.deflateRawSync(data);
    const crc = zlib.crc32(data);

    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4); // version needed
    local.writeUInt16LE(0x0800, 6); // UTF-8 names
    local.writeUInt16LE(8, 8); // deflate
    local.writeUInt16LE(0, 10); // time
    local.writeUInt16LE(0x21, 12); // date: 1980-01-01
    local.writeUInt32LE(crc, 14);
    local.writeUInt32LE(compressed.length, 18);
    local.writeUInt32LE(data.length, 22);
    local.writeUInt16LE(nameBytes.length, 26);
    local.writeUInt16LE(0, 28);
    locals.push(local, nameBytes, compressed);

    const central = Buffer.alloc(46);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4); // version made by
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(0x0800, 8);
    central.writeUInt16LE(8, 10);
    central.writeUInt16LE(0, 12);
    central.writeUInt16LE(0x21, 14);
    central.writeUInt32LE(crc, 16);
    central.writeUInt32LE(compressed.length, 20);
    central.writeUInt32LE(data.length, 24);
    central.writeUInt16LE(nameBytes.length, 28);
    central.writeUInt32LE(offset, 42);
    centrals.push(central, nameBytes);

    offset += local.length + nameBytes.length + compressed.length;
  }

  const centralSize = centrals.reduce((sum, part) => sum + part.length, 0);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0);
  end.writeUInt16LE(entries.length, 8);
  end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(centralSize, 12);
  end.writeUInt32LE(offset, 16);
  return Buffer.concat([...locals, ...centrals, end]);
}

module.exports = { buildDocx };
