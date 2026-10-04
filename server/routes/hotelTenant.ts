import type { Request, RequestHandler } from "express";

export type ResolvedHotelTenant = {
  organizationId: string;
  domain: string;
  name: string;
  logoUrl: string | null;
  primaryColor: string | null;
  accentColor: string | null;
};

type TenantRow = {
  organization_id: string;
  name: string;
  domain: string;
  logo_url: string | null;
  primary_color: string | null;
  accent_color: string | null;
};

const configuration = () => {
  const supabaseUrl = process.env.VITE_SUPABASE_URL;
  const supabaseAnonKey = process.env.VITE_SUPABASE_ANON_KEY;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !supabaseAnonKey || !serviceRoleKey) {
    throw new Error("Hotel tenant database configuration is incomplete");
  }
  return { supabaseUrl: supabaseUrl.replace(/\/$/, ""), supabaseAnonKey, serviceRoleKey };
};

const serviceHeaders = (json = false) => {
  const { supabaseAnonKey, serviceRoleKey } = configuration();
  return {
    apikey: supabaseAnonKey,
    Authorization: `Bearer ${serviceRoleKey}`,
    ...(json ? { "content-type": "application/json" } : {}),
  };
};

const hostnameFromRequest = (request: Request) => request.hostname.toLowerCase().replace(/\.$/, "");

