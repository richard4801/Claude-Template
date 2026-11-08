CREATE TABLE IF NOT EXISTS "byo_models" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"provider_id" text NOT NULL,
	"ref" text NOT NULL,
	"version" text,
	"provider_name" text NOT NULL,
	"display_name" text NOT NULL,
	"kind" text,
	"enabled" boolean DEFAULT false NOT NULL,
	"members" boolean DEFAULT false NOT NULL,
	"analysis" jsonb NOT NULL,
	"fixed_inputs" jsonb DEFAULT '{}'::jsonb NOT NULL,
	"price" jsonb,
	"price_scale" double precision DEFAULT 1 NOT NULL,
	"created_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS "byo_providers" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"kind" text NOT NULL,
	"label" text NOT NULL,
	"key_enc" text NOT NULL,
	"key_last4" text NOT NULL,
	"status" text DEFAULT 'ok' NOT NULL,
	"checked_at" bigint,
	"created_by" text,
	"created_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "byo_models_studio_idx" ON "byo_models" USING btree ("studio_id");--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS "byo_models_provider_ref_idx" ON "byo_models" USING btree ("provider_id","ref");--> statement-breakpoint
CREATE INDEX IF NOT EXISTS "byo_providers_studio_idx" ON "byo_providers" USING btree ("studio_id");