import { expect, it } from "vitest";
import { cleanRecoveryUrl } from "./recovery-url";
it("removes all supported recovery credentials while retaining unrelated query state", () => {
  expect(
    cleanRecoveryUrl(
      "https://example.test/reset-password?code=test&access_token=test&refresh_token=test&token=test&recovery_token=test&token_hash=test&type=recovery&next=home#access_token=test",
    ),
  ).toBe("https://example.test/reset-password?next=home");
});
