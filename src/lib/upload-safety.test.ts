import { describe, expect, it } from "vitest";
import {
  checkUploadFile,
  hasRiskyName,
  pdfHasActiveContent,
  sniffDocumentKind,
} from "@/lib/upload-safety";

const enc = (text: string) => new TextEncoder().encode(text);
const file = (name: string, bytes: Uint8Array, size = bytes.length) => ({
  name,
  size,
  arrayBuffer: async () =>
    bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer,
});

const PDF = enc("%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF");
const PNG = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);
const JPEG = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10]);
const WEBP = Uint8Array.from([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x45, 0x42, 0x50]);

describe("sniffDocumentKind", () => {
  it("recognises the accepted types by their first bytes", () => {
    expect(sniffDocumentKind(PDF)).toBe("pdf");
    expect(sniffDocumentKind(PNG)).toBe("png");
    expect(sniffDocumentKind(JPEG)).toBe("jpeg");
    expect(sniffDocumentKind(WEBP)).toBe("webp");
  });

  it("tolerates a little junk before %PDF- as readers do", () => {
    expect(sniffDocumentKind(enc("\n\n  %PDF-1.4 rest"))).toBe("pdf");
  });

  it("rejects programs, scripts, web pages and archives whatever they are called", () => {
    expect(sniffDocumentKind(enc("MZ\u0090\u0000"))).toBeNull(); // Windows program
    expect(sniffDocumentKind(enc("<html><script>alert(1)</script>"))).toBeNull();
    expect(sniffDocumentKind(enc("<svg onload=alert(1)>"))).toBeNull();
    expect(sniffDocumentKind(enc("PK\u0003\u0004"))).toBeNull(); // zip / docx
    expect(sniffDocumentKind(new Uint8Array())).toBeNull();
  });
});

describe("hasRiskyName", () => {
  it("flags program, script, web page and archive names, including double extensions", () => {
    for (const name of [
      "a.exe",
      "invoice.pdf.exe",
      "x.PDF.JS",
      "page.html",
      "logo.svg",
      "a.zip",
      "macro.docm",
      "run.ps1",
    ]) {
      expect(hasRiskyName(name), name).toBe(true);
    }
  });
  it("accepts ordinary document names", () => {
    for (const name of ["licence.pdf", "Pharmacy Licence 2026.PNG", "scan.1.jpg", "noextension"]) {
      expect(hasRiskyName(name), name).toBe(false);
    }
  });
});

describe("pdfHasActiveContent", () => {
  it("allows a plain PDF", () => {
    expect(pdfHasActiveContent(PDF)).toBe(false);
  });
  it("flags scripts, launch actions and embedded files", () => {
    expect(pdfHasActiveContent(enc("%PDF-1.7 << /S /JavaScript /JS (app.alert(1)) >>"))).toBe(true);
    expect(pdfHasActiveContent(enc("%PDF-1.7 << /Type /Action /S /Launch /F (cmd.exe) >>"))).toBe(
      true,
    );
    expect(pdfHasActiveContent(enc("%PDF-1.7 << /Type /EmbeddedFile >>"))).toBe(true);
  });
  it("flags an automatic action that runs something, but not a bare destination", () => {
    expect(
      pdfHasActiveContent(enc("%PDF-1.7 << /OpenAction << /S /URI /URI (http://x) >> >>")),
    ).toBe(true);
    expect(pdfHasActiveContent(enc("%PDF-1.7 << /OpenAction [3 0 R /Fit] >>"))).toBe(false);
  });
});

describe("checkUploadFile", () => {
  it("accepts a real PDF and reports the type to store it under", async () => {
    const result = await checkUploadFile(file("licence.pdf", PDF));
    expect(result).toMatchObject({
      ok: true,
      kind: "pdf",
      mime: "application/pdf",
      extension: "pdf",
    });
  });

  it("judges by content, not by the name or claimed type", async () => {
    const result = await checkUploadFile(file("licence.pdf", enc("<html><script>x</script>")));
    expect(result.ok).toBe(false);
    const renamed = await checkUploadFile(file("photo.png", PDF));
    expect(renamed).toMatchObject({ ok: true, kind: "pdf", extension: "pdf" });
  });

  it("refuses risky names even when the content looks fine", async () => {
    const result = await checkUploadFile(file("licence.pdf.exe", PDF));
    expect(result).toMatchObject({ ok: false });
  });

  it("refuses an active PDF with a clear message", async () => {
    const result = await checkUploadFile(file("x.pdf", enc("%PDF-1.7 /JavaScript (app.alert(1))")));
    expect(result).toMatchObject({ ok: false });
    if (!result.ok) expect(result.message).toMatch(/scripts or embedded content/);
  });

  it("refuses empty and oversized files before reading them", async () => {
    expect(await checkUploadFile(file("a.pdf", new Uint8Array()))).toMatchObject({ ok: false });
    const big = await checkUploadFile(file("a.pdf", PDF, 11 * 1024 * 1024));
    expect(big).toMatchObject({ ok: false });
    if (!big.ok) expect(big.message).toMatch(/10 MB/);
  });

  it("can be limited to some kinds", async () => {
    const result = await checkUploadFile(file("p.webp", WEBP), { allowed: ["pdf", "jpeg", "png"] });
    expect(result).toMatchObject({ ok: false });
  });
});
