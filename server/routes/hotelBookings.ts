import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import type { Request, RequestHandler } from "express";
import { resolveRequestHotelTenant } from "./hotelTenant.js";

const flutterwaveBaseUrl = "https://api.flutterwave.com/v3";
const supportedCurrencies = new Set(["USD", "UGX", "EUR", "GBP", "KES", "TZS", "RWF"]);
const fxProvider = "open.er-api.com";

export class HotelBookingError extends Error {
  constructor(message: string, readonly status = 400) {
    super(message);
  }
}

type HotelBooking = {
  id: string;
  organization_id: string;
  confirmation_number: string;
  total_amount: number | string;
  currency_code: string;
  payment_status: string;
  booking_status: string;
  check_in: string;
  check_out: string;
  nights: number;
  expires_at: string | null;
  access_token_hash: string;
  guest_first_name: string;
  guest_last_name: string;
  guest_email: string;
  guest_phone: string;
};

type HotelPaymentAttempt = {
  id: string;
  booking_id: string;
  tx_ref: string;
  transaction_id: string | null;
  amount: number | string;
  currency_code: string;
  status: string;
  payment_url: string | null;
  created_at: string;
};

type FlutterwaveTransaction = {
  id: number | string;
  tx_ref: string;
  status: string;
  amount: number | string;
  currency: string;
  meta?: Record<string, unknown>;
};

type ExchangeRatesPayload = {
  result?: string;
  time_last_update_unix?: number;
  rates?: Record<string, number>;
};

