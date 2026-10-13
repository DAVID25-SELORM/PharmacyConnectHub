import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("production asset routing", () => {
  const config = JSON.parse(readFileSync("vercel.json", "utf8"));
  const fallback = new RegExp(`^${config.rewrites[0].source}$`);

  it("never returns the SPA shell for missing JavaScript or API paths", () => {
    for (const path of ["/assets", "/assets/missing.js", "/assets/missing.css", "/api", "/api/receipt"])
      expect(fallback.test(path), path).toBe(false);
    for (const path of ["/", "/pharmacy", "/pharmacy/orders", "/admin/billing"])
      expect(fallback.test(path), path).toBe(true);
  });

  it("revalidates app HTML and uses the maintained font stylesheet", () => {
    expect(config.headers.some((rule: { headers: { key: string; value: string }[] }) =>
      rule.headers.some((header) => header.key === "Cache-Control" && header.value === "no-cache"),
    )).toBe(true);
    expect(readFileSync("src/styles.css", "utf8")).not.toContain("fonts.gstatic.com");
    expect(readFileSync("index.html", "utf8")).toContain("Plus+Jakarta+Sans:wght@400;500;600;700;800");
  });
});
