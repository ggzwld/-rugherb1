import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";
import { BrowserMultiFormatReader } from "@zxing/browser";
import { AlertCircle, ArrowLeft, Camera, CheckCircle, Mail, RefreshCw, Search, Shield, Users } from "lucide-react";
import { Button } from "../components/ui/button";
import { Input } from "../components/ui/input";
import { supabase } from "../lib/supabase";
import { formatEventDate } from "../lib/events";

type OperationsPayload = {
  access_role: "manager" | "scanner";
  event: { id: string; title: string; starts_at: string; timezone: string; location: string; capacity: number; currency: string };
  stats: Record<string, number>;
  tickets: Array<Record<string, unknown> & { id: string; attendee_name: string; attendee_email: string; guest_phone: string | null; order_number: string; ticket_type: string; status: string; payment_status: string; checked_in_at: string | null }>;
  bookings: Array<Record<string, unknown> & { id: string; order_number: string; guest_first_name: string; guest_last_name: string; guest_email: string; guest_phone: string | null; quantity: number; total_amount: number; currency: string; status: string; payment_status: string; books_accounting_status: string; books_accounting_error: string | null; ticket_email_status: string | null; ticket_email_error: string | null; refund_id: string | null; refund_accounting_status: string | null; refund_accounting_error: string | null }>;
  staff: Array<{ id: string; user_id: string; email: string | null; role: string; status: string }>;
};

type ScanResult = { result: string; attendee_name: string | null; ticket_type: string | null; checked_in_at: string | null; checked_in_by_name: string | null };