const configuration = () => {
  const supabaseUrl = process.env.VITE_SUPABASE_URL;
  const supabaseAnonKey = process.env.VITE_SUPABASE_ANON_KEY;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabaseUrl || !supabaseAnonKey || !serviceRoleKey) {
    throw new Error("Hotel booking database configuration is incomplete");
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

const readService = async <T>(path: string): Promise<T> => {
  const { supabaseUrl } = configuration();
  const response = await fetch(`${supabaseUrl}/rest/v1/${path}`, { headers: serviceHeaders() });
  if (!response.ok) throw new Error("Unable to read hotel booking data");
  return response.json() as Promise<T>;
};

const writeService = async (path: string, method: "POST" | "PATCH", body: unknown, prefer = "return=minimal") => {
  const { supabaseUrl } = configuration();
  const response = await fetch(`${supabaseUrl}/rest/v1/${path}`, {
    method,
    headers: { ...serviceHeaders(true), Prefer: prefer },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error("Unable to save hotel booking data");
  return response;
};

const callServiceRpc = async <T>(name: string, args: Record<string, unknown>): Promise<T> => {
  const { supabaseUrl } = configuration();
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: { ...serviceHeaders(true), Prefer: "return=representation" },
    body: JSON.stringify(args),
  });
  const payload = await response.json().catch(() => null);
  if (!response.ok) {
    const message = payload && typeof payload.message === "string" ? payload.message : "Unable to create hotel reservation";
    throw new HotelBookingError(message, response.status >= 500 ? 503 : 400);
  }
  return payload as T;
};

const fetchAndStoreRates = async () => {
  const cached = await readService<Array<{ quote_currency: string; rate: number | string; fetched_at: string; stored_at: string; provider: string }>>(
    "books_fx_rates?base_currency=eq.UGX&select=quote_currency,rate,fetched_at,stored_at,provider&order=stored_at.desc",
  );
  const currentTime = Date.now();
  const mostRecent = cached[0]?.stored_at ? new Date(cached[0].stored_at).getTime() : 0;
  const fetchedAt = cached[0]?.fetched_at ? new Date(cached[0].fetched_at).getTime() : 0;
  const cachedRates = Object.fromEntries(cached.map((row) => [row.quote_currency.trim(), Number(row.rate)]));
  const cachedSnapshotIsUsable = cached.length >= supportedCurrencies.size - 1
    && currentTime - mostRecent < 30 * 60 * 1000
    && mostRecent <= currentTime + 5 * 60 * 1000
    && currentTime - fetchedAt <= 36 * 60 * 60 * 1000
    && fetchedAt <= currentTime + 5 * 60 * 1000
    && cached.every((row) => row.provider === fxProvider
      && new Date(row.fetched_at).getTime() === fetchedAt
      && currentTime - new Date(row.stored_at).getTime() < 30 * 60 * 1000
      && new Date(row.stored_at).getTime() <= currentTime + 5 * 60 * 1000
      && Number.isFinite(Number(row.rate))
      && Number(row.rate) > 0)
    && [...supportedCurrencies].filter((currency) => currency !== "UGX").every((currency) => Number.isFinite(cachedRates[currency]) && cachedRates[currency] > 0);
  if (cachedSnapshotIsUsable) {
    return { rates: { UGX: 1, ...cachedRates }, asOf: cached[0].fetched_at, provider: cached[0].provider };
  }

  const response = await fetch("https://open.er-api.com/v6/latest/UGX", { signal: AbortSignal.timeout(8000) });
  const payload = await response.json() as ExchangeRatesPayload;
  if (!response.ok || payload.result !== "success" || !payload.rates || !payload.time_last_update_unix) {
    throw new Error("The exchange-rate service is temporarily unavailable");
  }
  const asOfDate = new Date(payload.time_last_update_unix * 1000);
  if (Date.now() - asOfDate.getTime() > 36 * 60 * 60 * 1000 || asOfDate.getTime() > Date.now() + 5 * 60 * 1000) {
    throw new Error("The exchange-rate service returned an outdated snapshot");
  }
  const asOf = asOfDate.toISOString();
  const rates = { ...payload.rates, UGX: 1 };
  const rows = [...supportedCurrencies]
    .filter((currency) => currency !== "UGX" && Number.isFinite(rates[currency]) && rates[currency] > 0)
    .map((currency) => ({ base_currency: "UGX", quote_currency: currency, rate: rates[currency], provider: fxProvider, fetched_at: asOf, stored_at: new Date().toISOString() }));
  if (rows.length !== supportedCurrencies.size - 1) throw new Error("The exchange-rate service is missing a supported hotel currency");
  await writeService("books_fx_rates?on_conflict=base_currency,quote_currency", "POST", rows, "resolution=merge-duplicates,return=minimal");
  return { rates, asOf, provider: fxProvider };
};

const safeText = (value: unknown, maxLength: number) => typeof value === "string" ? value.trim().slice(0, maxLength) : "";
const resolveAuthenticatedUserId = async (authorization: string | undefined) => {
  if (!authorization) return null;
  if (!authorization.startsWith("Bearer ")) throw new HotelBookingError("Your sign-in session is invalid", 401);
  const { supabaseUrl, supabaseAnonKey } = configuration();
  const response = await fetch(`${supabaseUrl}/auth/v1/user`, { headers: { apikey: supabaseAnonKey, Authorization: authorization } });
  if (!response.ok) throw new HotelBookingError("Your sign-in session has expired. Sign in again and retry.", 401);
  const user = await response.json() as { id?: string };
  if (!user.id) throw new HotelBookingError("Your sign-in session could not be verified", 401);
  return user.id;
};

const getBooking = async (bookingId: string) => {
  const rows = await readService<HotelBooking[]>(`hotel_bookings?id=eq.${encodeURIComponent(bookingId)}&select=*`);
  if (!rows[0]) throw new HotelBookingError("Hotel reservation was not found", 404);
  return rows[0];
};

const assertBookingTenant = async (request: Request, booking: HotelBooking) => {
  const tenant = await resolveRequestHotelTenant(request);
  if (booking.organization_id !== tenant.organizationId) {
    throw new HotelBookingError("This reservation is not available for this hotel", 404);
  }
  return tenant;
};

const getAttempt = async (txRef: string) => {
  const rows = await readService<HotelPaymentAttempt[]>(`hotel_payment_attempts?tx_ref=eq.${encodeURIComponent(txRef)}&select=*`);
  if (!rows[0]) throw new HotelBookingError("Payment attempt was not found", 404);
  return rows[0];
};

const getReturnUrl = (domain: string) => {
  const configuredUrl = process.env.NODE_ENV === "production"
    ? process.env.FLUTTERWAVE_RETURN_URL
    : process.env.FLUTTERWAVE_LOCAL_RETURN_URL;
  if (!configuredUrl) throw new Error("Flutterwave return URL is not configured");
  const url = new URL(configuredUrl);
  if (url.protocol !== "https:" || url.pathname !== "/checkout/flutterwave-return") {
    throw new Error("Flutterwave return URL must use HTTPS and target the payment return route");
  }
  url.hostname = domain;
  url.searchParams.set("flow", "hotel");
  return url.toString();
};

const createBooking: RequestHandler = async (request, response) => {
  try {
    const tenant = await resolveRequestHotelTenant(request);
    const body = request.body as {
      roomId?: string;
      guest?: Record<string, unknown>;
      checkIn?: string;
      checkOut?: string;
      guestCount?: number;
      roomCount?: number;
      specialRequests?: string;
      preferences?: unknown;
      idempotencyKey?: string;
      accessToken?: string;
    };
    const userId = await resolveAuthenticatedUserId(request.headers.authorization);
    const email = safeText(body.guest?.email, 254).toLowerCase();
    const forwardedAddress = request.headers["x-vercel-forwarded-for"] || request.headers["x-nf-client-connection-ip"];
    const clientAddress = (Array.isArray(forwardedAddress) ? forwardedAddress[0] : forwardedAddress)?.split(",")[0]?.trim() || request.ip || request.socket.remoteAddress || "unknown";
    const rateLimitKey = createHash("sha256").update(clientAddress).digest("hex");
    if (!body.roomId || !/^[0-9a-f-]{36}$/i.test(body.roomId)) throw new HotelBookingError("Select a valid room");
    if (!body.checkIn || !/^\d{4}-\d{2}-\d{2}$/.test(body.checkIn) || !body.checkOut || !/^\d{4}-\d{2}-\d{2}$/.test(body.checkOut)) throw new HotelBookingError("Select valid check-in and check-out dates");
    if (!body.idempotencyKey || !/^[0-9a-f-]{36}$/i.test(body.idempotencyKey)) throw new HotelBookingError("Booking request is invalid");
    if (!body.accessToken || body.accessToken.length < 32 || body.accessToken.length > 256) throw new HotelBookingError("Booking access credential is invalid");
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !Number.isInteger(body.guestCount) || !Number.isInteger(body.roomCount)) throw new HotelBookingError("Enter valid guest and room details");
    if (!Array.isArray(body.preferences) || body.preferences.some((value) => typeof value !== "string")) throw new HotelBookingError("Room preferences are invalid");
    const accessTokenHash = createHash("sha256").update(body.accessToken).digest("hex");
    const bookingWithKey = (await readService<Array<{ organization_id: string; user_id: string | null; access_token_hash: string; fx_rates_snapshot: { as_of?: string } | null }>>(
      `hotel_bookings?idempotency_key=eq.${encodeURIComponent(body.idempotencyKey)}&select=organization_id,user_id,access_token_hash,fx_rates_snapshot&limit=1`,
    ))[0];
    if (bookingWithKey && bookingWithKey.organization_id !== tenant.organizationId) {
      throw new HotelBookingError("Reservation belongs to a different hotel", 404);
    }
    const existingBooking = bookingWithKey?.user_id === userId && bookingWithKey.access_token_hash === accessTokenHash
      ? bookingWithKey
      : null;
    let ratesSnapshot: { rates: Record<string, number>; asOf: string; provider: string } | null = null;
    if (!existingBooking) {
      const rateLimitAllowed = await callServiceRpc<boolean>("consume_hotel_booking_rate_limit", { target_rate_limit_key: rateLimitKey });
      if (!rateLimitAllowed) throw new HotelBookingError("Too many reservation attempts. Please try again later", 429);
      ratesSnapshot = await fetchAndStoreRates();
      const selectedRoom = (await readService<Array<{ currency_code: string }>>(`hotel_rooms?id=eq.${encodeURIComponent(body.roomId)}&organization_id=eq.${encodeURIComponent(tenant.organizationId)}&status=eq.published&select=currency_code`))[0];
      if (!selectedRoom) throw new HotelBookingError("This room is not available for booking", 404);
      const currency = selectedRoom.currency_code.trim().toUpperCase();
      if (!supportedCurrencies.has(currency) || !ratesSnapshot.rates[currency]) throw new HotelBookingError("This room uses an unsupported booking currency");
    }

    const rows = await callServiceRpc<Array<{ booking_id: string; confirmation_number: string; total_amount: number; currency_code: string; expires_at: string }>>(
      "create_hotel_booking_for_tenant",
      {
        target_organization_id: tenant.organizationId,
        target_room_id: body.roomId,
        target_guest: {
          first_name: safeText(body.guest?.firstName, 100),
          last_name: safeText(body.guest?.lastName, 100),
          email,
          phone: safeText(body.guest?.phone, 40),
        },
        target_check_in: body.checkIn,
        target_check_out: body.checkOut,
        target_guest_count: body.guestCount,
        target_room_count: body.roomCount,
        target_special_requests: safeText(body.specialRequests, 2000),
        target_preferences: body.preferences,
        target_user_id: userId,
        target_idempotency_key: body.idempotencyKey,
        target_access_token_hash: accessTokenHash,
        target_fx_rates: ratesSnapshot ? { ...ratesSnapshot.rates, as_of: ratesSnapshot.asOf, provider: ratesSnapshot.provider } : null,
      },
    );
    const booking = rows[0];
    if (!booking) throw new Error("Reservation was not returned after creation");
    response.json({
      ...booking,
      accessToken: body.accessToken,
      fxAsOf: ratesSnapshot?.asOf ?? existingBooking?.fx_rates_snapshot?.as_of ?? null,
    });
  } catch (error) {
    response.status(error instanceof HotelBookingError ? error.status : 503).json({
      error: error instanceof Error ? error.message : "Unable to create hotel reservation",
    });
  }
};

