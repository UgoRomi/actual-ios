declare module "path-browserify" {
  const path: { join(...paths: string[]): string; basename(path: string): string };
  export default path;
}
