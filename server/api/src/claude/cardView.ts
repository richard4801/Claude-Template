// What the apps see of a stored chat line: a card's server-only part (the undo before-values, ui.full) stays here.
export function appTool<T extends object>(tool: T): T {
  const ui = (tool as { ui?: Record<string, unknown> }).ui;
  if (!ui || !('full' in ui)) return tool;
  const { full: _f, ...rest } = ui;
  return { ...tool, ui: rest };
}
