// @vitest-environment jsdom
import { act, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import { beforeEach, afterEach, expect, it, vi } from "vitest";
const mocks = vi.hoisted(() => ({ rpc: vi.fn() }));
vi.mock("@/lib/external-procurement", () => ({ externalRpc: mocks.rpc }));
vi.mock("./ProcurementCatalogue", () => ({
  ProcurementCatalogue: ({ onAdd }: any) => (
    <button
      type="button"
      onClick={() =>
        onAdd({
          id: "catalogue",
          source: "business",
          data: { name: "Selected medicine", unit: "packs" },
        })
      }
    >
      Add catalogue fixture
    </button>
  ),
}));
vi.mock("./ProcurementTemplates", () => ({ ProcurementTemplates: () => null }));
import { SupplyEditor } from "./SupplyEditor";
import { supplyDraft } from "@/lib/external-supply-orders";
let host: HTMLDivElement, root: Root;
beforeEach(() => {
  mocks.rpc.mockResolvedValue([]);
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
  vi.restoreAllMocks();
});
function Fixture() {
  const [draft, setDraft] = useState({
    ...supplyDraft(),
    lines: [{ ...supplyDraft().lines[0], specification: "Keep this unfinished row", quantity: 7 }],
  });
  return (
    <SupplyEditor
      businessId="business"
      draft={draft}
      onChange={setDraft}
      busy={false}
      save={() => {}}
      saveError=""
    />
  );
}
async function click(text: string) {
  const button = Array.from(host.querySelectorAll("button")).find((b) => b.textContent === text)!;
  expect(button).toBeTruthy();
  await act(async () => button.click());
}
it("adding catalogue entries preserves unfinished edited rows", async () => {
  await act(async () => root.render(<Fixture />));
  await click("Add catalogue fixture");
  expect(host.querySelectorAll('[aria-label^="Quantity "]')).toHaveLength(2);
  expect((host.querySelector('[aria-label="Quantity 1"]') as HTMLInputElement).value).toBe("7");
  expect((host.querySelector('[aria-label="Specification 1"]') as HTMLInputElement).value).toBe(
    "Keep this unfinished row",
  );
});
it("preview renders unsaved values without a write", async () => {
  await act(async () => root.render(<Fixture />));
  await click("Preview document");
  expect(host.textContent).toContain("DRAFT - Request for quotation");
  expect(mocks.rpc.mock.calls.every((c) => c[0] === "procurement_suppliers")).toBe(true);
});
it("shows saved only when caller confirms persisted draft", async () => {
  await act(async () =>
    root.render(
      <SupplyEditor
        businessId="b"
        draft={supplyDraft()}
        onChange={() => {}}
        busy={false}
        save={() => {}}
        saveError=""
        saved
      />,
    ),
  );
  expect(host.querySelector('[role="status"]')?.textContent).toBe("Saved");
});
