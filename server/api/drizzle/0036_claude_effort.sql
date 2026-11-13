ALTER TABLE "claude_threads" ADD COLUMN IF NOT EXISTS "effort" text;--> statement-breakpoint
ALTER TABLE "claude_prefs" ADD COLUMN IF NOT EXISTS "default_effort" text;