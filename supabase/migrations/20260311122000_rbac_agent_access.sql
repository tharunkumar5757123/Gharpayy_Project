-- Extend agent access without requiring user_roles entries
CREATE OR REPLACE FUNCTION public.is_agent_user()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT public.current_agent_id() IS NOT NULL
     OR public.has_role('agent');
$$;

-- Properties: allow agent read
DROP POLICY IF EXISTS "Owners read own properties" ON public.properties;
CREATE POLICY "Staff read properties" ON public.properties
  FOR SELECT TO authenticated
  USING (public.is_admin_or_manager() OR public.is_agent_user() OR public.is_owner_of_property(id));

-- Rooms: allow agent read
DROP POLICY IF EXISTS "Owners read rooms" ON public.rooms;
CREATE POLICY "Staff read rooms" ON public.rooms
  FOR SELECT TO authenticated
  USING (public.is_admin_or_manager() OR public.is_agent_user() OR public.is_owner_of_property(property_id));

-- Beds: allow agent read
DROP POLICY IF EXISTS "Owners read beds" ON public.beds;
CREATE POLICY "Staff read beds" ON public.beds
  FOR SELECT TO authenticated
  USING (public.is_admin_or_manager() OR public.is_agent_user() OR EXISTS (
    SELECT 1 FROM public.rooms r
    WHERE r.id = beds.room_id AND public.is_owner_of_property(r.property_id)
  ));
