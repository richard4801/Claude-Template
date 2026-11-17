-- A picture the person uploads into an outfit slot (owner 2026-11-17): which slots are uploads, and the pictures replaced.
ALTER TABLE "outfits" ADD COLUMN IF NOT EXISTS "sources" jsonb;--> statement-breakpoint
ALTER TABLE "outfits" ADD COLUMN IF NOT EXISTS "replaced" jsonb;
