import type { Request, RequestHandler } from "express";

const flutterwaveBaseUrl = "https://api.flutterwave.com/v3";
const flutterwaveReturnPath = "/checkout/flutterwave-return";

export class FlutterwaveRequestError extends Error {
  constructor(message: string, readonly status = 400) {
    super(message);
  }
}

const getFlutterwaveReturnUrl = () => {
  const returnUrl =
    process.env.NODE_ENV === "production"
      ? process.env.FLUTTERWAVE_RETURN_URL
      : process.env.FLUTTERWAVE_LOCAL_RETURN_URL;

  if (!returnUrl) throw new Error("Flutterwave return URL is not configured");

  const parsedUrl = new URL(returnUrl);
  if (parsedUrl.protocol !== "https:" || parsedUrl.pathname !== flutterwaveReturnPath) {
    throw new Error("Flutterwave return URL must use HTTPS and target the payment return route");
  }

  return parsedUrl.toString();
};

type MenuOrder = {
  id: string;
  user_id: string;
  order_number: string;
  payment_method: string;
  payment_status: string;
  pricing_version: number;
  currency?: string | null;
  payment_reference?: string | null;
  flutterwave_transaction_id?: string | null;
  total_amount: number | string;
  email: string | null;
  first_name: string;
  last_name: string;
  phone: string;
};

type MenuPaymentAttempt = {
  id: string;
  order_id: string;
  tx_ref: string;
  transaction_id: string | null;
  amount: number | string;
  currency: string;
  status: string;
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
  const defaultCurrency = process.env.FLUTTERWAVE_CURRENCY || "USD";

  if (
    !secretKey ||
    !secretHash ||
    !supabaseUrl ||
    !supabaseAnonKey ||
    !supabaseServiceRoleKey
  ) {
    throw new Error("Flutterwave payment configuration is incomplete");
  }

  return {
    secretKey,
    secretHash,
    supabaseUrl,
    supabaseAnonKey,
    supabaseServiceRoleKey,
    defaultCurrency,
  };
};

const getAuthenticatedOrder = async (orderId: string, authorization?: string) => {
  if (!authorization?.startsWith("Bearer ")) {
    throw new Error("Missing authenticated session");
  }

  const { supabaseUrl, supabaseAnonKey } = getConfiguration();
  const response = await fetch(
    `${supabaseUrl}/rest/v1/menu_orders?id=eq.${encodeURIComponent(orderId)}&select=*`,
    {
      headers: {
        apikey: supabaseAnonKey,
        authorization,
      },
    },
  );

  if (!response.ok) throw new Error("Unable to retrieve this order");

  const [order] = (await response.json()) as MenuOrder[];
  if (!order) throw new Error("Order not found");
  return order;
};

const getPaymentAttempt = async (txRef: string) => {
  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getConfiguration();
  const response = await fetch(
    `${supabaseUrl}/rest/v1/menu_payment_attempts?tx_ref=eq.${encodeURIComponent(txRef)}&select=id,order_id,tx_ref,transaction_id,amount,currency,status`,
    { headers: { apikey: supabaseAnonKey, Authorization: `Bearer ${supabaseServiceRoleKey}` } },
  );
  if (!response.ok) throw new Error("Unable to retrieve payment attempt");
  const [attempt] = await response.json() as MenuPaymentAttempt[];
  if (!attempt) throw new Error("Payment attempt not found");
  return attempt;
};

const getOrderByIdAsService = async (orderId: string) => {
  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getConfiguration();
  const response = await fetch(
    `${supabaseUrl}/rest/v1/menu_orders?id=eq.${encodeURIComponent(orderId)}&select=*`,
    { headers: { apikey: supabaseAnonKey, Authorization: `Bearer ${supabaseServiceRoleKey}` } },
  );
  if (!response.ok) throw new Error("Unable to retrieve payment order");
  const [order] = await response.json() as MenuOrder[];
  if (!order) throw new Error("Payment order not found");
  return order;
};

const getOrderByPaymentReference = async (paymentReference: string) => {
  const attempt = await getPaymentAttempt(paymentReference);
  return getOrderByIdAsService(attempt.order_id);
};

