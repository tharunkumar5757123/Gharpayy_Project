-- RBAC core
DO $$
BEGIN
  CREATE TYPE public.app_role AS ENUM ('admin', 'manager', 'agent', 'owner');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS public.user_roles (
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.app_role NOT NULL,
  UNIQUE (user_id, role)
);

ALTER TABLE public.user_roles ENABLE ROW LEVEL SECURITY;

-- Helper functions
CREATE OR REPLACE FUNCTION public.current_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$ SELECT auth.uid(); $$;

CREATE OR REPLACE FUNCTION public.has_role(p_role public.app_role)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = auth.uid() AND role = p_role
  );
$$;

CREATE OR REPLACE FUNCTION public.is_admin_or_manager()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.user_roles
    WHERE user_id = auth.uid() AND role IN ('admin','manager')
  );
$$;

CREATE OR REPLACE FUNCTION public.current_agent_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT id FROM public.agents WHERE user_id = auth.uid() AND is_active = true LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.current_owner_id()
RETURNS uuid
LANGUAGE sql
STABLE
AS $$
  SELECT id FROM public.owners WHERE user_id = auth.uid() AND is_active = true LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION public.is_owner_of_property(p_property_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.properties p
    JOIN public.owners o ON o.id = p.owner_id
    WHERE p.id = p_property_id AND o.user_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION public.is_assigned_agent(p_lead_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.leads l
    JOIN public.agents a ON a.id = l.assigned_agent_id
    WHERE l.id = p_lead_id AND a.user_id = auth.uid()
  );
$$;

-- USER_ROLES policies
DROP POLICY IF EXISTS "Auth manage user_roles" ON public.user_roles;
DROP POLICY IF EXISTS "Admin manage user_roles" ON public.user_roles;
CREATE POLICY "Admin manage user_roles" ON public.user_roles
  FOR ALL TO authenticated
  USING (public.has_role('admin'))
  WITH CHECK (public.has_role('admin'));

-- AGENTS
DROP POLICY IF EXISTS "Auth users read agents" ON public.agents;
DROP POLICY IF EXISTS "Auth users manage agents" ON public.agents;
DROP POLICY IF EXISTS "Auth users update agents" ON public.agents;
DROP POLICY IF EXISTS "Auth users delete agents" ON public.agents;
CREATE POLICY "Agents read own" ON public.agents
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.is_admin_or_manager());
CREATE POLICY "Admin manage agents" ON public.agents
  FOR ALL TO authenticated
  USING (public.is_admin_or_manager())
  WITH CHECK (public.is_admin_or_manager());

-- OWNERS
DROP POLICY IF EXISTS "Anon read owners" ON public.owners;
DROP POLICY IF EXISTS "Auth users manage owners" ON public.owners;
DROP POLICY IF EXISTS "Auth users update owners" ON public.owners;
DROP POLICY IF EXISTS "Auth users delete owners" ON public.owners;
CREATE POLICY "Owners read own" ON public.owners
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.is_admin_or_manager());
CREATE POLICY "Owners create self" ON public.owners
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());
CREATE POLICY "Owners update own" ON public.owners
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid() OR public.is_admin_or_manager())
  WITH CHECK (user_id = auth.uid() OR public.is_admin_or_manager());
CREATE POLICY "Admin delete owners" ON public.owners
  FOR DELETE TO authenticated
  USING (public.is_admin_or_manager());

-- PROPERTIES
DROP POLICY IF EXISTS "Auth users read properties" ON public.properties;
DROP POLICY IF EXISTS "Auth users manage properties" ON public.properties;
DROP POLICY IF EXISTS "Auth users update properties" ON public.properties;
DROP POLICY IF EXISTS "Auth users delete properties" ON public.properties;
DROP POLICY IF EXISTS "Anon read properties" ON public.properties;
CREATE POLICY "Public read active properties" ON public.properties
  FOR SELECT TO anon
  USING (is_active = true);
CREATE POLICY "Owners read own properties" ON public.properties
  FOR SELECT TO authenticated
  USING (public.is_admin_or_manager() OR public.is_owner_of_property(id));
CREATE POLICY "Owners update own properties" ON public.properties
  FOR UPDATE TO authenticated
  USING (public.is_admin_or_manager() OR public.is_owner_of_property(id))
  WITH CHECK (public.is_admin_or_manager() OR public.is_owner_of_property(id));
CREATE POLICY "Admin manage properties" ON public.properties
  FOR INSERT TO authenticated
  WITH CHECK (public.is_admin_or_manager());
CREATE POLICY "Admin delete properties" ON public.properties
  FOR DELETE TO authenticated
  USING (public.is_admin_or_manager());

