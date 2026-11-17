-- Her world, phase 1 (plans/model-world.md §1): a place can belong to one character, with an @tag, a description and up
-- to 8 photos (one the cover). Studio places (model_id null) stay shared. The old single image becomes images[0].
ALTER TABLE "suite_locations" ADD COLUMN IF NOT EXISTS "model_id" text;--> statement-breakpoint
ALTER TABLE "suite_locations" ADD COLUMN IF NOT EXISTS "tag" text;--> statement-breakpoint
ALTER TABLE "suite_locations" ADD COLUMN IF NOT EXISTS "description" text DEFAULT '' NOT NULL;--> statement-breakpoint
ALTER TABLE "suite_locations" ADD COLUMN IF NOT EXISTS "images" jsonb DEFAULT '[]'::jsonb NOT NULL;--> statement-breakpoint
ALTER TABLE "suite_locations" ADD COLUMN IF NOT EXISTS "cover" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "suite_locations" ADD COLUMN IF NOT EXISTS "updated_at" bigint;--> statement-breakpoint
UPDATE "suite_locations" SET "images" = jsonb_build_array("image" || '{"source":"upload"}'::jsonb) WHERE "images" = '[]'::jsonb;--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "suite_locations_model_idx" ON "suite_locations" USING btree ("studio_id","model_id");
