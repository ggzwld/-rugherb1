import { FormEvent, useRef, useState } from "react";
import { format } from "date-fns";
import { AlertCircle, ArrowLeft, ArrowRight, CalendarDays, CheckCircle, CreditCard, LockKeyhole, Mail, Phone, User } from "lucide-react";
import { Badge } from "../ui/badge";
import { Button } from "../ui/button";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "../ui/dialog";
import { Input } from "../ui/input";
import { Separator } from "../ui/separator";
import { supabase } from "../../lib/supabase";

type RoomData = {
  id: string;
  name: string;
  nightly_rate: number;
  currency_code: string;
  image_url: string | null;
  size_sqm: number | null;
  max_guests: number;
};

type BookingQuote = {
  booking_id: string;
  confirmation_number: string;
  currency_code: string;
  nights: number;
  nightly_subtotal: number;
  discount_amount: number;
  taxable_subtotal: number;
  vat_amount: number;
  lht_amount: number;
  total_amount: number;
  hotel_classification: number;
  expires_at: string;
};

interface BookingCheckoutModalProps {
  isOpen: boolean;
  onClose: () => void;
  roomData: RoomData | null;
  checkIn?: Date;
  checkOut?: Date;
  guests: string;
  roomCount: string;
  preferences: string[];
  specialRequests: string;
  totalNights: number;
  totalPrice: number;
  savings: number;
}

const money = (value: number, currency: string) => new Intl.NumberFormat(undefined, { style: "currency", currency }).format(value || 0);
const makeAccessToken = () => {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
};

