declare module "path-browserify" {
  const path: { join(...paths: string[]): string; basename(path: string): string };
  export default path;
}
// Actual's goal template grammar, compiled by the build's peggy loader.
declare module "@actual/source/server/budget/goal-template.pegjs" {
  import type { Template } from "@actual/source/types/models/templates.ts";
  export function parse(input: string): Template;
}