const createPaymentSession: RequestHandler = async (request, response) => {
  let txRef: string | undefined;
  try {
    const { bookingId, accessToken } = request.body as { bookingId?: string; accessToken?: string };
    if (!bookingId || !accessToken) throw new HotelBookingError("Booking access is required");
    const booking = await getBooking(bookingId);
    const tenant = await assertBookingTenant(request, booking);
    const tokenHash = createHash("sha256").update(accessToken).digest("hex");
    if (tokenHash !== booking.access_token_hash) throw new HotelBookingError("Booking access could not be verified", 403);
    if (booking.payment_status === "paid") throw new HotelBookingError("This reservation is already paid", 409);
    if (booking.booking_status !== "pending" || !booking.expires_at || new Date(booking.expires_at).getTime() <= Date.now()) {
      throw new HotelBookingError("This reservation hold has expired. Select the room again to start a new booking.", 409);
    }
    const secretKey = process.env.FLUTTERWAVE_SECRET_KEY;
    if (!secretKey) throw new Error("Flutterwave payment configuration is incomplete");
    const requestedTxRef = `hotel-${booking.confirmation_number}-${randomUUID()}`;
    const attempts = await callServiceRpc<Array<{ attempt_id: string; attempt_tx_ref: string; attempt_status: string; attempt_payment_url: string | null }>>(
      "create_hotel_payment_attempt",
      {
        target_booking_id: booking.id,
        target_access_token_hash: tokenHash,
        target_tx_ref: requestedTxRef,
      },
    );
    const active = attempts[0];
    if (!active) throw new Error("Payment attempt was not returned after creation");
    if (active.attempt_status === "redirected" && active.attempt_payment_url) {
      response.json({ paymentUrl: active.attempt_payment_url, txRef: active.attempt_tx_ref, bookingId: booking.id });
      return;
    }
    if (active.attempt_status === "preparing") {
      throw new HotelBookingError("Secure checkout is already being prepared. Try again shortly.", 409);
    }
    txRef = active.attempt_tx_ref;
    const currency = booking.currency_code.trim().toUpperCase();
    const flutterwaveResponse = await fetch(`${flutterwaveBaseUrl}/payments`, {
      method: "POST",
      headers: { Authorization: `Bearer ${secretKey}`, "content-type": "application/json" },
      body: JSON.stringify({
        tx_ref: txRef,
        amount: Number(booking.total_amount),
        currency,
        payment_options: currency === "UGX" ? "card, mobilemoneyuganda" : "card",
        redirect_url: getReturnUrl(tenant.domain),
        customer: {
          email: booking.guest_email,
          name: `${booking.guest_first_name} ${booking.guest_last_name}`.trim(),
          phonenumber: booking.guest_phone,
        },
        meta: { booking_id: booking.id, confirmation_number: booking.confirmation_number },
        customizations: { title: "Hotel Room Reservation", description: `Reservation ${booking.confirmation_number}` },
      }),
      signal: AbortSignal.timeout(15_000),
    });
    const payload = await flutterwaveResponse.json() as { status?: string; message?: string; data?: { link?: string } };
    if (!flutterwaveResponse.ok || payload.status !== "success" || !payload.data?.link) {
      throw new HotelBookingError("Flutterwave could not prepare secure checkout. Please try again.", 502);
    }
    await writeService(`hotel_payment_attempts?tx_ref=eq.${encodeURIComponent(txRef)}`, "PATCH", { status: "redirected", payment_url: payload.data.link });
    response.json({ paymentUrl: payload.data.link, txRef, bookingId: booking.id });
  } catch (error) {
    if (txRef) {
      await writeService(`hotel_payment_attempts?tx_ref=eq.${encodeURIComponent(txRef)}`, "PATCH", {
        status: "failed",
        failure_reason: error instanceof Error ? error.message.slice(0, 500) : "Unable to prepare payment",
      }).catch((failure) => console.error("Unable to record hotel payment failure", failure));
    }
    response.status(error instanceof HotelBookingError ? error.status : 503).json({
      error: error instanceof Error ? error.message : "Unable to prepare hotel payment",
    });
  }
};

