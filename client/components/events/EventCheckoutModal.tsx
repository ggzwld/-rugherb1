import { useMemo, useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { useRef } from "react";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "../ui/dialog";
import { Button } from "../ui/button";
import { Input } from "../ui/input";
import { Textarea } from "../ui/textarea";
import { Separator } from "../ui/separator";
import { Badge } from "../ui/badge";
import { Progress } from "../ui/progress";
import { Calendar, MapPin, User, Phone, Mail, Receipt, CheckCircle, AlertCircle, CreditCard, Shield, ArrowLeft, ArrowRight, Minus, Plus, X, Ticket, Award, Download } from "lucide-react";
import { supabase } from "../../lib/supabase";
import { formatEventDate, type SpecialEvent } from "../../lib/events";

type CheckoutEvent = SpecialEvent & { quantity: number };

type Props = {
  isOpen: boolean;
  onClose: () => void;
  cart: Record<string, number>;
  events: SpecialEvent[];
  onUpdateCart: (eventId: string, quantity: number) => void;
  onRemoveFromCart: (eventId: string) => void;
  onClearCart: () => void;
  invitationId?: string | null;
  onBooked: () => void;
};

type Confirmation = {
  confirmationNumber: string;
  ticketCode: string;
  eventTitle: string;
  quantity: number;
  total: number;
  currency: string;
};

const formatMoney = (value: number, currency: string) => new Intl.NumberFormat(undefined, { style: "currency", currency, maximumFractionDigits: 2 }).format(value || 0);
const formatEntry = (value: number, currency: string) => value > 0 ? formatMoney(value, currency) : "Free";

const getCheckoutErrorMessage = (error: unknown) => {
  if (typeof error === "string" && error.trim()) return error.trim();
  if (!error || typeof error !== "object") return "Unable to complete event booking. Please try again.";
  const details = error as Record<string, unknown>;
  const messages = [details.message, details.details, details.hint]
    .filter((value): value is string => typeof value === "string" && Boolean(value.trim()));
  return [...new Set(messages)].join(" — ") || "Unable to complete event booking. Please try again.";
};

const EventCheckoutModal: React.FC<Props> = ({ isOpen, onClose, cart, events, onUpdateCart, onRemoveFromCart, onClearCart, invitationId = null, onBooked }) => {
  const navigate = useNavigate();
  const location = useLocation();
  const [step, setStep] = useState<"tickets" | "details" | "payment" | "confirmation">("tickets");
  const [guestInfo, setGuestInfo] = useState({ firstName: "", lastName: "", email: "", phone: "", company: "", dietaryRestrictions: "", specialRequests: "" });
  const [attendeeNames, setAttendeeNames] = useState<string[]>([]);
  const [isProcessing, setIsProcessing] = useState(false);
  const [errorMessage, setErrorMessage] = useState("");
  const [confirmation, setConfirmation] = useState<Confirmation | null>(null);
  const [serverQuote, setServerQuote] = useState<{ amount: number; currency: string; fingerprint: string } | null>(null);
  const idempotencyKey = useRef<string | null>(null);
  const idempotencyFingerprint = useRef<string | null>(null);

  const cartItems = useMemo(() => Object.entries(cart).map(([eventId, quantity]) => {
    const event = events.find((candidate) => candidate.id === eventId);
    return event ? { ...event, quantity } : null;
  }).filter((item): item is CheckoutEvent => Boolean(item)), [cart, events]);
  const selectedEvent = cartItems[0];
  const previewSubtotal = selectedEvent ? selectedEvent.price * selectedEvent.quantity : 0;
  const currentFingerprint = JSON.stringify({
    eventId: selectedEvent?.id,
    quantity: selectedEvent?.quantity,
    ticketTypeId: selectedEvent?.default_ticket_type_id,
    guestInfo,
    attendeeNames: attendeeNames.slice(0, selectedEvent?.quantity || 0).map((name) => name.trim()),
    invitationId,
  });
  const quoteIsCurrent = serverQuote?.fingerprint === currentFingerprint;
  const subtotal = quoteIsCurrent ? serverQuote.amount : previewSubtotal;
  const total = subtotal;

  const resetModal = () => {
    setStep("tickets");
    setGuestInfo({ firstName: "", lastName: "", email: "", phone: "", company: "", dietaryRestrictions: "", specialRequests: "" });
    setIsProcessing(false);
    setErrorMessage("");
    setConfirmation(null);
    setAttendeeNames([]);
    setServerQuote(null);
    idempotencyKey.current = null;
    idempotencyFingerprint.current = null;
  };

  const handleClose = () => {
    resetModal();
    onClose();
  };

  const validateStep = () => {
    if (step === "tickets") return cartItems.length === 1 && Boolean(selectedEvent);
    if (step === "details") return Boolean(guestInfo.firstName.trim() && guestInfo.lastName.trim() && guestInfo.email.trim() && selectedEvent && attendeeNames.length >= selectedEvent.quantity && attendeeNames.slice(0, selectedEvent.quantity).every((name) => name.trim()));
    return true;
  };

  const handleNext = () => {
    setErrorMessage("");
    if (!validateStep()) {
      setErrorMessage(step === "tickets" ? "Please select one event to book at a time." : "Complete the required guest details.");
      return;
    }
    if (step === "tickets") setStep("details");
    else if (step === "details") setStep(total > 0 ? "payment" : "confirmation");
    else if (step === "payment") setStep("confirmation");
  };

  const handleBack = () => {
    setErrorMessage("");
    if (step === "details") setStep("tickets");
    else if (step === "payment") setStep("details");
    else if (step === "confirmation") setStep(total > 0 ? "payment" : "details");
  };

  const startHostedPayment = async (bookingId: string) => {
    const { data: sessionData } = await supabase.auth.getSession();
    if (!sessionData.session?.access_token) {
      const returnTo = `${location.pathname}${location.search}`;
      navigate(`/login?returnTo=${encodeURIComponent(returnTo)}`);
      return;
    }
    const response = await fetch("/api/payments/special-events/session", {
      method: "POST",
      headers: { Authorization: `Bearer ${sessionData.session.access_token}`, "content-type": "application/json" },
      body: JSON.stringify({ bookingId }),
    });
    const payload = await response.json().catch(() => null) as { paymentUrl?: string; error?: string } | null;
    if (!response.ok || !payload?.paymentUrl) {
      throw new Error(payload?.error || `Secure event checkout could not be started (HTTP ${response.status}).`);
    }
    if (window.top && window.top !== window.self) window.top.location.replace(payload.paymentUrl);
    else window.location.replace(payload.paymentUrl);
  };

  const handleBookEvents = async () => {
    if (!selectedEvent) return;
    setIsProcessing(true);
    setErrorMessage("");
    try {
      const { data: authData } = await supabase.auth.getUser();
      if (!authData.user) {
        const returnTo = `${location.pathname}${location.search}`;
      navigate(`/login?returnTo=${encodeURIComponent(returnTo)}`);
        return;
      }
      const fingerprint = currentFingerprint;
      if (idempotencyFingerprint.current !== fingerprint) {
        idempotencyFingerprint.current = fingerprint;
        idempotencyKey.current = crypto.randomUUID();
      }
      const { data: bookingResult, error: bookingError } = await supabase.rpc("create_special_event_booking", {
        target_event_id: selectedEvent.id,
        target_quantity: selectedEvent.quantity,
        guest_first_name: guestInfo.firstName.trim(),
        guest_last_name: guestInfo.lastName.trim(),
        guest_email: guestInfo.email.trim(),
        guest_phone: guestInfo.phone.trim() || null,
        special_requests: [guestInfo.company, guestInfo.dietaryRestrictions, guestInfo.specialRequests].filter(Boolean).join(" | ") || null,
        target_ticket_type_id: selectedEvent.default_ticket_type_id,
        target_idempotency_key: idempotencyKey.current,
        target_attendee_names: attendeeNames.slice(0, selectedEvent.quantity).map((name) => name.trim()),
        target_invitation_id: invitationId,
        target_share_token: selectedEvent.share_token || null,
      });
      if (bookingError || !bookingResult?.[0]) throw bookingError || new Error("Unable to create event booking.");
      const booking = bookingResult[0] as { booking_id: string; total_amount: number | string; currency: string };
      const authoritativeTotal = Number(booking.total_amount);
      const currencyDigits = new Intl.NumberFormat(undefined, { style: "currency", currency: booking.currency }).resolvedOptions().maximumFractionDigits;
      const normalizedPreview = Number(subtotal.toFixed(currencyDigits));
      const existingQuoteMatches = serverQuote?.fingerprint === fingerprint && serverQuote.amount === authoritativeTotal && serverQuote.currency === booking.currency;
      if (!existingQuoteMatches && normalizedPreview !== authoritativeTotal) {
        setServerQuote({ amount: authoritativeTotal, currency: booking.currency, fingerprint });
        setErrorMessage("The ticket price changed while you were checking out. Review the updated total and continue to confirm.");
        return;
      }
      if (!existingQuoteMatches && authoritativeTotal === 0) {
        setServerQuote({ amount: authoritativeTotal, currency: booking.currency, fingerprint });
      }
      if (authoritativeTotal === 0) {
        const { data: freeResult, error: freeError } = await supabase.rpc("confirm_free_special_event_booking", { target_booking_id: booking.booking_id });
        if (freeError || !freeResult?.[0]) throw freeError || new Error("Unable to confirm free event booking.");
        setConfirmation({ confirmationNumber: freeResult[0].confirmation_number, ticketCode: freeResult[0].ticket_code, eventTitle: selectedEvent.title, quantity: selectedEvent.quantity, total: authoritativeTotal, currency: booking.currency });
        setStep("confirmation");
        onClearCart();
        onBooked();
        return;
      }
      await startHostedPayment(booking.booking_id);
    } catch (error) {
      console.error("Unable to book special event", error);
      setErrorMessage(getCheckoutErrorMessage(error));
    } finally {
      setIsProcessing(false);
    }
  };

  if (confirmation) {
    return <Dialog open={isOpen} onOpenChange={handleClose}><DialogContent className="max-w-md mx-auto"><div className="text-center py-6"><div className="w-16 h-16 bg-green-100 rounded-full flex items-center justify-center mx-auto mb-4"><CheckCircle className="h-8 w-8 text-green-600" /></div><h2 className="text-2xl font-bold text-sheraton-navy mb-2">{confirmation.total === 0 ? "Registration Confirmed!" : "Event Tickets Confirmed!"}</h2><p className="text-gray-600 mb-6">{confirmation.total === 0 ? "Your free place is confirmed and your attendee ticket is ready." : "Your event booking has been confirmed successfully."}</p><div className="bg-sheraton-cream rounded-lg p-4 mb-6 space-y-2 text-sm"><div className="flex justify-between"><span className="text-gray-600">Confirmation</span><span className="font-semibold text-sheraton-navy">{confirmation.confirmationNumber}</span></div><div className="flex justify-between"><span className="text-gray-600">Ticket code</span><span className="font-semibold text-sheraton-navy">{confirmation.ticketCode}</span></div><div className="flex justify-between"><span className="text-gray-600">Total</span><span className="font-semibold text-sheraton-navy">{formatMoney(confirmation.total, confirmation.currency)}</span></div></div><div className="space-y-3"><Button onClick={handleClose} className="w-full bg-sheraton-gold hover:bg-sheraton-gold/90 text-sheraton-navy"><Ticket className="h-4 w-4 mr-2" />View My Events</Button><Button variant="outline" className="w-full" onClick={() => navigator.clipboard?.writeText(confirmation.ticketCode)}><Download className="h-4 w-4 mr-2" />Copy Ticket Code</Button></div></div></DialogContent></Dialog>;
  }

  return <Dialog open={isOpen} onOpenChange={handleClose}><DialogContent className="max-w-4xl max-h-[90vh] overflow-y-auto"><DialogHeader><DialogTitle className="text-2xl font-bold text-sheraton-navy">{step === "tickets" ? "Reserve a Place" : step === "details" ? "Attendee Information" : step === "payment" ? "Secure Payment" : "Registration Review"}</DialogTitle><div className="mt-4"><Progress value={(["tickets", "details", "payment", "confirmation"].indexOf(step) + 1) * 25} className="h-2" /><div className="flex justify-between mt-2 text-sm text-gray-600"><span>Tickets</span><span>Details</span><span>{total > 0 ? "Payment" : "Registration"}</span><span>Confirmation</span></div></div></DialogHeader><div className="grid lg:grid-cols-3 gap-6"><div className="lg:col-span-2">
    {step === "tickets" && <div className="space-y-4"><div className="flex items-center justify-between"><h3 className="text-lg font-semibold text-sheraton-navy">Your Event Tickets</h3><Badge variant="secondary">{cartItems.length} event</Badge></div>{cartItems.length === 0 ? <div className="text-center py-8"><Ticket className="h-16 w-16 text-gray-300 mx-auto mb-4" /><p className="text-gray-500">No events selected</p></div> : cartItems.map((item) => <div key={item.id} className="border rounded-lg p-4"><div className="flex items-start space-x-4">{item.image_url ? <img src={item.image_url} alt={item.title} loading="lazy" className="h-20 w-24 rounded-lg object-cover" /> : <div className="h-20 w-24 bg-gradient-to-br from-sheraton-cream to-sheraton-pearl rounded-lg flex items-center justify-center"><Award className="h-6 w-6 text-sheraton-gold" /></div>}<div className="flex-1"><div className="flex items-start justify-between"><div><h4 className="font-semibold text-sheraton-navy">{item.title}</h4><p className="text-sm text-gray-600 mb-2">{item.description}</p><div className="space-y-1 text-sm text-gray-600"><div><Calendar className="inline h-3 w-3 mr-1" />{formatEventDate(item.starts_at, item.timezone)}</div><div><MapPin className="inline h-3 w-3 mr-1" />{item.location}</div></div></div><Button variant="ghost" size="sm" onClick={() => onRemoveFromCart(item.id)}><X className="h-4 w-4" /></Button></div><div className="mt-4 flex items-center justify-between"><Badge variant="outline">General admission</Badge><div className="flex items-center space-x-2"><Button variant="outline" size="sm" onClick={() => onUpdateCart(item.id, Math.max(0, item.quantity - 1))}><Minus className="h-3 w-3" /></Button><span className="px-3 py-1 bg-gray-100 rounded text-sm">{item.quantity}</span><Button variant="outline" size="sm" onClick={() => onUpdateCart(item.id, item.quantity + 1)}><Plus className="h-3 w-3" /></Button></div></div><div className="mt-3 text-right"><span className="text-lg font-semibold text-sheraton-navy">{formatEntry(item.price * item.quantity, item.currency)}</span></div></div></div></div>)}</div>}
    {step === "details" && <div className="space-y-6"><div><h3 className="text-lg font-semibold text-sheraton-navy mb-4">Guest Information</h3><div className="grid grid-cols-2 gap-4"><div><label className="block text-sm font-medium text-gray-700 mb-1">First Name *</label><Input value={guestInfo.firstName} onChange={(event) => setGuestInfo({ ...guestInfo, firstName: event.target.value })} placeholder="John" /></div><div><label className="block text-sm font-medium text-gray-700 mb-1">Last Name *</label><Input value={guestInfo.lastName} onChange={(event) => setGuestInfo({ ...guestInfo, lastName: event.target.value })} placeholder="Doe" /></div><div><label className="block text-sm font-medium text-gray-700 mb-1">Email *</label><Input type="email" value={guestInfo.email} onChange={(event) => setGuestInfo({ ...guestInfo, email: event.target.value })} placeholder="john.doe@example.com" /></div><div><label className="block text-sm font-medium text-gray-700 mb-1">Phone (optional)</label><Input value={guestInfo.phone} onChange={(event) => setGuestInfo({ ...guestInfo, phone: event.target.value })} placeholder="+256..." /></div><div className="col-span-2"><label className="block text-sm font-medium text-gray-700 mb-1">Company (Optional)</label><Input value={guestInfo.company} onChange={(event) => setGuestInfo({ ...guestInfo, company: event.target.value })} placeholder="Company Name" /></div></div></div>{selectedEvent && <div><h3 className="mb-3 text-lg font-semibold text-sheraton-navy">Attendee names</h3><div className="grid gap-3 sm:grid-cols-2">{Array.from({ length: selectedEvent.quantity }, (_, index) => <Input key={index} value={attendeeNames[index] || ""} onChange={(change) => setAttendeeNames((names) => { const next = [...names]; next[index] = change.target.value; return next; })} placeholder={`Attendee ${index + 1} full name`} />)}</div></div>}<Separator /><div><h3 className="text-lg font-semibold text-sheraton-navy mb-4">Additional Information</h3><div className="space-y-4"><Input value={guestInfo.dietaryRestrictions} onChange={(event) => setGuestInfo({ ...guestInfo, dietaryRestrictions: event.target.value })} placeholder="Dietary restrictions / allergies" /><Textarea value={guestInfo.specialRequests} onChange={(event) => setGuestInfo({ ...guestInfo, specialRequests: event.target.value })} placeholder="Any special needs or requests..." rows={3} /></div></div></div>}
    {step === "payment" && <div className="space-y-6"><div className="rounded-lg border border-sheraton-gold/50 bg-sheraton-cream p-5"><div className="flex items-center gap-3"><CreditCard className="h-6 w-6 text-sheraton-navy" /><div><h3 className="font-semibold text-sheraton-navy">Secure hosted payment</h3><p className="text-sm text-gray-600">You will be redirected to Flutterwave to complete payment securely. Card details are never entered into this application.</p></div></div></div><div className="flex items-center gap-2 text-sm text-gray-600"><Shield className="h-4 w-4" />Payment is verified server-side before tickets are issued.</div></div>}
    {step === "confirmation" && <div className="space-y-6"><h3 className="text-lg font-semibold text-sheraton-navy">Booking Summary</h3>{selectedEvent && <div className="flex items-center justify-between p-3 bg-gray-50 rounded-lg"><div><p className="font-medium text-sheraton-navy">{selectedEvent.title}</p><p className="text-sm text-gray-600">{formatEventDate(selectedEvent.starts_at, selectedEvent.timezone)} • Qty: {selectedEvent.quantity}</p></div><span className="font-semibold text-sheraton-navy">{formatEntry(total, selectedEvent.currency)}</span></div>}<Separator /><div className="bg-gray-50 rounded-lg p-4"><p className="font-medium text-sheraton-navy">{guestInfo.firstName} {guestInfo.lastName}</p><p className="text-sm text-gray-600 mt-1">{guestInfo.email} • {guestInfo.phone}</p></div></div>}
    {errorMessage && <div role="alert" className="mt-5 flex items-start gap-2 rounded-md bg-red-50 p-3 text-sm text-red-700"><AlertCircle className="h-4 w-4 mt-0.5" />{errorMessage}</div>}
  </div><div className="lg:col-span-1"><div className="bg-gray-50 rounded-lg p-6 sticky top-6"><h3 className="text-lg font-semibold text-sheraton-navy mb-4">Booking Summary</h3><div className="space-y-3 mb-4"><div className="flex justify-between"><span className="text-gray-600">Subtotal</span><span className="font-medium">{selectedEvent ? formatEntry(subtotal, quoteIsCurrent ? serverQuote.currency : selectedEvent.currency) : "—"}</span></div><Separator /><div className="flex justify-between text-lg font-semibold text-sheraton-navy"><span>Total</span><span>{selectedEvent ? formatEntry(total, quoteIsCurrent ? serverQuote.currency : selectedEvent.currency) : "—"}</span></div></div><div className="flex space-x-2">{step !== "tickets" && <Button variant="outline" onClick={handleBack} className="flex-1"><ArrowLeft className="h-4 w-4 mr-2" />Back</Button>}{step !== "confirmation" ? <Button onClick={handleNext} disabled={isProcessing} className="flex-1 bg-sheraton-gold hover:bg-sheraton-gold/90 text-sheraton-navy">Continue<ArrowRight className="h-4 w-4 ml-2" /></Button> : <Button onClick={() => void handleBookEvents()} disabled={isProcessing} className="flex-1 bg-sheraton-gold hover:bg-sheraton-gold/90 text-sheraton-navy">{isProcessing ? "Processing..." : total > 0 ? "Pay Securely" : "Confirm Booking"}</Button>}</div><div className="mt-4 text-xs text-gray-500 text-center">{total > 0 ? <><div className="mb-1 flex items-center justify-center space-x-1"><Shield className="h-3 w-3" /><span>Secure Payment Processing</span></div><p>Your information is protected and secure</p></> : <p>No payment is required for free registration.</p>}</div></div></div></div></DialogContent></Dialog>;
};

export default EventCheckoutModal;