-- ROOMS
DROP POLICY IF EXISTS "Anon read rooms" ON public.rooms;
DROP POLICY IF EXISTS "Auth users manage rooms" ON public.rooms;
DROP POLICY IF EXISTS "Auth users update rooms" ON public.rooms;
DROP POLICY IF EXISTS "Auth users delete rooms" ON public.rooms;
CREATE POLICY "Public read rooms" ON public.rooms
  FOR SELECT TO anon
  USING (EXISTS (
    SELECT 1 FROM public.properties p
    WHERE p.id = rooms.property_id AND p.is_active = true
  ));
CREATE POLICY "Owners read rooms" ON public.rooms
  FOR SELECT TO authenticated
  USING (public.is_admin_or_manager() OR public.is_owner_of_property(property_id));
CREATE POLICY "Owners update rooms" ON public.rooms
  FOR UPDATE TO authenticated
  USING (public.is_admin_or_manager() OR public.is_owner_of_property(property_id))
  WITH CHECK (public.is_admin_or_manager() OR public.is_owner_of_property(property_id));
CREATE POLICY "Admin insert rooms" ON public.rooms
  FOR INSERT TO authenticated
  WITH CHECK (public.is_admin_or_manager());
CREATE POLICY "Admin delete rooms" ON public.rooms
  FOR DELETE TO authenticated
  USING (public.is_admin_or_manager());

-- BEDS
DROP POLICY IF EXISTS "Anon read beds" ON public.beds;
DROP POLICY IF EXISTS "Auth users manage beds" ON public.beds;
DROP POLICY IF EXISTS "Auth users update beds" ON public.beds;
DROP POLICY IF EXISTS "Auth users delete beds" ON public.beds;
CREATE POLICY "Public read beds" ON public.beds
  FOR SELECT TO anon
  USING (EXISTS (
    SELECT 1
    FROM public.rooms r
    JOIN public.properties p ON p.id = r.property_id
    WHERE r.id = beds.room_id AND p.is_active = true
  ));
CREATE POLICY "Owners read beds" ON public.beds
  FOR SELECT TO authenticated
  USING (public.is_admin_or_manager() OR EXISTS (
    SELECT 1 FROM public.rooms r
    WHERE r.id = beds.room_id AND public.is_owner_of_property(r.property_id)
  ));
CREATE POLICY "Owners update beds" ON public.beds
  FOR UPDATE TO authenticated
  USING (public.is_admin_or_manager() OR EXISTS (
    SELECT 1 FROM public.rooms r
    WHERE r.id = beds.room_id AND public.is_owner_of_property(r.property_id)
  ))
  WITH CHECK (public.is_admin_or_manager() OR EXISTS (
    SELECT 1 FROM public.rooms r
    WHERE r.id = beds.room_id AND public.is_owner_of_property(r.property_id)
  ));
CREATE POLICY "Admin insert beds" ON public.beds
  FOR INSERT TO authenticated
  WITH CHECK (public.is_admin_or_manager());
CREATE POLICY "Admin delete beds" ON public.beds
  FOR DELETE TO authenticated
  USING (public.is_admin_or_manager());

-- LEADS
DROP POLICY IF EXISTS "Auth users read leads" ON public.leads;
DROP POLICY IF EXISTS "Auth users manage leads" ON public.leads;
DROP POLICY IF EXISTS "Auth users update leads" ON public.leads;
DROP POLICY IF EXISTS "Auth users delete leads" ON public.leads;
CREATE POLICY "Agents read assigned leads" ON public.leads
  FOR SELECT TO authenticated
  USING (
    public.is_admin_or_manager()
    OR public.is_assigned_agent(id)
  );
CREATE POLICY "Agents insert leads" ON public.leads
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_admin_or_manager()
    OR assigned_agent_id IS NULL
    OR assigned_agent_id = public.current_agent_id()
  );
CREATE POLICY "Agents update leads" ON public.leads
  FOR UPDATE TO authenticated
  USING (
    public.is_admin_or_manager()
    OR public.is_assigned_agent(id)
  )
  WITH CHECK (
    public.is_admin_or_manager()
    OR public.is_assigned_agent(id)
  );
CREATE POLICY "Admin delete leads" ON public.leads
  FOR DELETE TO authenticated
  USING (public.is_admin_or_manager());

-- VISITS
DROP POLICY IF EXISTS "Auth users read visits" ON public.visits;
DROP POLICY IF EXISTS "Auth users manage visits" ON public.visits;
DROP POLICY IF EXISTS "Auth users update visits" ON public.visits;
DROP POLICY IF EXISTS "Auth users delete visits" ON public.visits;
CREATE POLICY "Agents read visits" ON public.visits
  FOR SELECT TO authenticated
  USING (
    public.is_admin_or_manager()
    OR assigned_staff_id = public.current_agent_id()
    OR public.is_assigned_agent(lead_id)
  );
CREATE POLICY "Agents insert visits" ON public.visits
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_admin_or_manager()
    OR assigned_staff_id = public.current_agent_id()
    OR public.is_assigned_agent(lead_id)
  );