const verifyTransaction = async (transactionId: string) => {
  const secretKey = process.env.FLUTTERWAVE_SECRET_KEY;
  if (!secretKey) throw new Error("Flutterwave payment configuration is incomplete");
  const response = await fetch(`${flutterwaveBaseUrl}/transactions/${encodeURIComponent(transactionId)}/verify`, {
    headers: { Authorization: `Bearer ${secretKey}` },
    signal: AbortSignal.timeout(15_000),
  });
  const payload = await response.json() as { status?: string; data?: FlutterwaveTransaction };
  if (!response.ok || payload.status !== "success" || !payload.data) throw new Error("Hotel payment could not be verified");
  return payload.data;
};

const verifyHotelPayment = async (transactionId: string, txRef: string, accessToken?: string, tenantOrganizationId?: string) => {
  const attempt = await getAttempt(txRef);
  const booking = await getBooking(attempt.booking_id);
  if (tenantOrganizationId && booking.organization_id !== tenantOrganizationId) {
    throw new HotelBookingError("This reservation is not available for this hotel", 404);
  }
  if (accessToken && createHash("sha256").update(accessToken).digest("hex") !== booking.access_token_hash) {
    throw new HotelBookingError("Booking access could not be verified", 403);
  }
  const transaction = await verifyTransaction(transactionId);
  if (
    transaction.status !== "successful" || transaction.tx_ref !== attempt.tx_ref ||
    Number(transaction.amount) !== Number(booking.total_amount) || Number(transaction.amount) !== Number(attempt.amount) ||
    transaction.currency.toUpperCase() !== booking.currency_code.trim().toUpperCase() ||
    transaction.currency.toUpperCase() !== attempt.currency_code.trim().toUpperCase() ||
    transaction.meta?.booking_id !== booking.id
  ) throw new HotelBookingError("Payment verification did not match this reservation", 409);

  const result = await callServiceRpc<Array<{ booking_id: string; confirmation_number: string; payment_status: string; booking_status: string }>>(
    "confirm_hotel_booking_payment",
    { target_tx_ref: txRef, target_transaction_id: String(transaction.id) },
  );
  const confirmation = result[0];
  if (!confirmation) throw new Error("Confirmed hotel reservation was not returned");
  return confirmation;
};

