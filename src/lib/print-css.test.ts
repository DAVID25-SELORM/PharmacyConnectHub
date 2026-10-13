import { readFileSync } from "node:fs";
import { transform } from "lightningcss";
import { describe, expect, it } from "vitest";

/**
 * Production CSS is minified. The minifier folds `translate`, `rotate` and `scale` resets into one
 * `transform` declaration, which does not clear a dialog's individual `translate: -50% -50%`.
 * The printed document was then shifted up and left and clipped (Ctrl+P on the orders page).
 */
describe("print stylesheet survives minification", () => {
  const css = readFileSync("src/styles.css", "utf8");
  const printBlock = css.slice(css.indexOf("@media print"), css.indexOf("@custom-variant"));
  const minified = transform({
    filename: "print.css",
    code: Buffer.from(printBlock),
    minify: true,
  }).code.toString();

  it("keeps an explicit reset of the individual translate property on the document's ancestors", () => {
    expect(minified).toMatch(/translate:0(px| 0)?!important/);
  });
  it("zeroes the Tailwind translate variables used by centred dialogs", () => {
    expect(minified).toContain("--tw-translate-x:0px!important");
    expect(minified).toContain("--tw-translate-y:0px!important");
  });
  it("still hides everything that is not part of the printed document", () => {
    expect(minified).toContain(".print-document");
    expect(minified).toMatch(/display:none!important/);
  });
});
