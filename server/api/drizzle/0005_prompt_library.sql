CREATE TABLE "prompt_overrides" (
	"studio_id" text NOT NULL,
	"key" text NOT NULL,
	"text" text NOT NULL,
	"updated_by" text,
	"updated_at" bigint NOT NULL,
	CONSTRAINT "prompt_overrides_studio_id_key_pk" PRIMARY KEY("studio_id","key")
);
--> statement-breakpoint
ALTER TABLE "takes" ADD COLUMN "refs" jsonb;