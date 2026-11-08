import { z } from "zod";

// HAIL-166: the default design kit and the artifact preset, the two things waggle_settings and
// Settings > Artifacts change. This file holds only schemas, so mcp.ts and rpc.ts both import it.

export const ArtifactPreset = z.enum(["quick", "visual", "rich"]);
export type ArtifactPreset = z.infer<typeof ArtifactPreset>;

// The design system text is stored whole, up to 1 MB. Agents get only the first 8 KB of it
// (DESIGN_KIT_MAX_BYTES in guide/design-kit.ts; docs/protocol-mvp.md "Default design kit").
export const DESIGN_SYSTEM_MAX_BYTES = 1024 * 1024;
export const PEN_FILE_MAX_CHARS = 1024;
export const TONE_MAX_BYTES = 1024;
export const UPDATED_BY_MAX_CHARS = 120;

function maxBytes(field: string, max: number) {
  return (value: string, ctx: z.RefinementCtx) => {
    const size = new TextEncoder().encode(value).length;
    if (size > max) {
      ctx.addIssue({
        code: "custom",
        message: `${field} is ${size} bytes; the maximum is ${max}. Shorten it.`,
      });
    }
  };
}

export const DesignSystemText = z.string().superRefine(maxBytes("design_system", DESIGN_SYSTEM_MAX_BYTES));
export const ToneText = z.string().superRefine(maxBytes("tone", TONE_MAX_BYTES));
// An absolute path, or empty to clear it. Waggle stores the string and never opens the file.
export const PenFilePath = z
  .string()
  .max(PEN_FILE_MAX_CHARS, `pen_file is too long; the maximum is ${PEN_FILE_MAX_CHARS} characters.`)
  .refine((v) => v === "" || (v.startsWith("/") && !/[\r\n]/.test(v)), {
    message: "pen_file must be an absolute path that starts with / (or empty to clear it), on one line.",
  });

export const DesignKitFields = z.object({
  design_system: DesignSystemText,
  pen_file: PenFilePath,
  tone: ToneText,
  enabled: z.boolean(),
});

// The stored kit. updated_by is "you" for the person, else "<runtime>:<session id>".
export const DesignKit = DesignKitFields.extend({
  updated_at: z.string().nullable(),
  updated_by: z.string().nullable(),
});
export type DesignKit = z.infer<typeof DesignKit>;
export const EMPTY_DESIGN_KIT: DesignKit = {
  design_system: "",
  pen_file: "",
  tone: "",
  enabled: false,
  updated_at: null,
  updated_by: null,
};

// A change: any subset of the fields, at least one.
export const DesignKitChange = DesignKitFields.partial().strict();
export type DesignKitChange = z.infer<typeof DesignKitChange>;
export const UpdatedBy = z.string().min(1).max(UPDATED_BY_MAX_CHARS);
