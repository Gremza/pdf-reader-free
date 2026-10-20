/**
 * Turns the text of a PDF into paragraphs for a Word document.
 * PDFs store positioned pieces of text, not paragraphs, so lines are rebuilt from positions
 * and joined into paragraphs when they are close together and the previous line runs to the margin.
 */
export async function extractDocument(pdf, onProgress) {
  const pages = [];
  let pageWidth = 0;
  let pageHeight = 0;

  for (let n = 1; n <= pdf.numPages; n++) {
    const page = await pdf.getPage(n);
    if (n === 1) {
      const viewport = page.getViewport({ scale: 1 });
      pageWidth = viewport.width;
      pageHeight = viewport.height;
    }
    // Loads the page's fonts, so their real names (…-Bold, …-Italic) are known
    await page.getOperatorList();
    const content = await page.getTextContent();
    pages.push({ paragraphs: paragraphsFrom(linesFrom(content.items, page)) });
    page.cleanup();
    onProgress?.(n);
  }
  return { pageWidth, pageHeight, pages };
}

export function hasText(document) {
  return document.pages.some((page) => page.paragraphs.some((paragraph) => paragraph.runs.some((run) => run.text.trim())));
}

function fontStyle(page, fontName) {
  try {
    const name = page.commonObjs.get(fontName)?.name ?? "";
    return { bold: /bold|black|heavy|semibold|demi/i.test(name), italic: /italic|oblique/i.test(name) };
  } catch {
    return { bold: false, italic: false };
  }
}

function linesFrom(items, page) {
  const lines = [];
  const styles = new Map();
  let line = null;

  for (const item of items) {
    if (!item.str) {
      if (item.hasEOL && line) line.ended = true;
      continue;
    }
    const [, , c, d, x, y] = item.transform;
    const size = Math.hypot(c, d) || item.height || 11;
    if (!styles.has(item.fontName)) styles.set(item.fontName, fontStyle(page, item.fontName));
    const style = styles.get(item.fontName);

    if (!line || line.ended || Math.abs(y - line.y) > size * 0.5) {
      line = { x, y, size, right: x, runs: [] };
      lines.push(line);
    } else {
      // Separate words that the PDF placed apart without a space character
      const last = line.runs.at(-1);
      if (x - line.right > size * 0.2 && !/\s$/.test(last.text) && !/^\s/.test(item.str)) last.text += " ";
    }

    const last = line.runs.at(-1);
    const roundedSize = Math.round(size * 2) / 2;
    if (last && last.bold === style.bold && last.italic === style.italic && last.size === roundedSize) {
      last.text += item.str;
    } else {
      line.runs.push({ text: item.str, bold: style.bold, italic: style.italic, size: roundedSize });
    }
    line.size = Math.max(line.size, size);
    line.right = Math.max(line.right, x + item.width);
    if (item.hasEOL) line.ended = true;
  }
  return lines.filter((l) => l.runs.some((run) => run.text.trim()));
}

function paragraphsFrom(lines) {
  if (!lines.length) return [];
  const left = Math.min(...lines.map((l) => l.x));
  const right = Math.max(...lines.map((l) => l.right));
  const paragraphs = [];
  let previous = null;

  for (const line of lines) {
    if (previous && continuesParagraph(previous, line, left, right)) {
      const runs = paragraphs.at(-1).runs;
      const last = runs.at(-1);
      // "exam-" + "ple" → "example"; otherwise join the lines with a space
      if (/[a-zëç]-$/i.test(last.text) && /^[a-zëç]/.test(line.runs[0].text)) last.text = last.text.slice(0, -1);
      else if (!/\s$/.test(last.text)) last.text += " ";
      for (const run of line.runs) appendRun(runs, run);
    } else {
      paragraphs.push({ runs: line.runs.map((run) => ({ ...run })) });
    }
    previous = line;
  }
  for (const paragraph of paragraphs) paragraph.runs.at(-1).text = paragraph.runs.at(-1).text.trimEnd();
  return paragraphs;
}

function continuesParagraph(previous, line, left, right) {
  const size = Math.max(previous.size, line.size);
  const gap = previous.y - line.y;
  return gap > 0
    && gap < size * 1.7
    && Math.abs(previous.size - line.size) < 1
    // The previous line reaches the right margin, so the text wraps
    && previous.right > right - size * 4
    // A first-line indent starts a new paragraph
    && line.x < left + size * 1.5;
}

function appendRun(runs, run) {
  const last = runs.at(-1);
  if (last.bold === run.bold && last.italic === run.italic && last.size === run.size) last.text += run.text;
  else runs.push({ ...run });
}
