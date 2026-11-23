/**
 * Checks a file before it is uploaded as a licence, evidence or supporting document.
 *
 * This is NOT an antivirus. It removes the easy ways to smuggle something harmful in:
 *  - only PDF, JPEG, PNG and WebP are accepted, judged by the file's real first bytes rather than
 *    its name or the type the browser claims;
 *  - names that look like programs, scripts or web pages ("invoice.pdf.exe", "licence.html") are refused;
 *  - PDFs that ask to run code, launch programs or carry hidden attachments are refused;
 *  - the size cap is enforced.
 *
 * The storage buckets repeat the type and size limits on the server.
 */

export const MAX_DOCUMENT_BYTES = 10 * 1024 * 1024;

export type DocumentKind = "pdf" | "jpeg" | "png" | "webp";

const KIND_INFO: Record<DocumentKind, { mime: string; extension: string; label: string }> = {
  pdf: { mime: "application/pdf", extension: "pdf", label: "PDF" },
  jpeg: { mime: "image/jpeg", extension: "jpg", label: "JPEG" },
  png: { mime: "image/png", extension: "png", label: "PNG" },
  webp: { mime: "image/webp", extension: "webp", label: "WebP" },
};

export function mimeForKind(kind: DocumentKind): string {
  return KIND_INFO[kind].mime;
}

export function extensionForKind(kind: DocumentKind): string {
  return KIND_INFO[kind].extension;
}

function startsWith(bytes: Uint8Array, signature: number[], offset = 0): boolean {
  return signature.every((value, index) => bytes[offset + index] === value);
}

/** Identifies the file by its first bytes. Null for anything that is not an accepted document. */
export function sniffDocumentKind(bytes: Uint8Array): DocumentKind | null {
  // %PDF- may follow up to 1 KB of junk, which PDF readers tolerate.
  const head = bytes.subarray(0, 1024);
  for (let i = 0; i + 4 < head.length; i++) {
    if (startsWith(head, [0x25, 0x50, 0x44, 0x46, 0x2d], i)) return "pdf";
  }
  if (startsWith(bytes, [0xff, 0xd8, 0xff])) return "jpeg";
  if (startsWith(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return "png";
  if (
    startsWith(bytes, [0x52, 0x49, 0x46, 0x46]) &&
    startsWith(bytes, [0x57, 0x45, 0x42, 0x50], 8)
  ) {
    return "webp";
  }
  return null;
}

const RISKY_EXTENSIONS = new Set([
  "exe",
  "dll",
  "msi",
  "bat",
  "cmd",
  "com",
  "scr",
  "pif",
  "cpl",
  "lnk",
  "vbs",
  "vbe",
  "js",
  "jse",
  "wsf",
  "wsh",
  "ps1",
  "psm1",
  "sh",
  "bash",
  "jar",
  "apk",
  "app",
  "dmg",
  "iso",
  "reg",
  "hta",
  "html",
  "htm",
  "xhtml",
  "svg",
  "xml",
  "php",
  "asp",
  "aspx",
  "jsp",
  "py",
  "rb",
  "pl",
  "docm",
  "xlsm",
  "pptm",
  "zip",
  "rar",
  "7z",
  "gz",
  "tar",
]);

/** True when any dot-separated part of the name is a program, script, web page or archive type. */
export function hasRiskyName(name: string): boolean {
  const parts = name.toLowerCase().split(".").slice(1);
  return parts.some((part) => RISKY_EXTENSIONS.has(part.trim()));
}

// Names in a PDF that run code, launch programs, embed files or load interactive content.
const ACTIVE_PDF_NAMES =
  /\/(JavaScript|JS|Launch|EmbeddedFile|EmbeddedFiles|RichMedia|XFA|SubmitForm|ImportData)\b/;
const OPEN_ACTION = /\/(OpenAction|AA)\b/;

/**
 * Looks in the raw bytes for the markers of an active PDF. A PDF can hide these inside compressed
 * streams, so this reduces risk rather than removing it.
 */
export function pdfHasActiveContent(bytes: Uint8Array): boolean {
  let text = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    text += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  if (ACTIVE_PDF_NAMES.test(text)) return true;
  // An automatic action is only a problem when it also names an action type that runs something.
  return OPEN_ACTION.test(text) && /\/S\s*\/(JavaScript|Launch|URI|GoToR|GoToE)\b/.test(text);
}

export type UploadCheck =
  | { ok: true; kind: DocumentKind; mime: string; extension: string }
  | { ok: false; message: string };

export async function checkUploadFile(
  file: Pick<File, "name" | "size" | "arrayBuffer">,
  options: { maxBytes?: number; allowed?: DocumentKind[] } = {},
): Promise<UploadCheck> {
  const maxBytes = options.maxBytes ?? MAX_DOCUMENT_BYTES;
  const allowed = options.allowed ?? ["pdf", "jpeg", "png", "webp"];
  const allowedLabel = allowed.map((kind) => KIND_INFO[kind].label).join(", ");

  if (file.size === 0) return { ok: false, message: "This file is empty." };
  if (file.size > maxBytes) {
    return { ok: false, message: `This file is larger than ${Math.round(maxBytes / 1048576)} MB.` };
  }
  if (hasRiskyName(file.name)) {
    return {
      ok: false,
      message: `This file name looks like a program or web page. Choose a ${allowedLabel} file.`,
    };
  }

  const bytes = new Uint8Array(await file.arrayBuffer());
  const kind = sniffDocumentKind(bytes);
  if (!kind || !allowed.includes(kind)) {
    return { ok: false, message: `Choose a ${allowedLabel} file. This file is a different type.` };
  }
  if (kind === "pdf" && pdfHasActiveContent(bytes)) {
    return {
      ok: false,
      message:
        "This PDF contains scripts or embedded content, which we do not accept. Save or print it as a plain PDF and try again.",
    };
  }
  return { ok: true, kind, mime: KIND_INFO[kind].mime, extension: KIND_INFO[kind].extension };
}
