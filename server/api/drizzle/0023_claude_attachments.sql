ALTER TABLE "claude_messages" ADD COLUMN IF NOT EXISTS "attachments" jsonb;--> statement-breakpoint
ALTER TABLE "claude_turns" ADD COLUMN IF NOT EXISTS "attachments" jsonb;