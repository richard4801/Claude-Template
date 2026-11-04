CREATE TABLE "topups" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"amount_usd" double precision NOT NULL,
	"note" text,
	"paid_at" bigint NOT NULL,
	"created_by" text,
	"created_at" bigint NOT NULL
);
--> statement-breakpoint
ALTER TABLE "outfits" ADD COLUMN "cost" double precision;--> statement-breakpoint
ALTER TABLE "studio_settings" ADD COLUMN "balance_since" bigint;--> statement-breakpoint
CREATE INDEX "topups_studio_idx" ON "topups" USING btree ("studio_id","created_at");--> statement-breakpoint
-- App clean-up (2026-11-04): existing studios start their owner-loaded ledger now, at $0 (earlier spending was paid from RunPod).
UPDATE "studio_settings" SET "balance_since" = (extract(epoch from now()) * 1000)::bigint WHERE "balance_since" IS NULL;
