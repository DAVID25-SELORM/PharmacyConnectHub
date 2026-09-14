export const MAX_VERIFICATION_BYTES = 10 * 1024 * 1024;
export async function validateVerificationFile(file: File) {
  if (!file.size || file.size > MAX_VERIFICATION_BYTES)
    throw new Error("Choose a nonempty document of at most 10MB.");
  const ext = file.name.split(".").pop()?.toLowerCase();
  const allowed: Record<string, string> = {
    pdf: "application/pdf",
    png: "image/png",
    jpg: "image/jpeg",
    jpeg: "image/jpeg",
  };
  if (!ext || !allowed[ext] || (file.type && file.type !== allowed[ext]))
    throw new Error("Only PDF, PNG and JPEG documents are supported.");
  const b = new Uint8Array(await file.slice(0, 8).arrayBuffer());
  const valid =
    ext === "pdf"
      ? new TextDecoder().decode(b).startsWith("%PDF-")
      : ext === "png"
        ? [137, 80, 78, 71, 13, 10, 26, 10].every((v, i) => b[i] === v)
        : b[0] === 255 && b[1] === 216 && b[2] === 255;
  if (!valid) throw new Error("Document content does not match its file type.");
  return allowed[ext];
}
