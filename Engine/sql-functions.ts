import { normalise } from "@actual/source/platform/server/sqlite/normalise.ts";
import { unicodeLike } from "@actual/source/platform/server/sqlite/unicodeLike.ts";
export const sqlFunctions = {
  UNICODE_LOWER: (x: string | null) => x?.toLowerCase() ?? null,
  UNICODE_UPPER: (x: string | null) => x?.toUpperCase() ?? null,
  UNICODE_LIKE: unicodeLike,
  REGEXP: (pattern: string, value: string | null) =>
    new RegExp(pattern).test(value || "") ? 1 : 0,
  NORMALISE: normalise,
};
