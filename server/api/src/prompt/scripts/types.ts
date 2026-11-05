// Prompt scripts (plans/prompt-scripts.md): every prompt the server sends to a model is assembled by a script.
//   inputs  — typed facts about the job (is the performer speaking? which audio is sent? presets on? …)
//   rules   — conditions on those inputs that choose blocks (owner-editable in a structured form, never free code)
//   blocks  — owner-editable texts with {placeholders}: the prompt library entries (library.ts), by key
// Assembly is deterministic and needs no AI call. System sections and the user's own words are kept apart: a script
// has `system` sections and at most one `user` section; only a user section sees the user's (sanitised) text.

export type InputType = 'bool' | 'enum' | 'number' | 'text' | 'list';
export type Scalar = boolean | number | string | null;
/** A list input holds items (objects of scalars or string lists), e.g. the reference images sent: { index, guides }. */
export type Item = Record<string, Scalar | string[]>;
export type InputValue = Scalar | string[] | Item[];
export type Inputs = Record<string, InputValue | undefined>;

export type InputDef = {
  name: string; label: string; description: string; type: InputType;
  /** enum: the allowed values. list of strings: the allowed members (for `has`). */
  options?: { id: string; label: string }[];
  /** list of items: the fields each item has (conditions inside an `each` section use "item.<field>"). */
  fields?: InputDef[];
  /** The value the editor's preview uses. */
  sample: InputValue;
};

export type CondOp = 'is' | 'isNot' | 'in' | 'notIn' | 'atLeast' | 'atMost' | 'has' | 'hasNot' | 'empty' | 'notEmpty';
export const COND_OPS: { id: CondOp; label: string; types: InputType[] }[] = [
  { id: 'is', label: 'is', types: ['bool', 'enum', 'number', 'text'] },
  { id: 'isNot', label: 'is not', types: ['bool', 'enum', 'number', 'text'] },
  { id: 'in', label: 'is one of', types: ['enum'] },
  { id: 'notIn', label: 'is none of', types: ['enum'] },
  { id: 'atLeast', label: 'is at least', types: ['number'] },
  { id: 'atMost', label: 'is at most', types: ['number'] },
  { id: 'has', label: 'includes', types: ['list'] },
  { id: 'hasNot', label: 'does not include', types: ['list'] },
  { id: 'empty', label: 'is empty', types: ['text', 'list'] },
  { id: 'notEmpty', label: 'is not empty', types: ['text', 'list'] },
];
/** One condition. All conditions of a rule must hold. */
export type Cond = { input: string; op: CondOp; value?: Scalar | string[] };

/**
 * A rule puts one block somewhere when its conditions hold.
 * `target` = a section id, or "@name" = the value of placeholder {name} in the other blocks (first matching rule wins).
 */
export type Rule = {
  id: string; label: string; target: string; when: Cond[]; block: string;
  /** Removed when the Presets switch is off (the optional system style blocks). */
  optional?: boolean;
  /** Owner may not switch it off or change its conditions/target (identity, safety, the user section). The block text stays editable. */
  locked?: boolean;
  /** false = switched off by the owner. Default true. */
  enabled?: boolean;
};

export type Section = {
  id: string; label: string; kind: 'system' | 'user';
  /** 'first': the first matching rule only; 'all': every matching rule, joined with `join`. */
  pick: 'first' | 'all';
  join?: string;
  /** "sections" format: the heading line ("summary:"). A section without a heading continues the previous one. */
  heading?: string;
  /** The slot layer the apps see (photo prompts). Default: the section id. */
  layer?: string;
  /** Repeat the section once per item of this list input (one slot each); "item.<field>" in conditions, item fields as placeholders. */
  each?: string;
  /** Placeholder → value name for this section's blocks, when two blocks use the same placeholder name for different values. */
  alias?: Record<string, string>;
};
/** A placeholder whose value is chosen by rules (target "@name"). `prefix` is put before a non-empty value. */
export type ValueSlot = { name: string; label: string; prefix?: string };

export type ScriptGroup = string;
export type Script = {
  id: string; group: ScriptGroup; title: string; description: string;
  /** 'lines': one line per section part. 'sections': "heading:\nbody" blocks separated by a blank line (the video models' format). */
  format: 'lines' | 'sections';
  inputs: InputDef[]; sections: Section[]; values?: ValueSlot[]; rules: Rule[];
  /** Placeholder values the code supplies (documentation and preview only; the runner takes whatever it is given). */
  vars?: { name: string; description: string; sample: string }[];
  /** Library keys the owner may pick in this script's rules (default: every block its default rules use). */
  blocks?: string[];
};

export type ScriptPart = { section: string; layer: string; kind: 'system' | 'user'; text: string; rules: string[] };
export type ScriptResult = {
  script: string; parts: ScriptPart[]; text: string;
  /** Rule ids that matched (in order), for the editor's preview and tests. */
  fired: string[];
  /** Clauses the direction sanitiser dropped (filled by the builders that sanitise). */
  removed: string[];
};
