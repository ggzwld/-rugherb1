import { useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { AlertCircle, ArrowLeft, CheckCircle, Loader2, RefreshCw } from "lucide-react";
import { Button } from "../components/ui/button";
import { clearPendingCheckout } from "../lib/flutterwave";
import { supabase } from "../lib/supabase";

type PaymentResult =
  | { status: "loading" }
  | { status: "success"; orderNumber: string; eventPayment: boolean; hotelBooking: boolean }
  | { status: "review"; orderNumber: string; hotelBooking: boolean }
  | { status: "cancelled"; message: string }
  | { status: "error"; message: string };

const readHotelAccess = () => {
  try {
    const stored = localStorage.getItem("hotel-booking-access");
    if (!stored) return null;
    const value = JSON.parse(stored) as { bookingId?: string; accessToken?: string; confirmationNumber?: string };
    return value.bookingId && value.accessToken ? value : null;
  } catch {
    return null;
  }
};

const getInitialPaymentResult = (searchParams: URLSearchParams): PaymentResult => {
  const status = searchParams.get("status");
  if (status === "cancelled") return { status: "cancelled", message: "The payment was cancelled. Your reservation is still saved while its temporary hold remains active." };
  if (status && status !== "successful") return { status: "error", message: "Flutterwave did not return a completed payment. Your reservation is saved so you can try payment again before the hold expires." };
  return { status: "loading" };
};

const FlutterwaveReturnPage = () => {
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const [result, setResult] = useState<PaymentResult>(() => getInitialPaymentResult(searchParams));
  const [verificationAttempt, setVerificationAttempt] = useState(0);
  const [retrying, setRetrying] = useState(false);

  useEffect(() => {
    let active = true;
    const verifyPayment = async () => {
      const transactionId = searchParams.get("transaction_id");
      const txRef = searchParams.get("tx_ref");
      const status = searchParams.get("status");
      const eventPayment = txRef?.startsWith("special-event-") ?? false;
      const hotelBooking = searchParams.get("flow") === "hotel" || (txRef?.startsWith("hotel-") ?? false);
      const hotelAccess = hotelBooking ? readHotelAccess() : null;
      const { data: { session } } = await supabase.auth.getSession();

      if (status !== "successful") {
        if (txRef && (hotelBooking || session?.access_token)) {
          try {
            await fetch(hotelBooking ? "/api/payments/hotel/cancel" : eventPayment ? "/api/payments/special-events/cancel" : "/api/payments/flutterwave/cancel", {
              method: "POST",
              headers: { ...(session?.access_token ? { Authorization: `Bearer ${session.access_token}` } : {}), "content-type": "application/json" },
              body: JSON.stringify({ txRef, status: status === "cancelled" ? "cancelled" : "failed", ...(hotelAccess ? { accessToken: hotelAccess.accessToken } : {}) }),
            });
          } catch (error) {
            console.error("Unable to record payment cancellation", error);
          }
        }
        if (active) setResult({ status: status === "cancelled" ? "cancelled" : "error", message: status === "cancelled" ? "The payment was cancelled. Your reservation is still saved while its temporary hold remains active." : "Flutterwave did not return a completed payment. Your reservation is saved so you can try payment again before the hold expires." });
        return;
      }
      if (!transactionId || !txRef) {
        if (active) setResult({ status: "error", message: "The payment response was incomplete. Return to the booking page and contact the hotel if the charge appears on your statement." });
        return;
      }
      if (!hotelBooking && !session?.access_token) {
        if (active) setResult({ status: "error", message: "Your session expired before payment could be confirmed. Sign in again, then retry this payment." });
        return;
      }

      try {
        const response = await fetch(hotelBooking ? "/api/payments/hotel/verify" : eventPayment ? "/api/payments/special-events/verify" : "/api/payments/flutterwave/verify", {
          method: "POST",
          headers: { ...(session?.access_token ? { Authorization: `Bearer ${session.access_token}` } : {}), "content-type": "application/json" },
          body: JSON.stringify({ transactionId, txRef, ...(hotelAccess ? { accessToken: hotelAccess.accessToken } : {}) }),
        });
        const payload = await response.json().catch(() => null) as { orderNumber?: string; confirmationNumber?: string; confirmation_number?: string; paymentStatus?: string; payment_status?: string; booking_status?: string; error?: string } | null;
        const orderNumber = payload?.orderNumber || payload?.confirmation_number || payload?.confirmationNumber;
        if (!response.ok || (!orderNumber && !hotelBooking)) throw new Error(payload?.error || `Payment could not be confirmed (HTTP ${response.status}).`);
        if ((eventPayment && payload?.paymentStatus === "manual_review") || (hotelBooking && (payload?.booking_status === "manual_review" || payload?.payment_status === "manual_review"))) {
          clearPendingCheckout();
          if (hotelBooking) localStorage.removeItem("hotel-booking-access");
          if (active) setResult({ status: "review", orderNumber: orderNumber || "Review required", hotelBooking });
          return;
        }
        const paymentStatus = hotelBooking ? payload?.payment_status || payload?.paymentStatus : payload?.paymentStatus;
        if (paymentStatus !== "paid") throw new Error(payload?.error || "Payment could not be confirmed.");
        clearPendingCheckout();
        if (hotelBooking) localStorage.removeItem("hotel-booking-access");
        if (active) setResult({ status: "success", orderNumber: orderNumber || "Confirmed", eventPayment, hotelBooking });
      } catch (error) {
        if (active) setResult({ status: "error", message: error instanceof Error ? error.message : "Payment could not be confirmed." });
      }
    };
    void verifyPayment();
    return () => { active = false; };
  }, [searchParams, verificationAttempt]);

  const txRef = searchParams.get("tx_ref");
  const eventPayment = txRef?.startsWith("special-event-") ?? false;
  const hotelBooking = searchParams.get("flow") === "hotel" || (txRef?.startsWith("hotel-") ?? false);
  const canRetryConfirmation = (eventPayment || hotelBooking) && searchParams.get("status") === "successful";
  const returnPath = eventPayment ? "/events" : hotelBooking ? "/book" : "/menu";
  const returnToPayment = async () => {
    if (canRetryConfirmation) {
      setResult({ status: "loading" });
      setVerificationAttempt((attempt) => attempt + 1);
      return;
    }
    if (hotelBooking) {
      const access = readHotelAccess();
      if (!access) {
        navigate("/book", { replace: true });
        return;
      }
      setRetrying(true);
      try {
        const response = await fetch("/api/payments/hotel/session", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ bookingId: access.bookingId, accessToken: access.accessToken }),
        });
        const payload = await response.json().catch(() => null) as { paymentUrl?: string; error?: string } | null;
        if (!response.ok || !payload?.paymentUrl) throw new Error(payload?.error || "Secure checkout could not be restarted.");
        window.location.assign(payload.paymentUrl);
      } catch (error) {
        setResult({ status: "error", message: error instanceof Error ? error.message : "Secure checkout could not be restarted." });
      } finally {
        setRetrying(false);
      }
      return;
    }
    navigate(returnPath, { replace: true });
  };
  const returnToPage = () => {
    clearPendingCheckout();
    navigate(eventPayment ? "/events?tab=my-tickets" : returnPath, { replace: true });
  };

  return (
    <div className="w-full bg-background"><main className="container py-8 sm:py-10"><div className="mx-auto max-w-2xl rounded-xl border bg-white p-6 text-center shadow-sm sm:p-10">
      {result.status === "loading" && <><Loader2 className="mx-auto h-12 w-12 animate-spin text-sheraton-gold" /><h1 className="mt-5 text-2xl font-semibold text-sheraton-navy">Confirming your payment</h1><p className="mt-2 text-muted-foreground">Please wait while we verify the transaction securely.</p></>}
      {result.status === "success" && <><CheckCircle className="mx-auto h-12 w-12 text-green-600" /><h1 className="mt-5 text-2xl font-semibold text-sheraton-navy">{result.hotelBooking ? "Stay confirmed" : result.eventPayment ? "Event booking confirmed" : "Order confirmed"}</h1><p className="mt-2 text-muted-foreground">{result.hotelBooking ? "Your payment is verified and your room reservation is confirmed. Your invoice and receipt will be sent to the guest email when Books email delivery is configured." : `Your payment was received and your ${result.eventPayment ? "event booking is confirmed" : "order is being prepared"}.`}</p><div className="mt-6 rounded-lg bg-sheraton-cream p-4"><p className="text-sm text-muted-foreground">{result.hotelBooking ? "Reservation confirmation" : "Order number"}</p><p className="mt-1 text-2xl font-bold text-sheraton-navy">{result.orderNumber}</p></div><Button onClick={returnToPage} className="mt-6 bg-sheraton-gold text-sheraton-navy hover:bg-sheraton-gold/90">{result.hotelBooking ? "Return to booking" : result.eventPayment ? "Return to Events" : "Return to Menu"}</Button></>}
      {result.status === "review" && <><AlertCircle className="mx-auto h-12 w-12 text-amber-600" /><h1 className="mt-5 text-2xl font-semibold text-sheraton-navy">Payment received — review required</h1><p className="mt-2 text-muted-foreground">{result.hotelBooking ? "Your payment was verified after the room hold expired or availability changed. The hotel must confirm an alternative stay or arrange a refund; this page does not mark the room as confirmed." : "Your payment was verified, but the available ticket capacity changed before confirmation. The event team must resolve this booking before tickets are issued."}</p><div className="mt-6 rounded-lg bg-sheraton-cream p-4"><p className="text-sm text-muted-foreground">{result.hotelBooking ? "Reservation reference" : "Order number"}</p><p className="mt-1 text-2xl font-bold text-sheraton-navy">{result.orderNumber}</p></div><Button onClick={returnToPage} className="mt-6 bg-sheraton-gold text-sheraton-navy hover:bg-sheraton-gold/90">{result.hotelBooking ? "Return to booking" : "Return to Events"}</Button></>}
      {(result.status === "cancelled" || result.status === "error") && <><AlertCircle className={`mx-auto h-12 w-12 ${result.status === "error" ? "text-red-600" : "text-amber-600"}`} /><h1 className="mt-5 text-2xl font-semibold text-sheraton-navy">{result.status === "cancelled" ? "Payment cancelled" : "Payment needs attention"}</h1><p className="mt-2 text-muted-foreground">{result.message}</p><div className="mt-6 flex flex-col justify-center gap-3 sm:flex-row"><Button onClick={() => void returnToPayment()} disabled={retrying} className="bg-sheraton-gold text-sheraton-navy hover:bg-sheraton-gold/90"><RefreshCw className="mr-2 h-4 w-4" />{retrying ? "Preparing secure checkout…" : canRetryConfirmation ? "Retry payment confirmation" : hotelBooking ? "Try payment again" : "Return to booking"}</Button><Button onClick={returnToPage} variant="outline"><ArrowLeft className="mr-2 h-4 w-4" />{hotelBooking ? "Return to booking" : eventPayment ? "Return to Events" : "Return to Menu"}</Button></div></>}
    </div></main></div>
  );
};

export default FlutterwaveReturnPage;
