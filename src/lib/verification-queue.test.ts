import { describe, expect, it } from "vitest";
import { documentsComplete, waitingLabel, waitingTone } from "./verification-queue";

describe("verification queue helpers", () => {
  it("words the waiting time", () => {
    expect(waitingLabel(null)).toBe("—");
    expect(waitingLabel(0)).toBe("Today");
    expect(waitingLabel(1)).toBe("1 day");
    expect(waitingLabel(12)).toBe("12 days");
  });

  it("flags long waits", () => {
    expect(waitingTone(null)).toBe("normal");
    expect(waitingTone(2)).toBe("normal");
    expect(waitingTone(3)).toBe("warning");
    expect(waitingTone(7)).toBe("urgent");
  });

  it("knows when every required document is in", () => {
    expect(documentsComplete({ docs_uploaded: 2, docs_required: 2 })).toBe(true);
    expect(documentsComplete({ docs_uploaded: 1, docs_required: 3 })).toBe(false);
  });
});