const BookingCheckoutModal = ({ isOpen, onClose, roomData, checkIn, checkOut, guests, roomCount, preferences, specialRequests, totalNights, totalPrice, savings }: BookingCheckoutModalProps) => {
  const [step, setStep] = useState<"details" | "payment">("details");
  const [guestInfo, setGuestInfo] = useState({ firstName: "", lastName: "", email: "", phone: "" });
  const [bookingQuote, setBookingQuote] = useState<BookingQuote | null>(null);
  const [loading, setLoading] = useState(false);
  const [errorMessage, setErrorMessage] = useState("");
  const idempotencyKey = useRef(crypto.randomUUID());
  const accessToken = useRef(makeAccessToken());
  const currency = bookingQuote?.currency_code || roomData?.currency_code.trim() || "USD";

  const requestJson = async (url: string, body: unknown) => {
    const { data: { session } } = await supabase.auth.getSession();
    const response = await fetch(url, { method: "POST", headers: { "content-type": "application/json", ...(session?.access_token ? { Authorization: `Bearer ${session.access_token}` } : {}) }, body: JSON.stringify(body) });
    const payload = await response.json().catch(() => null) as (BookingQuote & { accessToken?: string; paymentUrl?: string; error?: string }) | null;
    if (!response.ok || !payload) throw new Error(payload?.error || "We could not complete this request. Please try again.");
    return payload;
  };

  const handleStartPayment = async (event: FormEvent) => {
    event.preventDefault();
    if (!roomData || !checkIn || !checkOut) return;
    setLoading(true);
    setErrorMessage("");
    try {
      let currentBooking = bookingQuote;
      if (!currentBooking) {
        const created = await requestJson("/api/hotel-bookings/create", {
          roomId: roomData.id,
          guest: guestInfo,
          checkIn: format(checkIn, "yyyy-MM-dd"),
          checkOut: format(checkOut, "yyyy-MM-dd"),
          guestCount: Number(guests),
          roomCount: Number(roomCount),
          specialRequests,
          preferences,
          idempotencyKey: idempotencyKey.current,
          accessToken: accessToken.current,
        });
        currentBooking = {
          booking_id: created.booking_id,
          confirmation_number: created.confirmation_number,
          currency_code: created.currency_code.trim(),
          nights: Number(created.nights),
          nightly_subtotal: Number(created.nightly_subtotal),
          discount_amount: Number(created.discount_amount),
          taxable_subtotal: Number(created.taxable_subtotal),
          vat_amount: Number(created.vat_amount),
          lht_amount: Number(created.lht_amount),
          total_amount: Number(created.total_amount),
          hotel_classification: Number(created.hotel_classification),
          expires_at: created.expires_at,
        };
        setBookingQuote(currentBooking);
        localStorage.setItem("hotel-booking-access", JSON.stringify({ bookingId: currentBooking.booking_id, accessToken: accessToken.current, confirmationNumber: currentBooking.confirmation_number }));
        return;
      }
      if (new Date(currentBooking.expires_at).getTime() <= Date.now()) throw new Error("Your room hold expired. Close this window and select the room again.");
      const session = await requestJson("/api/payments/hotel/session", { bookingId: currentBooking.booking_id, accessToken: accessToken.current });
      if (!session.paymentUrl) throw new Error("Secure checkout link was not returned. Please try again.");
      window.location.assign(session.paymentUrl);
    } catch (error) {
      setErrorMessage(error instanceof Error ? error.message : "Unable to start secure checkout. Please try again.");
    } finally {
      setLoading(false);
    }
  };

  const resetAndClose = () => {
    if (bookingQuote) {
      void fetch("/api/hotel-bookings/cancel-hold", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ bookingId: bookingQuote.booking_id, accessToken: accessToken.current }),
      }).then((response) => {
        if (response.ok) localStorage.removeItem("hotel-booking-access");
      }).catch(() => undefined);
    }
    setStep("details");
    setGuestInfo({ firstName: "", lastName: "", email: "", phone: "" });
    setBookingQuote(null);
    setErrorMessage("");
    idempotencyKey.current = crypto.randomUUID();
    accessToken.current = makeAccessToken();
    onClose();
  };

  if (!roomData) return null;

  return (
    <Dialog open={isOpen} onOpenChange={(open) => { if (!open && !loading) resetAndClose(); }}>
      <DialogContent className="max-h-[90vh] max-w-2xl overflow-y-auto">
        <DialogHeader><DialogTitle className="flex items-center gap-2 text-sheraton-navy"><CreditCard className="h-5 w-5 text-sheraton-gold" />Complete your reservation</DialogTitle></DialogHeader>
        <div className="rounded-xl bg-sheraton-cream p-4"><div className="flex items-start justify-between gap-4"><div><div className="mb-1 flex flex-wrap items-center gap-2"><h2 className="font-semibold">{roomData.name}</h2><Badge variant="outline">{currency}</Badge></div><p className="text-sm text-muted-foreground"><CalendarDays className="mr-1 inline h-3.5 w-3.5" />{format(checkIn!, "MMM d, yyyy")} – {format(checkOut!, "MMM d, yyyy")} · {totalNights} {totalNights === 1 ? "night" : "nights"}</p><p className="mt-1 text-sm text-muted-foreground">{guests} guests · {roomCount} {Number(roomCount) === 1 ? "room" : "rooms"}</p></div><p className="text-right text-sm font-semibold">{money(Number(roomData.nightly_rate), currency)}<span className="block text-xs font-normal text-muted-foreground">per night</span></p></div></div>

        <div className="my-1 flex items-center justify-center gap-4 text-xs"><span className={step === "details" ? "font-semibold text-sheraton-navy" : "text-muted-foreground"}><User className="mr-1 inline h-3.5 w-3.5" />Guest details</span><span className="h-px w-8 bg-border" /><span className={step === "payment" ? "font-semibold text-sheraton-navy" : "text-muted-foreground"}><CreditCard className="mr-1 inline h-3.5 w-3.5" />Payment</span></div>

        {step === "details" ? <form onSubmit={(event) => { event.preventDefault(); setStep("payment"); }} className="space-y-5">
          <div><h3 className="font-semibold">Primary guest</h3><p className="text-sm text-muted-foreground">Your reservation details and receipt will be sent to this email address.</p></div>
          <div className="grid gap-4 sm:grid-cols-2"><div className="space-y-2"><label htmlFor="hotel-first-name" className="text-sm font-medium">First name</label><Input id="hotel-first-name" autoComplete="given-name" value={guestInfo.firstName} onChange={(event) => setGuestInfo({ ...guestInfo, firstName: event.target.value })} maxLength={100} required /></div><div className="space-y-2"><label htmlFor="hotel-last-name" className="text-sm font-medium">Last name</label><Input id="hotel-last-name" autoComplete="family-name" value={guestInfo.lastName} onChange={(event) => setGuestInfo({ ...guestInfo, lastName: event.target.value })} maxLength={100} required /></div><div className="space-y-2"><label htmlFor="hotel-email" className="text-sm font-medium"><Mail className="mr-1 inline h-3.5 w-3.5" />Email address</label><Input id="hotel-email" type="email" autoComplete="email" value={guestInfo.email} onChange={(event) => setGuestInfo({ ...guestInfo, email: event.target.value })} maxLength={254} required /></div><div className="space-y-2"><label htmlFor="hotel-phone" className="text-sm font-medium"><Phone className="mr-1 inline h-3.5 w-3.5" />Phone number</label><Input id="hotel-phone" type="tel" autoComplete="tel" value={guestInfo.phone} onChange={(event) => setGuestInfo({ ...guestInfo, phone: event.target.value })} maxLength={40} required /></div></div>
          <div className="flex gap-3"><Button type="button" variant="outline" className="flex-1" onClick={resetAndClose}>Cancel</Button><Button type="submit" className="flex-1 sheraton-gradient text-white">Review payment<ArrowRight className="ml-2 h-4 w-4" /></Button></div>
        </form> : <form onSubmit={handleStartPayment} className="space-y-5">
          <div className="rounded-lg border p-4"><h3 className="font-semibold">Price breakdown</h3><div className="mt-3 space-y-2 text-sm"><div className="flex justify-between"><span>Accommodation · {totalNights} nights</span><span>{money(bookingQuote?.nightly_subtotal ?? totalPrice + savings, currency)}</span></div>{(bookingQuote?.discount_amount ?? savings) > 0 && <div className="flex justify-between text-green-700"><span>Extended-stay discount</span><span>−{money(bookingQuote?.discount_amount ?? savings, currency)}</span></div>}<div className="flex justify-between"><span>Taxable accommodation</span><span>{money(bookingQuote?.taxable_subtotal ?? totalPrice, currency)}</span></div><div className="flex justify-between"><span>Uganda VAT · 18%</span><span>{bookingQuote ? money(bookingQuote.vat_amount, currency) : "Calculated at hold"}</span></div><div className="flex justify-between"><span>Local Hotel Tax · {bookingQuote ? `${bookingQuote.hotel_classification}-star property` : "classification-based"}</span><span>{bookingQuote ? money(bookingQuote.lht_amount, currency) : "Calculated at hold"}</span></div><Separator /><div className="flex justify-between font-semibold"><span>Amount due</span><span>{bookingQuote ? money(bookingQuote.total_amount, currency) : "Final amount confirmed securely"}</span></div></div><p className="mt-3 text-xs leading-5 text-muted-foreground">The property classification and timestamped exchange-rate snapshot determine the Local Hotel Tax. The complete tax breakdown is saved with your reservation before payment.</p></div>
          <div className="rounded-lg border border-sheraton-gold/30 bg-sheraton-gold/5 p-4"><div className="flex gap-3"><LockKeyhole className="mt-0.5 h-5 w-5 shrink-0 text-sheraton-gold" /><div><h3 className="font-medium">Secure payment with Flutterwave</h3><p className="mt-1 text-sm text-muted-foreground">You’ll be redirected to Flutterwave’s secure payment page. Card details are never collected or stored by the hotel booking page.{currency === "UGX" ? " Mobile money and card payment are supported." : " Card payment is supported for this currency."}</p></div></div></div>
          {bookingQuote && <div className="rounded-lg bg-muted/40 p-3 text-sm"><div className="flex justify-between gap-3"><span className="text-muted-foreground">Reservation hold</span><span className="font-medium">Expires {new Date(bookingQuote.expires_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</span></div><div className="mt-1 flex justify-between gap-3"><span className="text-muted-foreground">Confirmation reference</span><span className="font-mono font-medium">{bookingQuote.confirmation_number}</span></div><p className="mt-1 text-xs text-muted-foreground">Rates and tax calculation are locked for this reservation.</p></div>}
          {errorMessage && <div role="alert" className="flex gap-2 rounded-lg border border-destructive/30 bg-destructive/5 p-3 text-sm text-destructive"><AlertCircle className="h-4 w-4 shrink-0" />{errorMessage}</div>}
          <div className="flex flex-wrap gap-3">{bookingQuote ? <Button type="button" variant="outline" className="flex-1" onClick={resetAndClose} disabled={loading}>Release room hold</Button> : <Button type="button" variant="outline" className="flex-1" onClick={() => setStep("details")} disabled={loading}><ArrowLeft className="mr-2 h-4 w-4" />Guest details</Button>}<Button type="submit" className="flex-1 sheraton-gradient text-white" disabled={loading}>{loading ? bookingQuote ? "Preparing secure checkout…" : "Calculating secure total…" : bookingQuote ? `Continue to payment · ${money(bookingQuote.total_amount, currency)}` : "Calculate total & hold room"}<ArrowRight className="ml-2 h-4 w-4" /></Button></div>
          <p className="flex items-center justify-center gap-1 text-center text-xs text-muted-foreground"><CheckCircle className="h-3.5 w-3.5 text-green-600" />{bookingQuote ? "Review the full tax breakdown above before continuing to Flutterwave." : "We’ll reserve availability for 20 minutes while you review your final total."}</p>
        </form>}
      </DialogContent>
    </Dialog>
  );
};

export default BookingCheckoutModal;
