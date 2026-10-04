import type { Request, RequestHandler } from "express";

export type ResolvedHotelTenant = {
  organizationId: string;
  name: string;
  logoUrl: string | null;
  primaryColor: string;
  accentColor: string;
};

type TenantRow = {
  organization_id: string;
  name: string;
  logo_url: string | null;
  primary_color: string;
  accent_color: string;
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
  if (!response.ok) throw new Error("Hotel information could not be loaded");
  return response.json() as Promise<T>;
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
    const items = await readService(`menu_items?organization_id=eq.${organizationId}&is_published=eq.true&select=*&order=created_at.asc`);
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
    if (!checkIn || !/^\\d{4}-\\d{2}-\\d{2}$/.test(checkIn) || !checkOut || !/^\\d{4}-\\d{2}-\\d{2}$/.test(checkOut)) {
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
