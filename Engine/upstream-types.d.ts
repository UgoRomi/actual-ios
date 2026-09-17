import "@actual/server-config";

// The pinned upstream implementation supports null to clear the server,
// but its generated declaration excludes that existing reset operation.
declare module "@actual/server-config" {
  export function setServer(url: string | null): void;
}
