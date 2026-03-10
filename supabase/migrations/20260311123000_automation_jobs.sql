-- Consolidated automation job (DB-side)
CREATE OR REPLACE FUNCTION public.run_automation_jobs()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- 1) Auto-lock stale rooms
  PERFORM public.auto_lock_stale_rooms();

  -- 2) Recalculate lead scores
  PERFORM public.recalculate_all_lead_scores();

  -- 3) Overdue notifications
  PERFORM public.create_overdue_notifications();

  -- 4) Expire stale soft locks
  UPDATE public.soft_locks
  SET is_active = false
  WHERE is_active = true
    AND expires_at < now();

  -- 5) Release beds tied to expired locks
  UPDATE public.beds b
  SET status = 'vacant'
  WHERE b.status = 'reserved'
    AND EXISTS (
      SELECT 1
      FROM public.soft_locks sl
      WHERE sl.bed_id = b.id
        AND sl.is_active = false
        AND sl.expires_at < now()
    );

  -- 6) Expire reservations
  UPDATE public.reservations
  SET reservation_status = 'expired', updated_at = now()
  WHERE reservation_status = 'pending'
    AND expires_at IS NOT NULL
    AND expires_at < now();
END;
$$;

-- Schedule via pg_cron (runs every 10 minutes)
DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS pg_cron;
  PERFORM cron.schedule('gharpayy_automation_jobs', '*/10 * * * *', $$ SELECT public.run_automation_jobs(); $$);
EXCEPTION
  WHEN others THEN
    -- pg_cron may not be enabled in all environments
    NULL;
END $$;
