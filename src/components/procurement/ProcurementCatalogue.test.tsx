// @vitest-environment jsdom
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { beforeEach, afterEach, it, expect, vi } from "vitest";
const mocks = vi.hoisted(() => ({ rpc: vi.fn(), add: vi.fn() }));
vi.mock("@/lib/external-procurement", () => ({ externalRpc: mocks.rpc, db: {} }));
import { ProcurementCatalogue } from "./ProcurementCatalogue";
let host: HTMLDivElement, root: Root;
beforeEach(() => {
  mocks.rpc.mockReset();
  mocks.add.mockReset();
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
});
afterEach(async () => {
  await act(async () => root.unmount());
  host.remove();
});
const entries = [
  {
    id: "a",
    source: "business",
    data: { name: "Medicine A", strength: "500 mg" },
    archived: false,
  },
  { id: "b", source: "master", data: { name: "Medicine B", strength: "250 mg" }, archived: false },
];
it("supports keyboard selection and escape without submitting the parent form", async () => {
  mocks.rpc.mockResolvedValue(entries);
  await act(async () => root.render(<ProcurementCatalogue businessId="b" onAdd={mocks.add} />));
  const input = host.querySelector("input")!;
  await act(async () => {
    input.dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }),
    );
  });
  await act(async () => {
    input.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }),
    );
  });
  expect(mocks.add).toHaveBeenCalledWith(entries[1]);
  await act(async () => {
    input.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
  });
  expect(host.querySelector('[role="listbox"]')).toBeNull();
});
it("never selects an archived result by keyboard", async () => {
  mocks.rpc.mockResolvedValue([{ ...entries[0], archived: true }]);
  await act(async () => root.render(<ProcurementCatalogue businessId="b" onAdd={mocks.add} />));
  await act(async () => {
    host
      .querySelector("input")!
      .dispatchEvent(
        new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }),
      );
  });
  expect(mocks.add).not.toHaveBeenCalled();
});
it("retains search errors and allows recovery", async () => {
  mocks.rpc.mockRejectedValueOnce(new Error("Offline")).mockResolvedValueOnce(entries);
  await act(async () => root.render(<ProcurementCatalogue businessId="b" onAdd={mocks.add} />));
  expect(host.textContent).toContain("Offline");
  await act(async () =>
    Array.from(host.querySelectorAll("button"))
      .find((b) => b.textContent === "Retry")!
      .click(),
  );
  expect(host.textContent).toContain("Medicine A");
  expect(host.querySelector('[role="alert"]')).toBeNull();
});
