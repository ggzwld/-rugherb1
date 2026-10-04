import type { RequestHandler } from "express";
import { resolveRequestHotelTenant } from "./hotelTenant.js";

type MenuOrderInput = {
  items?: Array<{ menuItemId?: string; quantity?: number }>;
  orderType?: string;
  paymentMethod?: string;
  tipAmount?: number;
  customer?: Record<string, unknown>;
  cartId?: string | null;
  idempotencyKey?: string;
};

const getConfiguration = () => {
  const supabaseUrl = process.env.VITE_SUPABASE_URL;
  const supabaseAnonKey = process.env.VITE_SUPABASE_ANON_KEY;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !supabaseAnonKey || !serviceRoleKey) {
    throw new Error("Menu checkout database configuration is incomplete");
  }
  return { supabaseUrl: supabaseUrl.replace(/\/$/, ""), supabaseAnonKey, serviceRoleKey };
};

const getAuthenticatedUserId = async (authorization: string | undefined) => {
  if (!authorization?.startsWith("Bearer ")) return null;
  const { supabaseUrl, supabaseAnonKey } = getConfiguration();
  const response = await fetch(`${supabaseUrl}/auth/v1/user`, {
    headers: { apikey: supabaseAnonKey, Authorization: authorization },
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) return null;
  const user = await response.json() as { id?: string };
  return user.id || null;
};

export const createMenuOrder: RequestHandler = async (request, response) => {
  try {
    const input = request.body as MenuOrderInput;
    const userId = await getAuthenticatedUserId(request.headers.authorization);
    if (!userId) return response.status(401).json({ error: "Please sign in before placing an order." });
    if (!input.idempotencyKey || !/^[0-9a-f-]{36}$/i.test(input.idempotencyKey)) {
      return response.status(400).json({ error: "Checkout request is invalid." });
    }
    if (!Array.isArray(input.items) || !input.items.length || !input.customer) {
      return response.status(400).json({ error: "Add menu items and complete your customer details." });
    }
    if (input.cartId != null && !/^[0-9a-f-]{36}$/i.test(input.cartId)) {
      return response.status(400).json({ error: "Saved cart is invalid." });
    }
    if (typeof input.tipAmount !== "number" || !Number.isFinite(input.tipAmount)) {
      return response.status(400).json({ error: "Tip amount is invalid." });
    }

    const tenant = await resolveRequestHotelTenant(request);
    const { supabaseUrl, supabaseAnonKey, serviceRoleKey } = getConfiguration();
    const rpcResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/create_menu_order_for_tenant`, {
      method: "POST",
      headers: {
        apikey: supabaseAnonKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        "content-type": "application/json",
        Prefer: "return=representation",
      },
      body: JSON.stringify({
        target_organization_id: tenant.organizationId,
        target_user_id: userId,
        target_items: input.items.map(({ menuItemId, quantity }) => ({ menuItemId, quantity })),
        target_order_type: input.orderType,
        target_payment_method: input.paymentMethod,
        target_tip_amount: input.tipAmount,
        target_customer: input.customer,
        target_cart_id: input.cartId || null,
        target_idempotency_key: input.idempotencyKey,
      }),
      signal: AbortSignal.timeout(15_000),
    });
    const payload = await rpcResponse.json().catch(() => null) as Array<Record<string, unknown>> | { message?: string } | null;
    if (!rpcResponse.ok) {
      const message = payload && !Array.isArray(payload) && typeof payload.message === "string"
        ? payload.message
        : "The order could not be priced securely.";
      return response.status(rpcResponse.status === 401 ? 401 : 400).json({ error: message });
    }
    const [order] = Array.isArray(payload) ? payload : [];
    if (!order) return response.status(503).json({ error: "The order could not be created." });
    return response.status(201).json(order);
  } catch (error) {
    console.error("Menu order creation failed", error);
    return response.status(503).json({
      error: error instanceof Error ? error.message : "The order could not be created.",
    });
  }
};