export const resolveRequestHotelTenant = async (request: Request): Promise<ResolvedHotelTenant> => {
  const hostname = hostnameFromRequest(request);
  if (!hostname) throw new Error("Hotel domain is missing");

  const { supabaseUrl } = configuration();
  const tenantResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/resolve_hotel_tenant`, {
    method: "POST",
    headers: serviceHeaders(true),
    body: JSON.stringify({ target_hostname: hostname }),
    signal: AbortSignal.timeout(10_000),
  });
  const payload = await tenantResponse.json().catch(() => null) as TenantRow[] | TenantRow | null;
  const tenants = Array.isArray(payload) ? payload : payload ? [payload] : [];
  if (!tenantResponse.ok || tenants.length !== 1) throw new Error("This hotel domain is not configured");
  const tenant = tenants[0];

  return {
    organizationId: tenant.organization_id,
    domain: tenant.domain,
    name: tenant.name,
    logoUrl: tenant.logo_url,
    primaryColor: tenant.primary_color,
    accentColor: tenant.accent_color,
  };
};

const setPrivateTenantResponse = (response: { setHeader: (name: string, value: string) => unknown }) => response.setHeader("Cache-Control", "private, no-store");

const readService = async <T>(path: string): Promise<T> => {
  const { supabaseUrl } = configuration();
  const response = await fetch(`${supabaseUrl}/rest/v1/${path}`, {
    headers: serviceHeaders(),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error("Hotel information could not be loaded");
  return response.json() as Promise<T>;
};

const callTenantRpc = async <T>(name: string, args: Record<string, unknown>): Promise<T> => {
  const { supabaseUrl } = configuration();
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: serviceHeaders(true),
    body: JSON.stringify(args),
    signal: AbortSignal.timeout(10_000),
  });
  const payload = await response.json().catch(() => null) as T | { message?: string } | null;
  if (!response.ok) {
    throw new Error(payload && typeof payload === "object" && "message" in payload && typeof payload.message === "string"
      ? payload.message
      : "Hotel information could not be loaded");
  }
  return payload as T;
};

const getAuthenticatedUserId = async (authorization: string | undefined) => {
  if (!authorization?.startsWith("Bearer ")) throw new Error("Authentication is required");
  const { supabaseUrl, supabaseAnonKey } = configuration();
  const response = await fetch(`${supabaseUrl}/auth/v1/user`, {
    headers: { apikey: supabaseAnonKey, Authorization: authorization },
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error("Your sign-in session has expired");
  const user = await response.json() as { id?: string };
  if (!user.id) throw new Error("Your sign-in session could not be verified");
  return user.id;
};

const isUuid = (value: unknown): value is string => typeof value === "string"
  && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);

export const submitHotelEventProposal: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const userId = await getAuthenticatedUserId(request.headers.authorization);
    const input = request.body as Record<string, unknown>;
    const planId = input.target_plan_id;
    if (planId !== null && planId !== undefined && !isUuid(planId)) {
      response.status(400).json({ error: "Event proposal is invalid" });
      return;
    }
    const result = await callTenantRpc<string>("submit_special_event_proposal_for_tenant", {
      target_organization_id: tenant.organizationId,
      target_user_id: userId,
      target_plan_id: planId ?? null,
      proposal_title: input.proposal_title,
      proposal_description: input.proposal_description ?? null,
      proposal_category: input.proposal_category,
      proposal_starts_at: input.proposal_starts_at,
      proposal_ends_at: input.proposal_ends_at,
      proposal_timezone: input.proposal_timezone,
      proposal_facility_id: input.proposal_facility_id,
      proposal_expected_guests: input.proposal_expected_guests,
      proposal_contact_name: input.proposal_contact_name,
      proposal_contact_email: input.proposal_contact_email,
      proposal_contact_phone: input.proposal_contact_phone ?? null,
      proposal_image_url: input.proposal_image_url ?? null,
      proposal_is_private: input.proposal_is_private,
      proposal_entry_type: input.proposal_entry_type,
      proposal_entry_fee: input.proposal_entry_fee,
      proposal_share_manager_operations: input.proposal_share_manager_operations ?? false,
    });
    response.json({ planId: result });
  } catch (error) {
    response.status(400).json({ error: error instanceof Error ? error.message : "Unable to submit event proposal" });
  }
};

export const reviewHotelEventProposal: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const userId = await getAuthenticatedUserId(request.headers.authorization);
    const input = request.body as { planId?: unknown; action?: unknown; suggestedValues?: unknown; reviewMessage?: unknown };
    if (!isUuid(input.planId) || !["approve", "decline", "suggest_changes"].includes(String(input.action))) {
      response.status(400).json({ error: "Event review details are invalid" });
      return;
    }
    await callTenantRpc("review_special_event_proposal_for_tenant", {
      target_organization_id: tenant.organizationId,
      target_user_id: userId,
      target_plan_id: input.planId,
      review_action: input.action,
      suggested_values: input.suggestedValues ?? null,
      review_message: input.reviewMessage ?? null,
    });
    response.json({ success: true });
  } catch (error) {
    response.status(400).json({ error: error instanceof Error ? error.message : "Unable to review event proposal" });
  }
};

export const respondHotelEventProposal: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const userId = await getAuthenticatedUserId(request.headers.authorization);
    const { planId, acceptSuggestions } = request.body as { planId?: unknown; acceptSuggestions?: unknown };
    if (!isUuid(planId) || typeof acceptSuggestions !== "boolean") {
      response.status(400).json({ error: "Event response details are invalid" });
      return;
    }
    await callTenantRpc("respond_to_special_event_proposal_for_tenant", {
      target_organization_id: tenant.organizationId,
      target_user_id: userId,
      target_plan_id: planId,
      accept_suggestions: acceptSuggestions,
    });
    response.json({ success: true });
  } catch (error) {
    response.status(400).json({ error: error instanceof Error ? error.message : "Unable to respond to event proposal" });
  }
};

export const publishHotelEventProposal: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const userId = await getAuthenticatedUserId(request.headers.authorization);
    const { planId } = request.body as { planId?: unknown };
    if (!isUuid(planId)) {
      response.status(400).json({ error: "Event proposal is invalid" });
      return;
    }
    await callTenantRpc("publish_special_event_proposal_for_tenant", {
      target_organization_id: tenant.organizationId,
      target_user_id: userId,
      target_plan_id: planId,
    });
    response.json({ success: true });
  } catch (error) {
    response.status(400).json({ error: error instanceof Error ? error.message : "Unable to publish event proposal" });
  }
};

export const submitHotelComplaint: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const input = request.body as Record<string, unknown>;
    const requiredText = (value: unknown, maximumLength: number) => typeof value === "string"
      && value.trim().length > 0 && value.trim().length <= maximumLength;
    if (!requiredText(input.guestName, 160) || !requiredText(input.email, 320)
      || !requiredText(input.roomNumber, 64) || !requiredText(input.complaintType, 120)
      || !requiredText(input.description, 5000)
      || !["low", "medium", "high", "urgent"].includes(String(input.priority))) {
      response.status(400).json({ error: "Complete the required complaint details" });
      return;
    }
    const userId = request.headers.authorization
      ? await getAuthenticatedUserId(request.headers.authorization)
      : null;
    const { supabaseUrl, supabaseAnonKey, serviceRoleKey } = configuration();
    const insertResponse = await fetch(`${supabaseUrl}/rest/v1/complaints?select=id`, {
      method: "POST",
      headers: {
        apikey: supabaseAnonKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        "content-type": "application/json",
        Prefer: "return=representation",
      },
      body: JSON.stringify({
        user_id: userId,
        organization_id: tenant.organizationId,
        guest_name: String(input.guestName).trim(),
        email: String(input.email).trim().toLowerCase(),
        room_number: String(input.roomNumber).trim(),
        complaint_type: String(input.complaintType).trim(),
        description: String(input.description).trim(),
        priority: input.priority,
        status: "open",
        attachments: [],
      }),
      signal: AbortSignal.timeout(10_000),
    });
    const rows = await insertResponse.json().catch(() => null) as Array<{ id: string }> | null;
    if (!insertResponse.ok || !rows?.[0]?.id) throw new Error("Complaint could not be submitted");
    setPrivateTenantResponse(response);
    response.status(201).json({ complaintId: rows[0].id });
  } catch (error) {
    response.status(400).json({ error: error instanceof Error ? error.message : "Complaint could not be submitted" });
  }
};

export const getHotelTenant: RequestHandler = async (request, response) => {
  try {
    setPrivateTenantResponse(response);
    response.json(await resolveRequestHotelTenant(request));
  } catch (error) {
    response.status(404).json({ error: error instanceof Error ? error.message : "This hotel domain is not configured" });
  }
};

export const getPublicHotelBookingData: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const organizationId = encodeURIComponent(tenant.organizationId);
    const [settings, offers, rooms] = await Promise.all([
      readService<Array<{ booking_title: string; booking_subtitle: string }>>(`hotel_tenant_settings?organization_id=eq.${organizationId}&select=booking_title,booking_subtitle&is_active=eq.true&limit=1`),
      readService(`hotel_booking_offers?organization_id=eq.${organizationId}&is_active=eq.true&select=id,title,description,discount_percentage,minimum_nights,starts_at,ends_at&order=display_order`),
      readService(`hotel_public_room_listings?organization_id=eq.${organizationId}&select=id,organization_id,name,room_type,description,image_url,size_sqm,max_guests,available_units,nightly_rate,original_nightly_rate,currency_code,amenities,status,hotel_name,hotel_city,hotel_country,hotel_classification&order=nightly_rate`),
    ]);
    if (settings.length !== 1) throw new Error("Hotel booking content is not configured");
    setPrivateTenantResponse(response);
    response.json({ tenant, settings: { title: settings[0].booking_title, subtitle: settings[0].booking_subtitle }, offers, rooms });
  } catch (error) {
    response.status(404).json({ error: error instanceof Error ? error.message : "Hotel information could not be loaded" });
  }
};

export const getPublicMenuItems: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const organizationId = encodeURIComponent(tenant.organizationId);
    const select = "id,organization_id,name,short_description,full_description,currency,media_type,media_url,media_attachment_id,price,original_price,category,icon,preparation_time,availability,max_availability,dietary_tags,spice_level,origin,calories,chef_note,special_offer,status_labels,is_trending,is_published,created_at";
    const items = await readService(`menu_items?organization_id=eq.${organizationId}&is_published=eq.true&select=${select}&order=created_at.asc`);
    setPrivateTenantResponse(response);
    response.json({ tenant, items });
  } catch (error) {
    response.status(404).json({ error: error instanceof Error ? error.message : "Menu information could not be loaded" });
  }
};

export const getPublicSpecialEvents: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const organizationId = encodeURIComponent(tenant.organizationId);
    const select = "id,title,description,starts_at,ends_at,timezone,location,facility_id,organization_id,is_private,share_token,price,currency,capacity,ticket_type_capacity,max_tickets_per_order,default_ticket_type_id,attendees_count,category,image_url,featured,rating,host_name,status,organizer_id,created_at,updated_at";
    const events = await readService(`special_events?organization_id=eq.${organizationId}&status=eq.published&is_private=eq.false&starts_at=gte.${encodeURIComponent(new Date().toISOString())}&select=${select}&order=featured.desc,starts_at.asc`);
    setPrivateTenantResponse(response);
    response.json({ events });
  } catch (error) {
    response.status(404).json({ error: error instanceof Error ? error.message : "Event information could not be loaded" });
  }
};

export const getTenantRoomAvailability: RequestHandler = async (request, response) => {
  try {
    const { checkIn, checkOut } = request.body as { checkIn?: string; checkOut?: string };
    if (!checkIn || !/^\d{4}-\d{2}-\d{2}$/.test(checkIn) || !checkOut || !/^\d{4}-\d{2}-\d{2}$/.test(checkOut)) {
      response.status(400).json({ error: "Select valid check-in and check-out dates" });
      return;
    }
    const tenant = await resolveRequestHotelTenant(request);
    const availability = await callTenantRpc<Array<{ room_id: string; remaining_units: number }>>(
      "get_hotel_room_availability_for_tenant",
      { target_organization_id: tenant.organizationId, target_check_in: checkIn, target_check_out: checkOut },
    );
    setPrivateTenantResponse(response);
    response.json({ availability });
  } catch (error) {
    response.status(404).json({ error: error instanceof Error ? error.message : "Hotel availability could not be loaded" });
  }
};
