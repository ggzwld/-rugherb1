import { randomUUID } from "node:crypto";
import type { RequestHandler } from "express";

const flutterwaveBaseUrl = "https://api.flutterwave.com/v3";
const flutterwaveReturnPath = "/checkout/flutterwave-return";

export class SpecialEventPaymentError extends Error {
  constructor(message: string, readonly status = 400) {
    super(message);
  }
}

type SpecialBooking = {
  id: string;
  user_id: string;
  event_id: string;
  order_number: string;
  guest_first_name: string;
  guest_last_name: string;
  guest_email: string;
  guest_phone: string | null;
  total_amount: number | string;
  currency: string;
  status: string;
  payment_status: string;
  expires_at: string | null;
};

type SpecialPaymentAttempt = {
  id: string;
  booking_id: string;
  tx_ref: string;
  transaction_id: string | null;
  amount: number | string;
  currency: string;
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

const getConfiguration = () => {
  const secretKey = process.env.FLUTTERWAVE_SECRET_KEY;
  const secretHash = process.env.FLUTTERWAVE_SECRET_HASH;
  const supabaseUrl = process.env.VITE_SUPABASE_URL;
  const supabaseAnonKey = process.env.VITE_SUPABASE_ANON_KEY;
  const supabaseServiceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!secretKey || !supabaseUrl || !supabaseAnonKey || !supabaseServiceRoleKey) {
    throw new Error("Event payment configuration is incomplete");
  }

  return { secretKey, secretHash, supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey };
};

const getReturnUrl = () => {
  const value = process.env.NODE_ENV === "production"
    ? process.env.FLUTTERWAVE_RETURN_URL
    : process.env.FLUTTERWAVE_LOCAL_RETURN_URL;
  if (!value) throw new Error("Flutterwave return URL is not configured");
  const parsed = new URL(value);
  if (parsed.protocol !== "https:" || parsed.pathname !== flutterwaveReturnPath) {
    throw new Error("Flutterwave return URL must use HTTPS and target the payment return route");
  }
  return parsed.toString();
};

const restHeaders = (token: string, anonKey: string, json = false) => ({
  apikey: anonKey,
  Authorization: `Bearer ${token}`,
  ...(json ? { "content-type": "application/json" } : {}),
});

const getBooking = async (bookingId: string, authorization?: string) => {
  if (!authorization?.startsWith("Bearer ")) throw new SpecialEventPaymentError("Missing authenticated session", 401);
  const { supabaseUrl, supabaseAnonKey } = getConfiguration();
  const response = await fetch(`${supabaseUrl}/rest/v1/special_event_bookings?id=eq.${encodeURIComponent(bookingId)}&select=*`, {
    headers: restHeaders(authorization.slice("Bearer ".length), supabaseAnonKey),
  });
  if (!response.ok) throw new Error("Unable to retrieve event booking");
  const [booking] = (await response.json()) as SpecialBooking[];
  if (!booking) throw new SpecialEventPaymentError("Event booking not found", 404);
  return booking;
};

const getBookingAsService = async (bookingId: string) => {
  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getConfiguration();
  const response = await fetch(`${supabaseUrl}/rest/v1/special_event_bookings?id=eq.${encodeURIComponent(bookingId)}&select=*`, {
    headers: restHeaders(supabaseServiceRoleKey, supabaseAnonKey),
  });
  if (!response.ok) throw new Error("Unable to retrieve event booking");
  const [booking] = (await response.json()) as SpecialBooking[];
  if (!booking) throw new Error("Event booking not found");
  return booking;
};

const getPaymentAttemptAsService = async (txRef: string) => {
  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getConfiguration();
  const response = await fetch(`${supabaseUrl}/rest/v1/special_event_payment_attempts?tx_ref=eq.${encodeURIComponent(txRef)}&select=id,booking_id,tx_ref,transaction_id,amount,currency,status`, {
    headers: restHeaders(supabaseServiceRoleKey, supabaseAnonKey),
  });
  if (!response.ok) throw new Error("Unable to retrieve event payment attempt");
  const [attempt] = (await response.json()) as SpecialPaymentAttempt[];
  if (!attempt) throw new SpecialEventPaymentError("Event payment attempt not found", 404);
  return attempt;
};

