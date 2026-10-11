// Exercise the real print stylesheet in Chrome, including portalled dialogs.
import { chromium } from '../.tmp/import-db/node_modules/playwright/index.mjs';
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { getDocument } from 'pdfjs-dist/legacy/build/pdf.mjs';

const source = await readFile(new URL('../src/styles.css', import.meta.url), 'utf8');
const printCss = source.slice(source.indexOf('@media print {'), source.indexOf('@custom-variant'));
const browser = await chromium.launch({ executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true });
try {
  const page = await browser.newPage();
  await page.emulateMedia({ media: 'print' });
  const document = (rows = 1) => `<article class="print-document business-document"><h1>Invoice</h1><table><thead><tr><th>Product</th></tr></thead><tbody>${Array.from({ length: rows }, (_, i) => `<tr><td>Medicine ${i + 1}</td></tr>`).join('')}</tbody></table><footer>End of invoice</footer></article>`;
  const render = async (content) => {
    await page.setContent(`<style>${printCss} td {height:24px}</style>${content}`);
    const task = getDocument({ data: new Uint8Array(await page.pdf({ preferCSSPageSize: true })) });
    const pdf = await task.promise;
    const texts = [];
    for (let i = 1; i <= pdf.numPages; i++) {
      const pdfPage = await pdf.getPage(i);
      texts.push((await pdfPage.getTextContent()).items.map(item => item.str).join(' '));
    }
    await task.destroy();
    return texts;
  };
  const modal = content => `<main style="height:4000px">Unrelated application</main><div style="position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);max-height:200px;overflow:auto"><button>Close dialog</button>${content}</div>`;
  const short = await render(modal(document()));
  assert.equal(short.length, 1, 'Short modal document must have no blank pages');
  assert.match(short[0], /End of invoice/);
  assert.doesNotMatch(short[0], /Unrelated application|Close dialog/);
  const long = await render(modal(document(100)));
  assert.ok(long.length > 1, 'Long documents must paginate');
  assert.match(long.at(-1), /Medicine 100.*End of invoice/);
  assert.ok(long.every(text => text.trim()), 'No empty pages');
  const bulk = await render(modal(document() + document()));
  assert.equal(bulk.length, 2, 'Bulk invoices start separate pages');
  const ordinary = await render('<main>Ordinary report without document wrapper</main>');
  assert.match(ordinary[0], /Ordinary report/, 'Ordinary reports remain printable');
  console.log('PASS: short modal, long pagination, bulk invoices, ordinary report printing');
} finally {
  await browser.close();
}
