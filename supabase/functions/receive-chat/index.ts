import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

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
      lead_id,
      name,
      phone,
      email,
      property_id,
      message,
      source,
    } = body;

    if (!message || typeof message !== "string" || message.trim().length === 0) {
      return new Response(JSON.stringify({ error: "Message is required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    let leadId = lead_id as string | undefined;

    if (!leadId) {
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

      const { data: existing } = await supabase
        .from("leads")
        .select("id, assigned_agent_id")
        .eq("phone", phone.trim())
        .limit(1);

      if (existing && existing.length > 0) {
        leadId = existing[0].id;
      } else {
        const leadSource = ["whatsapp", "website", "instagram", "facebook", "phone", "landing_page"].includes(source)
          ? source
          : "website";

        let assignedAgentId: string | null = null;
        if (property_id) {
          const { data: prop } = await supabase
            .from("properties")
            .select("area, city")
            .eq("id", property_id)
            .single();
          const location = prop?.area || prop?.city || "";
          if (location) {
            const { data: routeData } = await supabase.rpc("route_lead_to_zone", {
              p_location: location,
            });
            const route = routeData?.[0];
            if (route?.assigned_agent_id) {
              assignedAgentId = route.assigned_agent_id;
            }
          }
        }

        const { data: lead, error: leadError } = await supabase
          .from("leads")
          .insert({
            name: name.trim().slice(0, 200),
            phone: phone.trim().slice(0, 30),
            email: email?.trim().slice(0, 255) || null,
            source: leadSource,
            status: "contacted",
            property_id: property_id || null,
            assigned_agent_id: assignedAgentId,
          })
          .select("id, name")
          .single();
        if (leadError) throw leadError;
        leadId = lead.id;
      }
    }

    const { error: convoError } = await supabase
      .from("conversations")
      .insert({
        lead_id: leadId!,
        message: message.trim().slice(0, 2000),
        direction: "inbound",
        channel: "web",
        context_type: property_id ? "property" : "lead",
        context_id: property_id || null,
      });
    if (convoError) throw convoError;

    return new Response(
      JSON.stringify({ success: true, lead_id: leadId }),
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