const getActivePaymentAttempt = async (bookingId: string) => {
  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getConfiguration();
  const response = await fetch(
    `${supabaseUrl}/rest/v1/special_event_payment_attempts?booking_id=eq.${encodeURIComponent(bookingId)}&status=in.(initiated,redirected,verified)&select=id,booking_id,tx_ref,transaction_id,amount,currency,status,payment_url,created_at&order=created_at.desc&limit=1`,
    { headers: restHeaders(supabaseServiceRoleKey, supabaseAnonKey) },
  );
  if (!response.ok) throw new Error("Unable to retrieve active event payment attempt");
  const [attempt] = await response.json() as SpecialPaymentAttempt[];
  return attempt || null;
};

const createPaymentAttempt = async (values: Record<string, unknown>) => {
  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getConfiguration();
  const response = await fetch(`${supabaseUrl}/rest/v1/special_event_payment_attempts`, {
    method: "POST",
    headers: { ...restHeaders(supabaseServiceRoleKey, supabaseAnonKey, true), Prefer: "return=minimal" },
    body: JSON.stringify(values),
  });
  if (!response.ok) throw new Error("Unable to create event payment attempt");
};

const updatePaymentAttempt = async (txRef: string, values: Record<string, unknown>) => {
  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getConfiguration();
  const response = await fetch(`${supabaseUrl}/rest/v1/special_event_payment_attempts?tx_ref=eq.${encodeURIComponent(txRef)}`, {
    method: "PATCH",
    headers: { ...restHeaders(supabaseServiceRoleKey, supabaseAnonKey, true), Prefer: "return=minimal" },
    body: JSON.stringify({ ...values, updated_at: new Date().toISOString() }),
  });
  if (!response.ok) throw new Error("Unable to update event payment attempt");
};

const verifyTransaction = async (transactionId: string) => {
  const { secretKey } = getConfiguration();
  const response = await fetch(`${flutterwaveBaseUrl}/transactions/${encodeURIComponent(transactionId)}/verify`, {
    headers: { Authorization: `Bearer ${secretKey}` },
  });
  const payload = await response.json() as { status?: string; data?: FlutterwaveTransaction };
  if (!response.ok || payload.status !== "success" || !payload.data) throw new Error("Event payment could not be verified");
  return payload.data;
};

