import { describe, expect, it } from "vitest";
import { documentFileName, resolveDocumentBranding } from "./document-branding";

describe("document branding", () => {
  it("keeps light brand colours from hiding document text", () => {
    expect(resolveDocumentBranding({ name:"Supplier", branding:{accent_color:"#ffffff"} }).accentColor).toBe("#0f766e");
    expect(resolveDocumentBranding({ name:"Supplier", branding:{accent_color:"#112233"} }).accentColor).toBe("#112233");
  });
  it("does not replace the registered issuer with a presentation name", () => {
    expect(resolveDocumentBranding({ name: "Registered Supplier Ltd", branding: { display_name: "Trading Brand" } }).name).toBe("Registered Supplier Ltd");
  });
  it("keeps the trusted business name when no display name is configured", () => {
    const identity = resolveDocumentBranding({
      name: "Ideal Pharma Ltd",
      city: "Accra",
      region: "Greater Accra",
      phone: "+233 20 000 0000",
      license_number: "PC-123",
      branding: { show_license: true },
    });
    expect(identity.name).toBe("Ideal Pharma Ltd");
    expect(identity.contactLines).not.toContain("Licence: PC-123");
  });

  it("rejects unsafe accent colors and honours visibility preferences", () => {
    const identity = resolveDocumentBranding({
      name: "Reel Pharmacy",
      phone: "024 000 0000",
      public_email: "orders@example.test",
      license_number: "PC-456",
      branding: { accent_color: "url(javascript:alert(1))", show_license: false, show_secondary_contact: false },
    });
    expect(identity.accentColor).toBe("#0f766e");
    expect(identity.contactLines).not.toContain("Licence: PC-456");
    expect(identity.contactLines).not.toContain("orders@example.test");
  });

  it("creates stable download-safe document names", () => {
    expect(documentFileName("Invoice", "INV/2026 001")).toBe("invoice-inv-2026-001.pdf");
  });
});