const updatePaymentAttemptAsService = async (txRef: string, values: Record<string, unknown>) => {
  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getConfiguration();
  const response = await fetch(
    `${supabaseUrl}/rest/v1/menu_payment_attempts?tx_ref=eq.${encodeURIComponent(txRef)}`,
    {
      method: "PATCH",
      headers: {
        apikey: supabaseAnonKey,
        Authorization: `Bearer ${supabaseServiceRoleKey}`,
        "content-type": "application/json",
        prefer: "return=minimal",
      },
      body: JSON.stringify({ ...values, updated_at: new Date().toISOString() }),
    },
  );

  if (!response.ok) throw new Error("Unable to update payment attempt");
};

const updatePendingOrderAsService = async (orderId: string, values: Record<string, unknown>, paymentReference?: string) => {
  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getConfiguration();
  const referenceFilter = paymentReference ? `&payment_reference=eq.${encodeURIComponent(paymentReference)}` : "";
  const response = await fetch(
    `${supabaseUrl}/rest/v1/menu_orders?id=eq.${encodeURIComponent(orderId)}&status=eq.pending&payment_status=eq.pending${referenceFilter}&select=id`,
    {
      method: "PATCH",
      headers: {
        apikey: supabaseAnonKey,
        Authorization: `Bearer ${supabaseServiceRoleKey}`,
        "content-type": "application/json",
        prefer: "return=representation",
      },
      body: JSON.stringify(values),
    },
  );
  if (!response.ok) throw new Error("Unable to update payment order");
  return (await response.json() as Array<{ id: string }>).length === 1;
};

const getPaymentOptions = (paymentMethod: string, currency: string) => {
  if (paymentMethod !== "mobile-money") return "card";
  if (currency !== "UGX") {
    throw new Error("Mobile Money is available only when checkout prices are configured in UGX.");
  }
  return "mobilemoneyuganda";
};

const verifyTransaction = async (transactionId: string) => {
  const { secretKey } = getConfiguration();
  const response = await fetch(
    `${flutterwaveBaseUrl}/transactions/${encodeURIComponent(transactionId)}/verify`,
    { headers: { Authorization: `Bearer ${secretKey}` } },
  );
  const payload = await response.json();

  if (!response.ok || payload.status !== "success" || !payload.data) {
    throw new Error("Payment could not be verified");
  }

  return payload.data as FlutterwaveTransaction;
};

const confirmPayment = async (
  transaction: FlutterwaveTransaction,
  transactionReference: string,
  order: MenuOrder,
) => {
  const metadataOrderId = transaction.meta?.order_id;
  if (metadataOrderId !== order.id) {
    throw new Error("Payment metadata does not match the order");
  }

  const { defaultCurrency } = getConfiguration();
  const currency = String(order.currency || defaultCurrency).toUpperCase();

  if (
    transaction.status !== "successful" ||
    transaction.tx_ref !== transactionReference ||
    Number(transaction.amount) !== Number(order.total_amount) ||
    transaction.currency !== currency
  ) {
    throw new Error("Payment verification data does not match the order");
  }

  const attempt = await getPaymentAttempt(transactionReference);
  if (
    Number(attempt.amount) !== Number(order.total_amount)
    || attempt.currency.toUpperCase() !== currency
    || attempt.order_id !== order.id
  ) {
    throw new Error("Payment attempt does not match the order total");
  }

  if (order.payment_status === "paid") {
    if (order.flutterwave_transaction_id === String(transaction.id)) {
      return { order, paymentStatus: "paid" as const };
    }
    await updatePaymentAttemptAsService(transactionReference, {
      transaction_id: String(transaction.id),
      status: "manual_review",
      failure_reason: "A second successful payment was received for an already-paid order",
      completed_at: new Date().toISOString(),
    });
    return { order, paymentStatus: "manual_review" as const };
  }

  const confirmed = await updatePendingOrderAsService(order.id, {
    status: "confirmed",
    payment_status: "paid",
    payment_reference: transactionReference,
    flutterwave_transaction_id: String(transaction.id),
  });
  if (!confirmed) {
    const current = await getOrderByIdAsService(order.id);
    if (current.payment_status === "paid" && current.flutterwave_transaction_id === String(transaction.id)) {
      return { order: current, paymentStatus: "paid" as const };
    }
    await updatePaymentAttemptAsService(transactionReference, {
      transaction_id: String(transaction.id),
      status: "manual_review",
      failure_reason: "A second successful payment was received for an already-paid order",
      completed_at: new Date().toISOString(),
    });
    return { order: current, paymentStatus: "manual_review" as const };
  }
  await updatePaymentAttemptAsService(transactionReference, {
    transaction_id: String(transaction.id),
    status: "completed",
    completed_at: new Date().toISOString(),
  });

  return { order: { ...order, payment_status: "paid", flutterwave_transaction_id: String(transaction.id) }, paymentStatus: "paid" as const };
};

