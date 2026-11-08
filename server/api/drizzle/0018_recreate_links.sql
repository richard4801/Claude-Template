ALTER TABLE "recreate_references" ADD COLUMN IF NOT EXISTS "source_url" text;--> statement-breakpoint
ALTER TABLE "recreate_references" ADD COLUMN IF NOT EXISTS "error_code" text;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "recreate_refs_link_idx" ON "recreate_references" USING btree ("studio_id","source_url");