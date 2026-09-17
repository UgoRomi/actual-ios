import { Buffer } from "buffer";

import { bytes } from "../native";
declare function __nativeFetch(payload: string, signal?: AbortSignal | null): Promise<string>;
export async function fetch(
  input: string,
  options: {
    method?: string;
    headers?: Record<string, string>;
    body?: string | Uint8Array | ArrayBuffer;
    signal?: AbortSignal | null;
  } = {},
) {
  const body = options.body;
  const response = JSON.parse(
    await __nativeFetch(
      JSON.stringify({
        url: String(input),
        method: options.method || "GET",
        headers: options.headers || {},
        body:
          body == null
            ? null
            : typeof body === "string"
              ? Buffer.from(body).toString("base64")
              : bytes(body),
      }),
      options.signal,
    ),
  );
  if (response.error) throw new Error(response.error);
  const data = Buffer.from(response.body, "base64");
  return {
    status: response.status,
    ok: response.status >= 200 && response.status < 300,
    type: "basic",
    headers: {
      get: (key: string) => response.headers[key.toLowerCase()] ?? null,
      has: (key: string) => key.toLowerCase() in response.headers,
    },
    text: async () => data.toString("utf8"),
    json: async () => JSON.parse(data.toString("utf8")),
    arrayBuffer: async () => data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength),
  };
}
