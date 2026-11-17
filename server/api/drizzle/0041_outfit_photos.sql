-- An outfit made "From a photo" keeps its reference photo(s), so Redo sends the original (owner 2026-11-17).
ALTER TABLE "outfits" ADD COLUMN IF NOT EXISTS "photos" jsonb;