const confirmBookingAsService = async (bookingId: string, transactionId: string) => {
  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getConfiguration();
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/confirm_special_event_payment`, {
    method: "POST",
    headers: { ...restHeaders(supabaseServiceRoleKey, supabaseAnonKey, true), Prefer: "return=representation" },
    body: JSON.stringify({ target_booking_id: bookingId, target_transaction_id: transactionId }),
  });
  const payload = await response.json().catch(() => null) as Array<{ booking_id: string; confirmation_number: string; ticket_code: string | null; order_number: string; payment_status: string }> | { message?: string; details?: string; hint?: string } | null;
  if (!response.ok) {
    const error = payload && !Array.isArray(payload) ? [payload.message, payload.details, payload.hint].filter((value): value is string => typeof value === "string" && Boolean(value.trim())).join(" — ") : "";
    throw new Error(error || "Unable to confirm event booking");
  }
  const [confirmation] = Array.isArray(payload) ? payload : [];
  if (!confirmation) throw new Error("Event booking confirmation was not returned");
  return confirmation;
};

const assertTransactionMatches = (transaction: FlutterwaveTransaction, attempt: SpecialPaymentAttempt, booking: SpecialBooking) => {
  if (transaction.status !== "successful" || transaction.tx_ref !== attempt.tx_ref) throw new Error("Event payment status does not match the booking");
  if (
    Number(transaction.amount) !== Number(booking.total_amount)
    || Number(transaction.amount) !== Number(attempt.amount)
    || transaction.currency.toUpperCase() !== booking.currency.toUpperCase()
    || transaction.currency.toUpperCase() !== attempt.currency.toUpperCase()
  ) throw new Error("Event payment amount does not match the booking");
  if (transaction.meta?.booking_id !== booking.id) throw new Error("Event payment metadata does not match the booking");
};

export const prepareSpecialEventPayment: RequestHandler = async (req, res) => {
  let bookingId: string | undefined;
  let txRef: string | undefined;
  try {
    bookingId = (req.body as { bookingId?: string }).bookingId;
    if (!bookingId) throw new SpecialEventPaymentError("Booking ID is required");
    const booking = await getBooking(bookingId, req.headers.authorization);
    if (booking.payment_status === "paid") throw new SpecialEventPaymentError("This event booking has already been paid", 409);
    if (booking.status !== "pending" || booking.payment_status !== "pending") throw new SpecialEventPaymentError("This event booking is no longer pending", 409);
    if (booking.expires_at && new Date(booking.expires_at).getTime() <= Date.now()) throw new SpecialEventPaymentError("This ticket hold has expired. Start a new booking.", 409);
    if (Number(booking.total_amount) <= 0) throw new SpecialEventPaymentError("This booking does not require online payment", 400);

    const { secretKey } = getConfiguration();
    const activeAttempt = await getActivePaymentAttempt(booking.id);
    if (activeAttempt?.status === "redirected" && activeAttempt.payment_url) {
      return res.json({ paymentUrl: activeAttempt.payment_url, txRef: activeAttempt.tx_ref, bookingId: booking.id });
    }
    if (activeAttempt?.status === "verified") {
      throw new SpecialEventPaymentError("Payment verification is still processing. Refresh My Events shortly.", 409);
    }
    if (activeAttempt?.status === "initiated") {
      const attemptAge = Date.now() - new Date(activeAttempt.created_at).getTime();
      if (attemptAge < 120_000) {
        throw new SpecialEventPaymentError("Secure checkout is being prepared. Try again in a moment.", 409);
      }
      await updatePaymentAttempt(activeAttempt.tx_ref, { status: "expired", failure_reason: "Checkout preparation timed out" });
    }

    txRef = `special-event-${booking.order_number}-${randomUUID()}`;
    try {
      await createPaymentAttempt({ booking_id: booking.id, tx_ref: txRef, amount: Number(booking.total_amount), currency: booking.currency, status: "initiated" });
    } catch (error) {
      const racedAttempt = await getActivePaymentAttempt(booking.id);
      if (racedAttempt?.status === "redirected" && racedAttempt.payment_url) {
        return res.json({ paymentUrl: racedAttempt.payment_url, txRef: racedAttempt.tx_ref, bookingId: booking.id });
      }
      throw error;
    }
    const response = await fetch(`${flutterwaveBaseUrl}/payments`, {
      method: "POST",
      headers: { Authorization: `Bearer ${secretKey}`, "content-type": "application/json" },
      body: JSON.stringify({
        tx_ref: txRef,
        amount: Number(booking.total_amount),
        currency: booking.currency,
        payment_options: "card",
        redirect_url: getReturnUrl(),
        customer: { email: booking.guest_email, name: `${booking.guest_first_name} ${booking.guest_last_name}`.trim(), phonenumber: booking.guest_phone },
        meta: { booking_id: booking.id, order_number: booking.order_number },
        customizations: { title: "Special Events", description: `Event booking ${booking.order_number}` },
      }),
    });
    const payload = await response.json().catch(() => null) as { status?: string; message?: string; data?: { link?: string } } | null;
    if (!response.ok || payload?.status !== "success" || !payload.data?.link) {
      const providerMessage = typeof payload?.message === "string" ? payload.message : "Flutterwave did not return a checkout link";
      throw new SpecialEventPaymentError(`Flutterwave checkout failed: ${providerMessage}`, 502);
    }
    await updatePaymentAttempt(txRef, { status: "redirected", payment_url: payload.data.link });
    return res.json({ paymentUrl: payload.data.link, txRef, bookingId: booking.id });
  } catch (error) {
    console.error("Special event checkout initialization failed", { bookingId, txRef, error });
    if (txRef) await updatePaymentAttempt(txRef, { status: "failed", failure_reason: error instanceof Error ? error.message : "Unable to prepare event payment" }).catch(() => undefined);
    return res.status(error instanceof SpecialEventPaymentError ? error.status : 502).json({ error: error instanceof Error ? error.message : "Unable to prepare event payment" });
  }
};

export const verifySpecialEventPayment: RequestHandler = async (req, res) => {
  try {
    const { transactionId, txRef } = req.body as { transactionId?: string | number; txRef?: string };
    if (!transactionId || !txRef) return res.status(400).json({ error: "Event payment verification details are required" });
    const attempt = await getPaymentAttemptAsService(txRef);
    const booking = await getBooking(attempt.booking_id, req.headers.authorization);
    const transaction = await verifyTransaction(String(transactionId));
    assertTransactionMatches(transaction, attempt, booking);
    if (attempt.status !== "successful" && attempt.status !== "manual_review") {
      await updatePaymentAttempt(txRef, { transaction_id: String(transaction.id), status: "verified" });
    }
    const confirmation = await confirmBookingAsService(booking.id, String(transaction.id));
    return res.json({ bookingId: confirmation.booking_id, orderNumber: confirmation.order_number, confirmationNumber: confirmation.confirmation_number, ticketCode: confirmation.ticket_code, paymentStatus: confirmation.payment_status });
  } catch (error) {
    return res.status(error instanceof SpecialEventPaymentError ? error.status : 400).json({ error: error instanceof Error ? error.message : "Unable to verify event payment" });
  }
};

export const cancelSpecialEventPayment: RequestHandler = async (req, res) => {
  try {
    const { txRef, status } = req.body as { txRef?: string; status?: "cancelled" | "failed" };
    if (!txRef || (status !== "cancelled" && status !== "failed")) return res.status(400).json({ error: "Event payment outcome is invalid" });
    const attempt = await getPaymentAttemptAsService(txRef);
    await getBooking(attempt.booking_id, req.headers.authorization);
    if (attempt.status === "successful" || attempt.status === "manual_review") {
      return res.json({ bookingId: attempt.booking_id, paymentStatus: attempt.status });
    }
    if (attempt.status === "initiated" || attempt.status === "redirected") {
      await updatePaymentAttempt(txRef, status === "cancelled" ? { status, cancelled_at: new Date().toISOString() } : { status, failure_reason: "Flutterwave returned an unsuccessful payment status" });
    }
    return res.json({ bookingId: attempt.booking_id, paymentStatus: status });
  } catch (error) {
    return res.status(error instanceof SpecialEventPaymentError ? error.status : 400).json({ error: error instanceof Error ? error.message : "Unable to record event payment cancellation" });
  }
};

export const handleSpecialEventWebhook: RequestHandler = async (req, res) => {
  const { secretHash } = getConfiguration();
  if (!secretHash) {
    console.error("Special event webhook secret is not configured");
    return res.status(503).end();
  }
  if (req.headers["verif-hash"] !== secretHash) return res.status(401).end();
  const payload = req.body as { event?: string; data?: { id?: string | number; tx_ref?: string } };
  if (payload.event !== "charge.completed" || !payload.data?.id || !payload.data.tx_ref) return res.status(200).end();
  try {
    const attempt = await getPaymentAttemptAsService(payload.data.tx_ref);
    const booking = await getBookingAsService(attempt.booking_id);
    const transaction = await verifyTransaction(String(payload.data.id));
    assertTransactionMatches(transaction, attempt, booking);
    if (attempt.status !== "successful" && attempt.status !== "manual_review") {
      await updatePaymentAttempt(payload.data.tx_ref, { transaction_id: String(transaction.id), status: "verified" });
    }
    await confirmBookingAsService(booking.id, String(transaction.id));
    return res.status(200).end();
  } catch (error) {
    console.error("Special event webhook processing error", error);
    return res.status(500).end();
  }
};
