import { describe, expect, it } from "vitest";
import sharp from "sharp";
import { normalizeBrandingImage } from "./_branding-image";
const image = (width = 64, height = 64) =>
  sharp({ create: { width, height, channels: 4, background: "#008877" } });
describe("validated logo processing", () => {
  it("normalizes supported formats to a static metadata-free WebP", async () => {
    for (const format of ["png", "jpeg", "webp"] as const) {
      const output = await normalizeBrandingImage(await image().toFormat(format).toBuffer());
      const info = await sharp(output).metadata();
      expect(info.format).toBe("webp");
      expect(info.width).toBe(64);
      expect(info.exif).toBeUndefined();
    }
  });
  it("rejects corrupted content, SVG and oversized files", async () => {
    for (const bytes of [
      Buffer.from("not an image"),
      Buffer.from('<svg width="64" height="64"></svg>'),
      Buffer.alloc(2097153),
    ])
      await expect(normalizeBrandingImage(bytes)).rejects.toThrow();
  });
  it("rejects dimensions outside allowed bounds", async () => {
    for (const [w, h] of [
      [31, 64],
      [64, 31],
      [4097, 32],
    ])
      await expect(normalizeBrandingImage(await image(w, h).png().toBuffer())).rejects.toThrow();
  });
});
