export class HttpError extends Error {
  constructor(
    public status: number,
    message: string,
    public headers: Record<string, string> = {},
    // A short machine word the Mac app can act on. The message stays plain text for people.
    public code?: string,
  ) {
    super(message);
  }
}

export function json(data: unknown, status = 200, headers: HeadersInit = {}): Response {
  return Response.json(data, { status, headers: { "cache-control": "no-store", ...headers } });
}

export async function body<T>(request: Request): Promise<T> {
  try {
    return (await request.json()) as T;
  } catch {
    throw new HttpError(400, "Send JSON");
  }
}

export function text(v: unknown, field: string, max: number, required = true): string | null {
  if (v === undefined || v === null || v === "") {
    if (required) throw new HttpError(400, `${field} is missing`);
    return null;
  }
  if (typeof v !== "string") throw new HttpError(400, `${field} must be text`);
  const s = v.trim();
  if (required && s === "") throw new HttpError(400, `${field} is missing`);
  if (s.length > max) throw new HttpError(400, `${field} is longer than ${max} characters`);
  return s;
}

export const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