export const createHotelBooking = createBooking;
export const createHotelPaymentSession = createPaymentSession;

export const recoverHotelBooking: RequestHandler = async (request, response) => {
  try {
    const { bookingId, accessToken } = request.body as { bookingId?: string; accessToken?: string };
    if (!bookingId || !/^[0-9a-f-]{36}$/i.test(bookingId) || !accessToken || accessToken.length < 32 || accessToken.length > 256) {
      throw new HotelBookingError("Booking recovery details are invalid");
    }
    const booking = await getBooking(bookingId);
    await assertBookingTenant(request, booking);
    if (createHash("sha256").update(accessToken).digest("hex") !== booking.access_token_hash) {
      throw new HotelBookingError("Booking access could not be verified", 403);
    }
    response.json({
      bookingId: booking.id,
      confirmationNumber: booking.confirmation_number,
      bookingStatus: booking.booking_status,
      paymentStatus: booking.payment_status,
      currencyCode: booking.currency_code.trim(),
      totalAmount: Number(booking.total_amount),
      checkIn: booking.check_in,
      checkOut: booking.check_out,
      nights: Number(booking.nights),
      expiresAt: booking.expires_at,
    });
  } catch (error) {
    response.status(error instanceof HotelBookingError ? error.status : 503).json({
      error: error instanceof Error ? error.message : "Unable to retrieve this reservation",
    });
  }
};

