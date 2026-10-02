import { describe, expect, it } from "vitest";
import { masterProductLabel, toIlikeTerm, validateRfqDraft, type MasterProductSuggestion } from "./rfq";

const product = (overrides: Partial<MasterProductSuggestion> = {}): MasterProductSuggestion => ({
  id: "00000000-0000-0000-0000-000000000001",
  name: "Paracetamol",
  generic_name: null,
  brand_name: null,
  strength: null,
  dosage_form: null,
  pack_size: null,
  ...overrides,
});

describe("masterProductLabel", () => {
  it("returns the bare name when there is nothing to add", () => {
    expect(masterProductLabel(product())).toBe("Paracetamol");
  });
  it("appends strength, form and pack size in that order", () => {
    expect(masterProductLabel(product({ strength: "500mg", dosage_form: "Tablet", pack_size: "20s" }))).toBe(
      "Paracetamol 500mg Tablet 20s",
    );
  });
  it("does not repeat a part the name already contains (case-insensitive)", () => {
    expect(masterProductLabel(product({ name: "Paracetamol 500MG", strength: "500mg", dosage_form: "Tablet" }))).toBe(
      "Paracetamol 500MG Tablet",
    );
  });
  it("ignores blank parts", () => {
    expect(masterProductLabel(product({ strength: "  ", pack_size: "" }))).toBe("Paracetamol");
  });
});

describe("toIlikeTerm", () => {
  it("strips characters that would break a PostgREST or() filter", () => {
    expect(toIlikeTerm("para,cet(amol)%_")).toBe("para cet amol");
  });
  it("collapses whitespace and trims", () => {
    expect(toIlikeTerm("  amox   500 ")).toBe("amox 500");
  });
});

describe("validateRfqDraft", () => {
  const base = { title: "Restock", wholesalerIds: ["w1"], items: [{ productName: "Paracetamol", quantity: "10", notes: "" }], responseDeadline: "" };
  it("accepts a complete draft", () => {
    expect(validateRfqDraft(base).error).toBeNull();
  });
  it("requires at least one recipient, whether picked or broadcast", () => {
    expect(validateRfqDraft({ ...base, wholesalerIds: [] }).error).toMatch(/at least one supplier/i);
  });
});