CREATE POLICY "Agents update visits" ON public.visits
  FOR UPDATE TO authenticated
  USING (
    public.is_admin_or_manager()
    OR assigned_staff_id = public.current_agent_id()
    OR public.is_assigned_agent(lead_id)
  )
  WITH CHECK (
    public.is_admin_or_manager()
    OR assigned_staff_id = public.current_agent_id()
    OR public.is_assigned_agent(lead_id)
  );
CREATE POLICY "Admin delete visits" ON public.visits
  FOR DELETE TO authenticated
  USING (public.is_admin_or_manager());

-- CONVERSATIONS
DROP POLICY IF EXISTS "Auth users read conversations" ON public.conversations;
DROP POLICY IF EXISTS "Auth users manage conversations" ON public.conversations;
CREATE POLICY "Agents read conversations" ON public.conversations
  FOR SELECT TO authenticated
  USING (
    public.is_admin_or_manager()
    OR public.is_assigned_agent(lead_id)
  );
CREATE POLICY "Agents insert conversations" ON public.conversations
  FOR INSERT TO authenticated
  WITH CHECK (
    public.is_admin_or_manager()
    OR public.is_assigned_agent(lead_id)
  );

-- BOOKINGS
CREATE POLICY "Agents read bookings" ON public.bookings
  FOR SELECT TO authenticated
  USING (
    public.is_admin_or_manager()
    OR public.is_assigned_agent(lead_id)
    OR public.is_owner_of_property(property_id)
  );
CREATE POLICY "Admin manage bookings" ON public.bookings
  FOR ALL TO authenticated
  USING (public.is_admin_or_manager())
  WITH CHECK (public.is_admin_or_manager());

-- RESERVATIONS
CREATE POLICY "Admin read reservations" ON public.reservations
  FOR SELECT TO authenticated
  USING (public.is_admin_or_manager());
CREATE POLICY "Admin manage reservations" ON public.reservations
  FOR UPDATE TO authenticated
  USING (public.is_admin_or_manager())
  WITH CHECK (public.is_admin_or_manager());

-- FOLLOW UPS
DROP POLICY IF EXISTS "Auth users read reminders" ON public.follow_up_reminders;
DROP POLICY IF EXISTS "Auth users manage reminders" ON public.follow_up_reminders;
DROP POLICY IF EXISTS "Auth users update reminders" ON public.follow_up_reminders;
CREATE POLICY "Agents read reminders" ON public.follow_up_reminders
  FOR SELECT TO authenticated
  USING (public.is_admin_or_manager() OR public.is_assigned_agent(lead_id));
CREATE POLICY "Agents manage reminders" ON public.follow_up_reminders
  FOR INSERT TO authenticated
  WITH CHECK (public.is_admin_or_manager() OR public.is_assigned_agent(lead_id));
CREATE POLICY "Agents update reminders" ON public.follow_up_reminders
  FOR UPDATE TO authenticated
  USING (public.is_admin_or_manager() OR public.is_assigned_agent(lead_id))
  WITH CHECK (public.is_admin_or_manager() OR public.is_assigned_agent(lead_id));

-- NOTIFICATIONS
DROP POLICY IF EXISTS "Auth users read notifications" ON public.notifications;
DROP POLICY IF EXISTS "Auth users update notifications" ON public.notifications;
CREATE POLICY "Users read own notifications" ON public.notifications
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.is_admin_or_manager());
CREATE POLICY "Users update own notifications" ON public.notifications
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid() OR public.is_admin_or_manager())
  WITH CHECK (user_id = auth.uid() OR public.is_admin_or_manager());

-- ACTIVITY LOG
CREATE POLICY "Agents read activity" ON public.activity_log
  FOR SELECT TO authenticated
  USING (public.is_admin_or_manager() OR public.is_assigned_agent(lead_id));
CREATE POLICY "Admin insert activity" ON public.activity_log
  FOR INSERT TO authenticated
  WITH CHECK (public.is_admin_or_manager());

-- ZONES / TEAM_QUEUES / HANDOFFS / ESCALATIONS (admin only)
CREATE POLICY "Admin manage zones" ON public.zones
  FOR ALL TO authenticated
  USING (public.is_admin_or_manager())
  WITH CHECK (public.is_admin_or_manager());
CREATE POLICY "Admin manage team_queues" ON public.team_queues
  FOR ALL TO authenticated
  USING (public.is_admin_or_manager())
  WITH CHECK (public.is_admin_or_manager());
CREATE POLICY "Admin manage handoffs" ON public.handoffs
  FOR ALL TO authenticated
  USING (public.is_admin_or_manager())
  WITH CHECK (public.is_admin_or_manager());
CREATE POLICY "Admin manage escalations" ON public.escalations
  FOR ALL TO authenticated
  USING (public.is_admin_or_manager())
  WITH CHECK (public.is_admin_or_manager());

-- SOFT LOCKS
CREATE POLICY "Admin manage soft_locks" ON public.soft_locks
  FOR ALL TO authenticated
  USING (public.is_admin_or_manager())
  WITH CHECK (public.is_admin_or_manager());
