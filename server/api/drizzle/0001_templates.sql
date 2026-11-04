CREATE TABLE "template_favourites" (
	"user_id" text NOT NULL,
	"template_id" text NOT NULL,
	"created_at" bigint NOT NULL,
	CONSTRAINT "template_favourites_user_id_template_id_pk" PRIMARY KEY("user_id","template_id")
);
--> statement-breakpoint
CREATE TABLE "templates" (
	"id" text PRIMARY KEY NOT NULL,
	"studio_id" text NOT NULL,
	"owner_id" text NOT NULL,
	"visibility" text NOT NULL,
	"name" text NOT NULL,
	"tags" jsonb NOT NULL,
	"layers" jsonb NOT NULL,
	"variation_pool" jsonb NOT NULL,
	"cover_key" text,
	"created_from_shot_id" text,
	"slug" text,
	"uses" integer DEFAULT 0 NOT NULL,
	"created_at" bigint NOT NULL,
	"updated_at" bigint NOT NULL
);
--> statement-breakpoint
ALTER TABLE "takes" ADD COLUMN "layers" jsonb;--> statement-breakpoint
ALTER TABLE "takes" ADD COLUMN "template_id" text;--> statement-breakpoint
ALTER TABLE "takes" ADD COLUMN "template_name" text;--> statement-breakpoint
ALTER TABLE "takes" ADD COLUMN "template_owner_id" text;--> statement-breakpoint
ALTER TABLE "takes" ADD COLUMN "variation" jsonb;--> statement-breakpoint
ALTER TABLE "takes" ADD COLUMN "shuffle_seed" integer;--> statement-breakpoint
ALTER TABLE "takes" ADD COLUMN "public_prompt" text;--> statement-breakpoint
ALTER TABLE "template_favourites" ADD CONSTRAINT "template_favourites_template_id_templates_id_fk" FOREIGN KEY ("template_id") REFERENCES "public"."templates"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "templates_studio_idx" ON "templates" USING btree ("studio_id","updated_at");--> statement-breakpoint
CREATE UNIQUE INDEX "templates_slug_idx" ON "templates" USING btree ("studio_id","slug");--> statement-breakpoint
CREATE INDEX "takes_template_idx" ON "takes" USING btree ("template_id","created_at");