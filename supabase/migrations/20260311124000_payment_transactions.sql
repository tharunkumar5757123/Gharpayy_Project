-- Payment transactions
CREATE TABLE IF NOT EXISTS public.payment_transactions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id uuid REFERENCES public.reservations(id) ON DELETE SET NULL,
  amount numeric NOT NULL,
  gateway_transaction_id text,
  status text NOT NULL DEFAULT 'pending',
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.payment_transactions ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admin manage payment_transactions" ON public.payment_transactions
  FOR ALL TO authenticated
  USING (public.is_admin_or_manager())
  WITH CHECK (public.is_admin_or_manager());

-- Update confirm_reservation to log payment
CREATE OR REPLACE FUNCTION public.confirm_reservation(
  p_reservation_id uuid,
  p_payment_reference text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_res reservations%ROWTYPE;
  v_lead_id uuid;
BEGIN
  SELECT * INTO v_res FROM reservations WHERE id = p_reservation_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'Reservation not found'); END IF;
  IF v_res.reservation_status != 'pending' THEN RETURN jsonb_build_object('error', 'Reservation already processed'); END IF;

  -- Update reservation
  UPDATE reservations SET reservation_status = 'paid', payment_reference = p_payment_reference, updated_at = now() WHERE id = p_reservation_id;

  -- Create CRM lead
  INSERT INTO leads (name, phone, email, source, status, property_id, preferred_location, notes)
  VALUES (v_res.customer_name, v_res.customer_phone, v_res.customer_email, 'website', 'booked', v_res.property_id,
    (SELECT area FROM properties WHERE id = v_res.property_id),
    'Online reservation #' || p_reservation_id::text || ' | Payment: ' || p_payment_reference)
  RETURNING id INTO v_lead_id;

  -- Update reservation with lead
  UPDATE reservations SET lead_id = v_lead_id WHERE id = p_reservation_id;

  -- Create booking
  INSERT INTO bookings (lead_id, property_id, room_id, bed_id, booking_status, monthly_rent, move_in_date, payment_status, notes)
  VALUES (v_lead_id, v_res.property_id, v_res.room_id, v_res.bed_id, 'confirmed', v_res.monthly_rent, v_res.move_in_date, 'partial', 'Online reservation fee paid');

  -- Log payment transaction
  INSERT INTO payment_transactions (reservation_id, amount, gateway_transaction_id, status)
  VALUES (p_reservation_id, COALESCE(v_res.reservation_fee, 1000), p_payment_reference, 'paid');

  -- Update bed to booked
  IF v_res.bed_id IS NOT NULL THEN
    UPDATE beds SET status = 'booked' WHERE id = v_res.bed_id;
  END IF;

  -- Deactivate soft lock
  IF v_res.soft_lock_id IS NOT NULL THEN
    UPDATE soft_locks SET is_active = false WHERE id = v_res.soft_lock_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'lead_id', v_lead_id, 'reservation_id', p_reservation_id);
END;
$$;
