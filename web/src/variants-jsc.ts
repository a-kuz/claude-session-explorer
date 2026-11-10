// Entry of the bundle the macOS app runs in JavaScriptCore to build the
// transcript variants it uploads with a share (`pnpm build:jsc` writes it to
// Sources/Resources/transcript.js).

import { VariantBuilder } from "./variants";

(globalThis as Record<string, unknown>).SETranscript = {
  create: (imageBase: string) => new VariantBuilder(imageBase),
};
