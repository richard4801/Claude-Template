CREATE TABLE IF NOT EXISTS "studio_seeds" (
	"studio_id" text NOT NULL,
	"kind" text NOT NULL,
	"slug" text NOT NULL,
	"seeded_at" bigint NOT NULL,
	CONSTRAINT "studio_seeds_studio_id_kind_slug_pk" PRIMARY KEY("studio_id","kind","slug")
);
