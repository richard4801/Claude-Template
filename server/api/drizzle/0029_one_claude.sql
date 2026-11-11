ALTER TABLE "claude_threads" ADD COLUMN IF NOT EXISTS "page" jsonb;--> statement-breakpoint
ALTER TABLE "claude_threads" ADD COLUMN IF NOT EXISTS "model" text;--> statement-breakpoint
ALTER TABLE "claude_threads" ADD COLUMN IF NOT EXISTS "archived_at" bigint;--> statement-breakpoint
ALTER TABLE "playbook_rules" ADD COLUMN IF NOT EXISTS "character_id" text;--> statement-breakpoint
ALTER TABLE "playbook_rules" ADD COLUMN IF NOT EXISTS "user_id" text;