const SpecialEventOperationsPage: React.FC = () => {
  const { eventId = "" } = useParams();
  const [operations, setOperations] = useState<OperationsPayload | null>(null);
  const [loadError, setLoadError] = useState("");
  const [scanner, setScanner] = useState("");
  const [scanResult, setScanResult] = useState<ScanResult | null>(null);
  const [scanError, setScanError] = useState("");
  const [staffEmail, setStaffEmail] = useState("");
  const [staffRole, setStaffRole] = useState("scanner");
  const [reviewBooking, setReviewBooking] = useState<string | null>(null);
  const [refundReference, setRefundReference] = useState("");
  const [refundReason, setRefundReason] = useState("");
  const [notice, setNotice] = useState("");
  const [isBusy, setIsBusy] = useState(false);
  const videoRef = useRef<HTMLVideoElement>(null);
  const stopCameraRef = useRef<(() => void) | null>(null);

  const loadOperations = useCallback(async () => {
    setLoadError("");
    const { data, error } = await supabase.rpc("get_special_event_operations", { target_event_id: eventId });
    if (error) {
      setLoadError(error.message);
      return;
    }
    setOperations(data as OperationsPayload);
  }, [eventId]);

  useEffect(() => {
    void loadOperations();
    return () => stopCameraRef.current?.();
  }, [loadOperations]);

  const visibleTickets = useMemo(() => {
    const query = scanner.trim().toLowerCase();
    if (!operations || !query) return operations?.tickets || [];
    return operations.tickets.filter((ticket) => [ticket.attendee_name, ticket.attendee_email, ticket.guest_phone, ticket.order_number]
      .some((value) => String(value || "").toLowerCase().includes(query)));
  }, [operations, scanner]);

  const checkIn = async (rawToken = scanner) => {
    const token = rawToken.trim();
    if (!token) return;
    setIsBusy(true);
    setScanError("");
    setScanResult(null);
    const { data, error } = await supabase.rpc("check_in_special_event_ticket", {
      target_event_id: eventId,
      target_ticket_token: token,
    });
    setIsBusy(false);
    if (error) {
      setScanError(error.message);
      return;
    }
    const result = (data as ScanResult[])[0];
    setScanResult(result);
    setScanner("");
    await loadOperations();
  };

  const startCamera = async () => {
    setScanError("");
    try {
      const reader = new BrowserMultiFormatReader();
      const controls = await reader.decodeFromVideoDevice(undefined, videoRef.current!, (result) => {
        if (!result) return;
        const text = result.getText();
        stopCameraRef.current?.();
        stopCameraRef.current = null;
        void checkIn(text);
      });
      stopCameraRef.current = () => controls.stop();
    } catch (error) {
      setScanError(error instanceof Error ? error.message : "Camera access is unavailable. Enter the ticket code manually.");
    }
  };

  const assignStaff = async () => {
    if (!staffEmail.trim()) return;
    setIsBusy(true);
    const { error } = await supabase.rpc("assign_special_event_staff", {
      target_event_id: eventId,
      staff_email: staffEmail.trim(),
      staff_role: staffRole,
    });
    setIsBusy(false);
    if (error) setNotice(error.message);
    else {
      setStaffEmail("");
      setNotice("Event staff access has been assigned.");
      await loadOperations();
    }
  };

  const retryTicketEmail = async (bookingId: string) => {
    setIsBusy(true);
    setNotice("");
    const { error } = await supabase.rpc("retry_special_event_ticket_email", { target_booking_id: bookingId });
    setIsBusy(false);
    if (error) setNotice(error.message);
    else {
      setNotice("Ticket email has been queued for delivery.");
      await loadOperations();
    }
  };

  const retryBooksPosting = async (bookingId: string) => {
    setIsBusy(true);
    setNotice("");
    const { data, error } = await supabase.rpc("retry_special_event_payment_books", { target_booking_id: bookingId });
    setIsBusy(false);
    if (error) setNotice(error.message);
    else {
      setNotice(data === "posted" ? "Books payment and receipt posting completed." : "Books posting is still failing; check the accounting error.");
      await loadOperations();
    }
  };

  const retryRefundPosting = async (refundId: string) => {
    setIsBusy(true);
    setNotice("");
    const { data, error } = await supabase.rpc("post_special_event_refund_to_books", { target_refund_id: refundId });
    setIsBusy(false);
    if (error) setNotice(error.message);
    else {
      setNotice(data === "posted" ? "Refund accounting has been posted." : "Refund accounting is still failing; check the accounting error.");
      await loadOperations();
    }
  };

  const revokeStaff = async (staffId: string) => {
    setIsBusy(true);
    const { error } = await supabase.rpc("revoke_special_event_staff", { target_staff_id: staffId });
    setIsBusy(false);
    if (error) setNotice(error.message);
    else await loadOperations();
  };

  const resolveReview = async (bookingId: string, resolution: "issue_tickets" | "refund") => {
    setIsBusy(true);
    setNotice("");
    const { data, error } = await supabase.rpc("resolve_special_event_payment_review", {
      target_booking_id: bookingId,
      resolution,
      provider_refund_reference: resolution === "refund" ? refundReference.trim() : null,
      refund_reason: resolution === "refund" ? refundReason.trim() : null,
    });
    setIsBusy(false);
    if (error) {
      setNotice(error.message);
      return;
    }
    setReviewBooking(null);
    setRefundReference("");
    setRefundReason("");
    setNotice(resolution === "refund" ? "Refund recorded. Tickets have been invalidated." : data === "paid" ? "Tickets issued." : "Payment remains in manual review until capacity is available.");
    await loadOperations();
  };

  if (loadError) {
    return <main className="container mx-auto max-w-5xl px-4 py-10"><div role="alert" className="rounded-lg border border-red-200 bg-red-50 p-6 text-red-800"><AlertCircle className="mb-2 h-5 w-5" />{loadError}</div><Link to="/events" className="mt-4 inline-flex items-center gap-2 text-sheraton-navy"><ArrowLeft className="h-4 w-4" />Back to Events</Link></main>;
  }
  if (!operations) return <main className="container mx-auto px-4 py-16 text-center">Loading event operations…</main>;

  const stats = operations.stats;
  const cards = [
    ["Tickets sold", stats.tickets_sold],
    ["Remaining", stats.tickets_remaining],
    ["Pending holds", stats.pending_holds],
    ["Paid orders", stats.paid_orders],
    ["Pending payments", stats.pending_payments],
    ["Checked in", stats.checked_in],
    ["Manual review", stats.manual_review],
    ["Cancelled / refunded", stats.cancelled_refunded],
    ["Duplicate scans", stats.duplicate_scans],
    ["Failed scans", stats.failed_scans],
  ];

  return <main className="min-h-screen bg-sheraton-cream/40"><div className="container mx-auto max-w-7xl space-y-6 px-4 py-8">
    <Link to="/events" className="inline-flex items-center gap-2 text-sm text-sheraton-navy"><ArrowLeft className="h-4 w-4" />Back to Events</Link>
    <header className="rounded-xl bg-white p-6 shadow-sm"><div className="flex flex-wrap items-start justify-between gap-4"><div><p className="text-sm text-gray-500">Event operations</p><h1 className="mt-1 text-3xl font-bold text-sheraton-navy">{operations.event.title}</h1><p className="mt-2 text-sm text-gray-600">{formatEventDate(operations.event.starts_at, operations.event.timezone)} · {operations.event.location}</p></div><Button variant="outline" onClick={() => void loadOperations()}><RefreshCw className="mr-2 h-4 w-4" />Refresh</Button></div></header>
    {notice && <div role="status" className="rounded-lg bg-sheraton-gold/20 p-3 text-sm text-sheraton-navy">{notice}</div>}
    {operations.access_role === "manager" && <section className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">{cards.map(([label, value]) => <div key={label} className="rounded-lg bg-white p-4 shadow-sm"><p className="text-sm text-gray-500">{label}</p><p className="mt-1 text-2xl font-bold text-sheraton-navy">{value}</p></div>)}</section>}
    <section className="grid gap-6 lg:grid-cols-2">
      <div className="space-y-4 rounded-xl bg-white p-5 shadow-sm"><div className="flex items-center gap-2"><Shield className="h-5 w-5 text-sheraton-gold" /><h2 className="text-xl font-semibold text-sheraton-navy">Check in tickets</h2></div><p className="text-sm text-gray-600">Scan one opaque QR code per attendee, or enter the code manually. A ticket can only be checked in once.</p><video ref={videoRef} className="aspect-video w-full rounded-lg bg-black" muted playsInline /><div className="flex flex-wrap gap-2"><Button onClick={() => void startCamera()}><Camera className="mr-2 h-4 w-4" />Start camera</Button><Button variant="outline" onClick={() => { stopCameraRef.current?.(); stopCameraRef.current = null; }}>Stop camera</Button></div><div className="flex gap-2"><Input value={scanner} onChange={(event) => setScanner(event.target.value)} onKeyDown={(event) => { if (event.key === "Enter") void checkIn(); }} placeholder="Ticket code / QR token" autoComplete="off" /><Button onClick={() => void checkIn()} disabled={isBusy || !scanner.trim()}>Check in</Button></div>{scanError && <p role="alert" className="rounded bg-red-50 p-3 text-sm text-red-700">{scanError}</p>}{scanResult && <div role="status" className={`rounded-lg p-4 ${scanResult.result === "checked_in" ? "bg-green-50 text-green-800" : "bg-amber-50 text-amber-900"}`}><p className="font-semibold">{scanResult.result.replace(/_/g, " ")}</p>{scanResult.attendee_name && <p>{scanResult.attendee_name} · {scanResult.ticket_type}</p>}{scanResult.checked_in_at && <p className="text-sm">Scanned {new Date(scanResult.checked_in_at).toLocaleTimeString()}{scanResult.checked_in_by_name ? ` by ${scanResult.checked_in_by_name}` : ""}</p>}</div>}</div>
      {operations.access_role === "manager" && <div className="space-y-4 rounded-xl bg-white p-5 shadow-sm"><div className="flex items-center gap-2"><Users className="h-5 w-5 text-sheraton-gold" /><h2 className="text-xl font-semibold text-sheraton-navy">Event staff</h2></div><div className="flex flex-wrap gap-2"><Input value={staffEmail} onChange={(event) => setStaffEmail(event.target.value)} placeholder="Registered staff email" type="email" /><select value={staffRole} onChange={(event) => setStaffRole(event.target.value)} className="rounded-md border px-3"><option value="scanner">Scanner</option><option value="manager">Manager</option></select><Button onClick={() => void assignStaff()} disabled={isBusy}>Assign</Button></div><div className="divide-y">{operations.staff.map((staff) => <div key={staff.id} className="flex items-center justify-between gap-3 py-3"><div><p className="font-medium">{staff.email || staff.user_id}</p><p className="text-sm capitalize text-gray-500">{staff.role}</p></div><Button variant="outline" size="sm" onClick={() => void revokeStaff(staff.id)} disabled={isBusy}>Revoke</Button></div>)}{!operations.staff.length && <p className="py-3 text-sm text-gray-500">No additional event staff assigned.</p>}</div><p className="text-xs text-gray-500">Staff must have an account before they can be assigned.</p></div>}
    </section>
    {operations.access_role === "manager" && <section className="rounded-xl bg-white p-5 shadow-sm"><div className="mb-4 flex items-center gap-2"><Search className="h-5 w-5 text-sheraton-gold" /><h2 className="text-xl font-semibold text-sheraton-navy">Attendee lookup</h2></div><Input value={scanner} onChange={(event) => setScanner(event.target.value)} placeholder="Search name, phone, email, or order number" /><div className="mt-4 overflow-x-auto"><table className="w-full min-w-[780px] text-left text-sm"><thead><tr className="border-b text-gray-500"><th className="p-2">Attendee</th><th className="p-2">Contact</th><th className="p-2">Order</th><th className="p-2">Ticket</th><th className="p-2">Payment</th><th className="p-2">Check-in</th></tr></thead><tbody>{visibleTickets.map((ticket) => <tr key={ticket.id} className="border-b"><td className="p-2">{ticket.attendee_name}</td><td className="p-2">{ticket.attendee_email}<br />{ticket.guest_phone || ""}</td><td className="p-2">{ticket.order_number}</td><td className="p-2">{ticket.ticket_type} · {ticket.status}</td><td className="p-2">{ticket.payment_status}</td><td className="p-2">{ticket.checked_in_at ? new Date(ticket.checked_in_at).toLocaleString() : "Not checked in"}</td></tr>)}</tbody></table>{!visibleTickets.length && <p className="py-6 text-center text-sm text-gray-500">No attendee tickets match the search.</p>}</div></section>}
    {operations.access_role === "manager" && operations.bookings.some((booking) => booking.ticket_email_status === "failed" || booking.books_accounting_status === "failed" || booking.refund_accounting_status === "failed") && <section className="rounded-xl bg-white p-5 shadow-sm"><div className="mb-4 flex items-center gap-2"><Mail className="h-5 w-5 text-sheraton-gold" /><h2 className="text-xl font-semibold text-sheraton-navy">Delivery and accounting recovery</h2></div><div className="space-y-3">{operations.bookings.filter((booking) => booking.ticket_email_status === "failed" || booking.books_accounting_status === "failed" || booking.refund_accounting_status === "failed").map((booking) => <div key={booking.id} className="rounded-lg border p-4"><p className="font-semibold">{booking.order_number} · {booking.guest_first_name} {booking.guest_last_name}</p><div className="mt-3 flex flex-wrap gap-2">{booking.ticket_email_status === "failed" && <Button variant="outline" onClick={() => void retryTicketEmail(booking.id)} disabled={isBusy}>Retry ticket email</Button>}{booking.books_accounting_status === "failed" && booking.payment_status === "paid" && <Button variant="outline" onClick={() => void retryBooksPosting(booking.id)} disabled={isBusy}>Retry Books payment</Button>}{booking.refund_accounting_status === "failed" && booking.refund_id && <Button variant="outline" onClick={() => void retryRefundPosting(booking.refund_id!)} disabled={isBusy}>Retry Books refund</Button>}</div><div className="mt-2 space-y-1 text-xs text-red-700">{booking.ticket_email_error && <p>Ticket email: {booking.ticket_email_error}</p>}{booking.books_accounting_error && <p>Books: {booking.books_accounting_error}</p>}{booking.refund_accounting_error && <p>Refund: {booking.refund_accounting_error}</p>}</div></div>)}</div></section>}
    {operations.access_role === "manager" && <section className="rounded-xl bg-white p-5 shadow-sm"><h2 className="text-xl font-semibold text-sheraton-navy">Payment issues and reconciliation</h2><p className="mt-1 text-sm text-gray-600">Refunds must first be completed in Flutterwave. Recording the provider reference here invalidates every unscanned ticket.</p><div className="mt-4 space-y-3">{operations.bookings.filter((booking) => booking.payment_status === "manual_review").map((booking) => <div key={booking.id} className="rounded-lg border border-amber-200 bg-amber-50 p-4"><div className="flex flex-wrap items-center justify-between gap-2"><div><p className="font-semibold">{booking.order_number} · {booking.guest_first_name} {booking.guest_last_name}</p><p className="text-sm">{booking.guest_email} · {booking.quantity} ticket(s) · {booking.total_amount} {booking.currency}</p></div><Button variant="outline" onClick={() => setReviewBooking(reviewBooking === booking.id ? null : booking.id)}>Resolve</Button></div>{reviewBooking === booking.id && <div className="mt-4 space-y-3"><Button onClick={() => void resolveReview(booking.id, "issue_tickets")} disabled={isBusy}>Issue tickets if capacity is available</Button><div className="grid gap-2 md:grid-cols-2"><Input value={refundReference} onChange={(event) => setRefundReference(event.target.value)} placeholder="Completed Flutterwave refund reference" /><Input value={refundReason} onChange={(event) => setRefundReason(event.target.value)} placeholder="Refund reason" /></div><Button variant="outline" onClick={() => void resolveReview(booking.id, "refund")} disabled={isBusy || !refundReference.trim() || !refundReason.trim()}>Record completed full refund</Button></div>}</div>)}{!operations.bookings.some((booking) => booking.payment_status === "manual_review") && <p className="text-sm text-gray-500">No payments require manual review.</p>}</div></section>}
    <div className="flex items-center gap-2 text-xs text-gray-500"><CheckCircle className="h-4 w-4" />Payment verification, ticket issuance, capacity, and check-in are recorded by server-side RPCs.</div>
  </div></main>;
};

export default SpecialEventOperationsPage;
