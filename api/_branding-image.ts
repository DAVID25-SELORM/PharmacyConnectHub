import sharp from "sharp";

/** Decode actual content, bound resource use, strip metadata and emit a single inert image. */
export async function normalizeBrandingImage(input: Buffer) {
  if (!input.length || input.length > 2097152) throw new Error("Use an image up to 2 MB.");
  const image = sharp(input, { limitInputPixels: 4096 * 4096, failOn: "warning", animated: false });
  const info = await image.metadata();
  if (!["png", "jpeg", "webp"].includes(info.format ?? "") || (info.pages ?? 1) > 1)
    throw new Error("Use a static PNG, JPEG, or WebP image.");
  if (
    !info.width ||
    !info.height ||
    Math.min(info.width, info.height) < 32 ||
    Math.max(info.width, info.height) > 4096
  )
    throw new Error("Each image dimension must be between 32 and 4096 pixels.");
  const output = await image.rotate().webp({ lossless: true }).toBuffer();
  if (output.length > 2097152)
    throw new Error("The processed logo exceeds 2 MB. Use a smaller image.");
  return output;
}
