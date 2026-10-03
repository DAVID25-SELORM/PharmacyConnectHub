import { describe, expect, it } from "vitest";
import {
  CHECKOUT_CATEGORIES,
  purchaseCategoryLabel,
  summarizeClassification,
  unclassifiedMessage,
  type ClassificationLine,
} from "./purchase-category";

const line = (
  id: string,
  amount: number,
  category: ClassificationLine["category"],
): ClassificationLine => ({
  id,
  amount,
  category,
});

describe("summarizeClassification", () => {
  it("splits spend and line counts per classification and labels a mixed purchase", () => {
    const summary = summarizeClassification([
      line("para", 4000, "nhis"),
      line("amox", 4450, "nhis"),
      line("vitc", 1500, "cash_private"),
      line("ors", 800, "cash_private"),
    ]);
    expect(summary.byCategory.nhis).toEqual({ lines: 2, amount: 8450 });
    expect(summary.byCategory.cash_private).toEqual({ lines: 2, amount: 2300 });
    expect(summary.total).toBe(10750);
    expect(summary.label).toBe("Mixed Purchase");
    expect(summary.unclassified.lines).toBe(0);
  });

  it("labels a single-classification order by that classification", () => {
    expect(summarizeClassification([line("a", 10, "nhis"), line("b", 5, "nhis")]).label).toBe(
      "NHIS Order",
    );
    expect(summarizeClassification([line("a", 10, "cash_private")]).label).toBe("Cash Order");
  });

  it("has no label while lines are unclassified, and lists exactly which ones", () => {
    const summary = summarizeClassification([
      line("a", 10, "nhis"),
      line("b", 5, undefined),
      line("c", 2.5, undefined),
    ]);
    expect(summary.label).toBeNull();
    expect(summary.unclassified).toEqual({ lines: 2, amount: 7.5, ids: ["b", "c"] });
    expect(summary.total).toBe(17.5);
  });

  it("has no label for an empty cart", () => {
    expect(summarizeClassification([]).label).toBeNull();
    expect(summarizeClassification([]).total).toBe(0);
  });

  it("does not drift on floating-point amounts", () => {
    const summary = summarizeClassification([line("a", 0.1, "nhis"), line("b", 0.2, "nhis")]);
    expect(summary.byCategory.nhis.amount).toBe(0.3);
  });
});

describe("unclassifiedMessage", () => {
  it("uses singular and plural forms", () => {
    expect(unclassifiedMessage(1)).toBe("1 item still needs a purchase classification.");
    expect(unclassifiedMessage(3)).toBe("3 items still need a purchase classification.");
  });
});

describe("classification labels and checkout options", () => {
  it("shows cash_private as Cash and never assumes legacy orders are cash", () => {
    expect(purchaseCategoryLabel("cash_private")).toBe("Cash");
    expect(purchaseCategoryLabel(null)).toBe("Not classified");
    expect(purchaseCategoryLabel(undefined)).toBe("Not classified");
  });
  it("offers only NHIS and Cash at checkout", () => {
    expect(CHECKOUT_CATEGORIES).toEqual(["nhis", "cash_private"]);
  });
});
