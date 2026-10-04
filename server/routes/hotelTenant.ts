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
  const tenant = Array.isArray(payload) ? payload[0] : payload;
  if (!tenantResponse.ok || !tenant) throw new Error("This hotel domain is not configured");

  return {
    organizationId: tenant.organization_id,
    name: tenant.name,
    logoUrl: tenant.logo_url,
    primaryColor: tenant.primary_color,
    accentColor: tenant.accent_color,
  };
};

const readService = async <T>(path: string): Promise<T> => {
  const { supabaseUrl } = configuration();
  const response = await fetch(`${supabaseUrl}/rest/v1/${path}`, {
    headers: serviceHeaders(),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error("Hotel information could not be loaded");
  return response.json() as Promise<T>;
};

export const getHotelTenant: RequestHandler = async (request, response) => {
  try {
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
      readService<Array<{ title: string; subtitle: string }>>(`hotel_booking_page_settings?organization_id=eq.${organizationId}&select=title,subtitle&limit=1`),
      readService(`hotel_booking_offers?organization_id=eq.${organizationId}&is_active=eq.true&select=id,title,description,discount_percentage,minimum_nights,starts_at,ends_at&order=display_order`),
      readService(`hotel_public_room_listings?organization_id=eq.${organizationId}&select=id,organization_id,name,room_type,description,image_url,size_sqm,max_guests,available_units,nightly_rate,original_nightly_rate,currency_code,amenities,status,hotel_name,hotel_city,hotel_country,hotel_classification&order=nightly_rate`),
    ]);
    response.json({ tenant, settings: settings[0] || null, offers, rooms });
  } catch (error) {
    response.status(404).json({ error: error instanceof Error ? error.message : "Hotel information could not be loaded" });
  }
};

export const getPublicMenuItems: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const organizationId = encodeURIComponent(tenant.organizationId);
    const items = await readService(`menu_items?organization_id=eq.${organizationId}&is_published=eq.true&select=*&order=created_at.asc`);
    response.json({ items });
  } catch (error) {
    response.status(404).json({ error: error instanceof Error ? error.message : "Menu information could not be loaded" });
  }
};
