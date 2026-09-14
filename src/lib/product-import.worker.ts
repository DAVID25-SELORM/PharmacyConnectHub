import { parseProductImportFileDirect } from "./product-import";
self.onmessage = async (event: MessageEvent<File>) => {
  try {
    self.postMessage({
      type: "product-import-result",
      result: await parseProductImportFileDirect(event.data),
    });
  } catch (error) {
    self.postMessage({
      type: "product-import-result",
      error: error instanceof Error ? error.message : "Malformed import.",
    });
  }
};
