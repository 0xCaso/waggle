// The relay tsconfig has no Node types. The fake Git remote in the tests uses this one call.
declare module "node:zlib" {
  export function inflateSync(data: Uint8Array, options?: { info: boolean }): unknown;
}