type FlutterwaveHostedSessionInput = { orderId?: string };

const createMenuPaymentAttempt = async (order: MenuOrder, txRef: string) => {
  const { supabaseUrl, supabaseAnonKey, supabaseServiceRoleKey } = getConfiguration();
  const response = await fetch(`${supabaseUrl}/rest/v1/rpc/create_menu_payment_attempt`, {
    method: "POST",
    headers: {
      apikey: supabaseAnonKey,
      Authorization: `Bearer ${supabaseServiceRoleKey}`,
      "content-type": "application/json",
      Prefer: "return=representation",
    },
    body: JSON.stringify({ target_order_id: order.id, target_user_id: order.user_id, target_tx_ref: txRef }),
  });
  const payload = await response.json().catch(() => null) as Array<{
    attempt_id: string;
    attempt_tx_ref: string;
    attempt_status: string;
    attempt_payment_url: string | null;
  }> | { message?: string } | null;
  if (!response.ok) {
    const message = payload && !Array.isArray(payload) && typeof payload.message === "string"
      ? payload.message
      : "Unable to create a secure payment attempt";
    throw new Error(message);
  }
  const [attempt] = Array.isArray(payload) ? payload : [];
  if (!attempt) throw new Error("Payment attempt was not returned");
  return attempt;
};

export const prepareFlutterwaveHostedSession = async (
  { orderId }: FlutterwaveHostedSessionInput,
  authorization?: string,
) => {
  let txRef: string | undefined;

  try {
    if (!orderId) throw new Error("Order ID is required");
    const order = await getAuthenticatedOrder(orderId, authorization);
    if (order.payment_status === "paid") {
      throw new FlutterwaveRequestError("This order has already been paid", 409);
    }
    if (!order.email?.trim()) {
      throw new FlutterwaveRequestError("An email address is required for online payment.", 400);
    }

    const { secretKey } = getConfiguration();
    const requestedTxRef = `sheraton-${order.order_number}-${crypto.randomUUID()}`;
    const attempt = await createMenuPaymentAttempt(order, requestedTxRef);
    txRef = attempt.attempt_tx_ref;
    if (attempt.attempt_status === "redirected" && attempt.attempt_payment_url) {
      return { paymentUrl: attempt.attempt_payment_url, txRef, orderId: order.id };
    }
    const storedAttempt = await getPaymentAttempt(txRef);
    const amount = Number(storedAttempt.amount);
    const currency = storedAttempt.currency.toUpperCase();
    if (!Number.isFinite(amount) || amount <= 0 || amount !== Number(order.total_amount) || currency !== String(order.currency || "").toUpperCase()) {
      throw new Error("Stored payment attempt does not match the order total");
    }

    const response = await fetch(`${flutterwaveBaseUrl}/payments`, {
      method: "POST",
      headers: { Authorization: `Bearer ${secretKey}`, "content-type": "application/json" },
      body: JSON.stringify({
        tx_ref: txRef,
        amount,
        currency,
        payment_options: getPaymentOptions(order.payment_method, currency),
        redirect_url: getFlutterwaveReturnUrl(),
        customer: {
          email: order.email,
          name: `${order.first_name} ${order.last_name}`.trim(),
          phonenumber: order.phone,
        },
        meta: { order_id: order.id },
        customizations: { title: "Sheraton Special", description: `Order ${order.order_number}` },
      }),
    });
    const payload = await response.json() as { status?: string; data?: { link?: string } };
    if (!response.ok || payload.status !== "success" || !payload.data?.link) {
      throw new Error("Unable to create secure payment page");
    }

    await updatePaymentAttemptAsService(txRef, { status: "redirected", payment_url: payload.data.link });
    return { paymentUrl: payload.data.link, txRef, orderId: order.id };
  } catch (error) {
    if (txRef) {
      await updatePaymentAttemptAsService(txRef, {
        status: "failed",
        failure_reason: error instanceof Error ? error.message : "Unable to prepare payment",
      }).catch((attemptError) => console.error("Unable to record failed payment attempt", attemptError));
    }
    throw error;
  }
};

