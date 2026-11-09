DROP INDEX IF EXISTS "claude_threads_context_idx";--> statement-breakpoint
ALTER TABLE "claude_threads" ADD COLUMN IF NOT EXISTS "context_key" text;--> statement-breakpoint
ALTER TABLE "claude_threads" ADD COLUMN IF NOT EXISTS "title" text;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "claude_threads_key_idx" ON "claude_threads" USING btree ("owner_id","context_key","updated_at");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "claude_threads_context_idx" ON "claude_threads" USING btree ("owner_id","context_kind","context_id");--> statement-breakpoint
UPDATE "claude_threads" t SET "context_key" = 'suite:' || COALESCE(a."draft"->>'tool', 'shot') FROM "suite_assists" a WHERE t."context_kind" = 'suite' AND t."context_id" = a."id" AND t."context_key" IS NULL;--> statement-breakpoint
UPDATE "claude_threads" SET "context_key" = CASE WHEN "context_kind" = 'suite' THEN 'suite:shot' ELSE "context_kind" || ':' || "context_id" END WHERE "context_key" IS NULL;
