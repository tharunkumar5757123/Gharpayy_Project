DO $$
BEGIN
  CREATE TYPE public.visit_type AS ENUM ('in_person', 'virtual');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

ALTER TABLE public.visits
  ADD COLUMN IF NOT EXISTS visit_type public.visit_type NOT NULL DEFAULT 'in_person';

CREATE INDEX IF NOT EXISTS idx_visits_type ON public.visits(visit_type);
