import { Buffer } from "buffer";

import path from "path-browserify";

import { native } from "../native";
let documentDir = "/documents";
export const init = async () => {};
export const bundledDatabasePath = "/resources/default-db.sqlite";
export const migrationsPath = "/resources/migrations";
export const demoBudgetPath = "/resources/demo-budget";
export const join = path.join;
export const basename = path.basename;
export const getDataDir = () => "/documents";
export const _setDocumentDir = (dir: string) => {
  documentDir = dir;
};
export const getDocumentDir = () => documentDir;
export function getBudgetDir(id: string) {
  if (!id || /[^A-Za-z0-9_-]/.test(id)) throw new Error("Invalid budget identifier");
  return join(documentDir, id);
}
export const listDir = async (path: string) => native<string[]>("fs.list", { path });
export const exists = async (path: string) => native<boolean>("fs.exists", { path });
export const mkdir = async (path: string) => native("fs.mkdir", { path });
export const size = async (path: string) => native<number>("fs.size", { path });
export const copyFile = async (from: string, to: string) => native("fs.copy", { from, to });
export async function readFile(path: string, encoding: "utf8" | "binary" | null = "utf8") {
  const data = Buffer.from(native<string>("fs.read", { path }), "base64");
  return encoding === "binary" || encoding === null ? data : data.toString("utf8");
}
export async function writeFile(path: string, contents: string | ArrayBuffer | Uint8Array) {
  const data =
    typeof contents === "string"
      ? Buffer.from(contents)
      : Buffer.from(contents instanceof ArrayBuffer ? new Uint8Array(contents) : contents);
  native("fs.write", { path, data: data.toString("base64") });
}
export const removeFile = async (path: string) => native("fs.remove", { path });
export const removeDir = removeFile;
export const removeDirRecursively = removeFile;
export const getModifiedTime = async (path: string) =>
  new Date(native<number>("fs.modified", { path }));