export const createFlutterwaveHostedSession: RequestHandler = async (req, res) => {
  try {
    const paymentSession = await prepareFlutterwaveHostedSession(
      req.body as FlutterwaveHostedSessionInput,
      req.headers.authorization,
    );
    return res.json(paymentSession);
  } catch (error) {
    console.error("Flutterwave hosted session error", error);
    return res.status(error instanceof FlutterwaveRequestError ? error.status : 400).json({
      error: error instanceof Error ? error.message : "Unable to prepare payment",
    });
  }
};

export const cancelFlutterwavePayment: RequestHandler = async (req, res) => {
  try {
    const { txRef, status } = req.body as {
      txRef?: string;
      status?: "cancelled" | "failed";
    };
    if (!txRef) return res.status(400).json({ error: "Payment reference is required" });
    if (status !== "cancelled" && status !== "failed") {
      return res.status(400).json({ error: "Payment outcome is invalid" });
    }

    const attempt = await getPaymentAttempt(txRef);
    const order = await getOrderByIdAsService(attempt.order_id);
    await getAuthenticatedOrder(order.id, req.headers.authorization);
    if (attempt.status === "completed" || attempt.status === "manual_review" || order.payment_status === "paid") {
      return res.json({ orderId: order.id, paymentStatus: order.payment_status });
    }
    if (attempt.status === "initiated" || attempt.status === "redirected") {
      await updatePaymentAttemptAsService(txRef, {
        status,
        ...(status === "cancelled"
          ? { cancelled_at: new Date().toISOString() }
          : { failure_reason: "Flutterwave returned an unsuccessful payment status" }),
      });
      await updatePendingOrderAsService(order.id, { payment_status: status }, txRef);
    }
    return res.json({ orderId: order.id, paymentStatus: status });
  } catch (error) {
    console.error("Flutterwave payment cancellation error", error);
    return res.status(400).json({
      error: error instanceof Error ? error.message : "Unable to record payment cancellation",
    });
  }
};

export const verifyFlutterwavePayment: RequestHandler = async (req, res) => {
  try {
    const { transactionId, txRef } = req.body as {
      transactionId?: string | number;
      txRef?: string;
    };
    if (!transactionId || !txRef) {
      return res.status(400).json({ error: "Payment verification details are required" });
    }

    const order = await getOrderByPaymentReference(txRef);
    await getAuthenticatedOrder(order.id, req.headers.authorization);
    const transaction = await verifyTransaction(String(transactionId));
    const result = await confirmPayment(transaction, txRef, order);

    return res.json({
      orderId: result.order.id,
      orderNumber: result.order.order_number,
      paymentStatus: result.paymentStatus,
    });
  } catch (error) {
    console.error("Flutterwave payment verification error", error);
    return res.status(400).json({
      error: error instanceof Error ? error.message : "Unable to verify payment",
    });
  }
};

export const handleFlutterwaveWebhook: RequestHandler = async (req, res) => {
  const signature = req.headers["verif-hash"];
  const { secretHash } = getConfiguration();

  if (!signature || signature !== secretHash) {
    return res.status(401).end();
  }

  const payload = req.body as {
    event?: string;
    data?: { id?: string | number; tx_ref?: string };
  };

  if (payload.event !== "charge.completed" || !payload.data?.id || !payload.data.tx_ref) {
    return res.status(200).end();
  }

  try {
    const order = await getOrderByPaymentReference(payload.data.tx_ref);
    await confirmPayment(
      await verifyTransaction(String(payload.data.id)),
      payload.data.tx_ref,
      order,
    );
    return res.status(200).end();
  } catch (error) {
    console.error("Flutterwave webhook processing error", error);
    return res.status(500).end();
  }
};
