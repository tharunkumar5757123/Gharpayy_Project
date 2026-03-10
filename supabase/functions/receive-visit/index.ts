import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

const validVisitTypes = ["in_person", "virtual"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    const body = await req.json();
    const {
      name,
      phone,
      email,
      property_id,
      scheduled_at,
      visit_type,
      notes,
      preferred_location,
      source,
    } = body;

    if (!name || typeof name !== "string" || name.trim().length === 0) {
      return new Response(JSON.stringify({ error: "Name is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (!phone || typeof phone !== "string" || phone.trim().length < 5) {
      return new Response(JSON.stringify({ error: "Valid phone number is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (!property_id || typeof property_id !== "string") {
      return new Response(JSON.stringify({ error: "Property is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (!scheduled_at || typeof scheduled_at !== "string") {
      return new Response(JSON.stringify({ error: "Scheduled time is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (!validVisitTypes.includes(visit_type)) {
      return new Response(JSON.stringify({ error: "Invalid visit type" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const scheduledAt = new Date(scheduled_at);
    if (isNaN(scheduledAt.getTime())) {
      return new Response(JSON.stringify({ error: "Invalid scheduled time" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (name.length > 200 || (email && email.length > 255) || phone.length > 30) {
      return new Response(JSON.stringify({ error: "Field too long" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { data: property, error: propertyError } = await supabase
      .from("properties")
      .select("id, name, area, city")
      .eq("id", property_id)
      .single();

    if (propertyError || !property) {
      return new Response(JSON.stringify({ error: "Property not found" }), {
        status: 404,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const leadSource = ["whatsapp", "website", "instagram", "facebook", "phone", "landing_page"].includes(source)
      ? source
      : "website";

    const location =
      preferred_location ||
      property.area ||
      property.city ||
      "";

    let assignedAgentId: string | null = null;
    let assignedAgentName: string | null = null;

    if (location) {
      const { data: routeData } = await supabase.rpc("route_lead_to_zone", {
        p_location: location,
      });
      const route = routeData?.[0];
      if (route?.assigned_agent_id) {
        assignedAgentId = route.assigned_agent_id;
      }
    }

    if (!assignedAgentId) {
      const { data: agents } = await supabase
        .from("agents")
        .select("id, name")
        .eq("is_active", true);

      if (agents && agents.length > 0) {
        const { data: leadCounts } = await supabase
          .from("leads")
          .select("assigned_agent_id")
          .not("status", "in", '("booked","lost")');

        const countMap: Record<string, number> = {};
        agents.forEach((a) => (countMap[a.id] = 0));
        (leadCounts || []).forEach((l) => {
          if (l.assigned_agent_id && countMap[l.assigned_agent_id] !== undefined) {
            countMap[l.assigned_agent_id]++;
          }
        });

        const sorted = agents.sort((a, b) => (countMap[a.id] || 0) - (countMap[b.id] || 0));
        assignedAgentId = sorted[0].id;
        assignedAgentName = sorted[0].name;
      }
    }

    const { data: existing } = await supabase
      .from("leads")
      .select("id, assigned_agent_id, status")
      .eq("phone", phone.trim())
      .limit(1);

    let leadId: string;
    if (existing && existing.length > 0) {
      leadId = existing[0].id;
      if (existing[0].assigned_agent_id) {
        assignedAgentId = existing[0].assigned_agent_id;
      }
      await supabase
        .from("leads")
        .update({
          property_id,
          status: "visit_scheduled",
          last_activity_at: new Date().toISOString(),
        })
        .eq("id", leadId);
    } else {
      const { data: lead, error: leadError } = await supabase
        .from("leads")
        .insert({
          name: name.trim().slice(0, 200),
          phone: phone.trim().slice(0, 30),
          email: email?.trim().slice(0, 255) || null,
          source: leadSource,
          preferred_location: preferred_location?.trim().slice(0, 200) || null,
          assigned_agent_id: assignedAgentId,
          status: "visit_scheduled",
          property_id,
        })
        .select("id, name")
        .single();
      if (leadError) throw leadError;
      leadId = lead.id;
    }

    const { data: visit, error: visitError } = await supabase
      .from("visits")
      .insert({
        lead_id: leadId,
        property_id,
        assigned_staff_id: assignedAgentId,
        scheduled_at: scheduledAt.toISOString(),
        visit_type,
        notes: notes?.toString().slice(0, 2000) || null,
      })
      .select("id")
      .single();
    if (visitError) throw visitError;

    if (assignedAgentId) {
      const { data: agent } = await supabase
        .from("agents")
        .select("user_id, name")
        .eq("id", assignedAgentId)
        .single();

      if (agent?.user_id) {
        await supabase.from("notifications").insert({
          user_id: agent.user_id,
          type: "visit_request",
          title: "New Visit Request",
          body: `${name.trim()} requested a ${visit_type === "virtual" ? "virtual tour" : "visit"} at ${property.name}`,
          link: "/visits",
        });
      }
    }

    return new Response(
      JSON.stringify({
        success: true,
        lead_id: leadId,
        visit_id: visit.id,
        assigned_agent: assignedAgentName,
      }),
      {
        status: 201,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  } catch (err) {
    return new Response(
      JSON.stringify({ error: err.message || "Internal server error" }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      }
    );
  }
});