export const cancelHotelBookingHold: RequestHandler = async (request, response) => {
  try {
    const { bookingId, accessToken } = request.body as { bookingId?: string; accessToken?: string };
    if (!bookingId || !/^[0-9a-f-]{36}$/i.test(bookingId) || !accessToken || accessToken.length < 32 || accessToken.length > 256) {
      throw new HotelBookingError("Booking cancellation details are invalid");
    }
    const booking = await getBooking(bookingId);
    await assertBookingTenant(request, booking);
    const tokenHash = createHash("sha256").update(accessToken).digest("hex");
    if (tokenHash !== booking.access_token_hash) throw new HotelBookingError("Booking access could not be verified", 403);
    const cancelled = await callServiceRpc<boolean>("cancel_hotel_booking_hold", {
      target_booking_id: bookingId,
      target_access_token_hash: tokenHash,
    });
    response.json({ cancelled });
  } catch (error) {
    response.status(error instanceof HotelBookingError ? error.status : 503).json({
      error: error instanceof Error ? error.message : "Unable to release reservation hold",
    });
  }
};

export const verifyHotelBookingPayment: RequestHandler = async (request, response) => {
  try {
    const { transactionId, txRef, accessToken } = request.body as { transactionId?: string | number; txRef?: string; accessToken?: string };
    if (!transactionId || !txRef?.startsWith("hotel-") || !accessToken) throw new HotelBookingError("Payment verification details are required");
    const tenant = await resolveRequestHotelTenant(request);
    const confirmation = await verifyHotelPayment(String(transactionId), txRef, accessToken, tenant.organizationId);
    response.json({ ...confirmation, paymentStatus: confirmation.payment_status });
  } catch (error) {
    response.status(error instanceof HotelBookingError ? error.status : 503).json({
      error: error instanceof Error ? error.message : "Unable to confirm hotel payment",
    });
  }
};

export const cancelHotelBookingPayment: RequestHandler = async (request, response) => {
  try {
    const { txRef, status, accessToken } = request.body as { txRef?: string; status?: string; accessToken?: string };
    if (!txRef?.startsWith("hotel-") || !["cancelled", "failed"].includes(status || "") || !accessToken) {
      throw new HotelBookingError("Payment cancellation details are invalid");
    }
    const attempt = await getAttempt(txRef);
    const booking = await getBooking(attempt.booking_id);
    await assertBookingTenant(request, booking);
    if (createHash("sha256").update(accessToken).digest("hex") !== booking.access_token_hash) throw new HotelBookingError("Booking access could not be verified", 403);
    if (attempt.status !== "completed") {
      await writeService(`hotel_payment_attempts?tx_ref=eq.${encodeURIComponent(txRef)}`, "PATCH", {
        status: status === "cancelled" ? "cancelled" : "failed",
        ...(status === "cancelled" ? { cancelled_at: new Date().toISOString() } : { failure_reason: "Flutterwave returned an unsuccessful payment status" }),
      });
    }
    response.json({ paymentStatus: status });
  } catch (error) {
    response.status(error instanceof HotelBookingError ? error.status : 503).json({
      error: error instanceof Error ? error.message : "Unable to record payment status",
    });
  }
};

export const handleHotelBookingWebhook: RequestHandler = async (request, response) => {
  const signature = request.headers["verif-hash"];
  const secretHash = process.env.FLUTTERWAVE_SECRET_HASH;
  const signatureBytes = typeof signature === "string" ? Buffer.from(signature) : null;
  const secretBytes = secretHash ? Buffer.from(secretHash) : null;
  const signatureIsValid = Boolean(signatureBytes && secretBytes && signatureBytes.length === secretBytes.length && timingSafeEqual(signatureBytes, secretBytes));
  if (!signatureIsValid) return response.status(401).end();
  const payload = request.body as { event?: string; data?: { id?: string | number; tx_ref?: string } };
  if (payload.event !== "charge.completed" || !payload.data?.id || !payload.data.tx_ref?.startsWith("hotel-")) return response.status(200).end();
  try {
    await verifyHotelPayment(String(payload.data.id), payload.data.tx_ref);
    return response.status(200).end();
  } catch (error) {
    console.error("Hotel payment webhook verification failed", error);
    return response.status(500).end();
  }
};

export const getExchangeRates: RequestHandler = async (_request, response) => {
  try {
    const result = await fetchAndStoreRates();
    response.setHeader("Cache-Control", "private, max-age=300");
    response.json({ base: "UGX", rates: result.rates, asOf: result.asOf, provider: result.provider });
  } catch (error) {
    console.error("Unable to refresh Books exchange rates", error);
    response.status(503).json({ error: "Exchange rates are temporarily unavailable" });
  }
};
