import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { format } from "date-fns";
import { supabase } from "../lib/supabase";
import BookingCheckoutModal from "../components/booking/BookingCheckoutModal";
import { Button } from "../components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "../components/ui/card";
import { Input } from "../components/ui/input";
import { Label } from "../components/ui/label";
import { Badge } from "../components/ui/badge";
import { Textarea } from "../components/ui/textarea";
import { Checkbox } from "../components/ui/checkbox";
import { Calendar } from "../components/ui/calendar";
import { Popover, PopoverContent, PopoverTrigger } from "../components/ui/popover";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "../components/ui/select";
import { Separator } from "../components/ui/separator";
import { useToast } from "../hooks/use-toast";
import { Bed, CalendarDays, Check, CheckCircle, Crown, Gift, Hotel, MapPin, Plus, Users, Wifi } from "lucide-react";
import { cn } from "../lib/utils";

type HotelRoom = {
  id: string;
  organization_id: string;
  name: string;
  room_type: string;
  description: string;
  image_url: string | null;
  size_sqm: number | null;
  max_guests: number;
  available_units: number;
  nightly_rate: number;
  original_nightly_rate: number | null;
  currency_code: string;
  amenities: string[];
  status: "draft" | "published" | "unavailable";
  hotel_name?: string;
  hotel_city?: string | null;
  hotel_country?: string | null;
  hotel_classification?: number | null;
};

type BookingOffer = { id: string; title: string; description: string; discount_percentage: number; minimum_nights: number; starts_at: string | null; ends_at: string | null };
type BookingSettings = { title: string; subtitle: string };
type SavedBookingAccess = { bookingId: string; accessToken: string; confirmationNumber: string };
type ManagerBooking = { id: string; confirmation_number: string; room_id: string; check_in: string; check_out: string; guest_first_name: string; guest_last_name: string; guest_email: string; guest_count: number; booking_status: string; payment_status: string; total_amount: number; currency_code: string; books_accounting_status: string; books_accounting_error: string | null; hotel_rooms: { name: string } | null; hotel_payment_attempts: { status: string }[] };

const currencies = ["USD", "UGX", "EUR", "GBP", "KES", "TZS", "RWF"];
const defaultSettings = {
  title: "Book Your Special Stay",
  subtitle: "Experience luxury, comfort, and personalized service. Every detail crafted to make your stay extraordinary.",
};
const today = new Date();
const money = (value: number, currency: string) => new Intl.NumberFormat(undefined, { style: "currency", currency }).format(value || 0);

const BookingPage = () => {
  const { toast } = useToast();
  const [settings, setSettings] = useState<BookingSettings>(defaultSettings);
  const [offers, setOffers] = useState<BookingOffer[]>([]);
  const [rooms, setRooms] = useState<HotelRoom[]>([]);
  const [managerBookings, setManagerBookings] = useState<ManagerBooking[]>([]);
  const [savedBooking, setSavedBooking] = useState<SavedBookingAccess | null>(null);
  const [recoveringBooking, setRecoveringBooking] = useState(false);
  const [checkIn, setCheckIn] = useState<Date>();
  const [checkOut, setCheckOut] = useState<Date>();
  const [selectedRoomId, setSelectedRoomId] = useState("");
  const [guests, setGuests] = useState("2");
  const [roomCount, setRoomCount] = useState("1");
  const [preferences, setPreferences] = useState<string[]>([]);
  const [specialRequests, setSpecialRequests] = useState("");
  const [checkoutOpen, setCheckoutOpen] = useState(false);
  const [loading, setLoading] = useState(true);
  const [managerUserId, setManagerUserId] = useState<string | null>(null);
  const [managerOrganizationId, setManagerOrganizationId] = useState<string | null>(null);
  const [hotelClassification, setHotelClassification] = useState<number | null>(null);
  const [roomAvailability, setRoomAvailability] = useState<Record<string, number> | null>(null);
  const [availabilityError, setAvailabilityError] = useState(false);
  const [roomFormOpen, setRoomFormOpen] = useState(false);
  const [editingRoomId, setEditingRoomId] = useState<string | null>(null);
  const [savingRoom, setSavingRoom] = useState(false);
  const [roomForm, setRoomForm] = useState({ name: "", room_type: "suite", description: "", image_url: "", size_sqm: "", max_guests: "2", available_units: "1", nightly_rate: "", original_nightly_rate: "", currency_code: "USD", amenities: "Wi-Fi, King bed", status: "published" as "draft" | "published" | "unavailable" });

  const loadPage = async () => {
    setLoading(true);
    try {
      const [settingsResult, offerResult, roomResult, authResult] = await Promise.all([
        supabase.from("hotel_booking_page_settings").select("title,subtitle").eq("id", true).maybeSingle(),
        supabase.from("hotel_booking_offers").select("id,title,description,discount_percentage,minimum_nights,starts_at,ends_at").eq("is_active", true).order("display_order"),
        supabase.from("hotel_public_room_listings").select("id,organization_id,name,room_type,description,image_url,size_sqm,max_guests,available_units,nightly_rate,original_nightly_rate,currency_code,amenities,status,hotel_name,hotel_city,hotel_country,hotel_classification").order("nightly_rate"),
        supabase.auth.getUser(),
      ]);
      if (settingsResult.error) throw settingsResult.error;
      if (offerResult.error) throw offerResult.error;
      if (roomResult.error) throw roomResult.error;
      setSettings(settingsResult.data || defaultSettings);
      const now = Date.now();
      setOffers((offerResult.data || []).filter((offer) => (!offer.starts_at || new Date(offer.starts_at).getTime() <= now) && (!offer.ends_at || new Date(offer.ends_at).getTime() > now)));
      setRooms((roomResult.data || []) as HotelRoom[]);
      const user = authResult.data.user;
      if (user) {
        const { data: profile } = await supabase.from("user_profiles").select("role,hotel_star_rating").eq("user_id", user.id).maybeSingle();
        if (profile?.role === "manager") {
          setManagerUserId(user.id);
          setHotelClassification(profile.hotel_star_rating ? Number(profile.hotel_star_rating) : null);
          const { data: organizationId, error: organizationError } = await supabase.rpc("get_or_create_books_organization");
          if (organizationError) throw organizationError;
          setManagerOrganizationId(organizationId);
          const { data: managerRooms, error: managerRoomsError } = await supabase.from("hotel_rooms").select("id,organization_id,name,room_type,description,image_url,size_sqm,max_guests,available_units,nightly_rate,original_nightly_rate,currency_code,amenities,status").eq("organization_id", organizationId).order("created_at", { ascending: false });
          if (managerRoomsError) throw managerRoomsError;
          setRooms((managerRooms || []) as HotelRoom[]);
          const { data: reservations, error: reservationError } = await supabase.from("hotel_bookings").select("id,confirmation_number,room_id,check_in,check_out,guest_first_name,guest_last_name,guest_email,guest_count,booking_status,payment_status,total_amount,currency_code,books_accounting_status,books_accounting_error,hotel_rooms(name),hotel_payment_attempts(status)").eq("organization_id", organizationId).order("created_at", { ascending: false }).limit(50);
          if (reservationError) throw reservationError;
          setManagerBookings((reservations || []) as unknown as ManagerBooking[]);
        }
      }
    } catch (error) {
      toast({ title: "Booking information could not be loaded", description: error instanceof Error ? error.message : "Please refresh and try again.", variant: "destructive" });
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    void loadPage();
    try {
      const stored = localStorage.getItem("hotel-booking-access");
      if (stored) {
        const access = JSON.parse(stored) as SavedBookingAccess;
        if (access.bookingId && access.accessToken && access.confirmationNumber) setSavedBooking(access);
      }
    } catch {
      localStorage.removeItem("hotel-booking-access");
    }
  }, []);

  useEffect(() => {
    if (!checkIn || !checkOut || checkOut <= checkIn) {
      setRoomAvailability(null);
      setAvailabilityError(false);
      return;
    }
    let active = true;
    const loadAvailability = async () => {
      const { data, error } = await supabase.rpc("get_hotel_room_availability", {
        target_check_in: format(checkIn, "yyyy-MM-dd"),
        target_check_out: format(checkOut, "yyyy-MM-dd"),
      });
      if (!active) return;
      if (error) {
        setRoomAvailability(null);
        setAvailabilityError(true);
        return;
      }
      setAvailabilityError(false);
      setRoomAvailability(Object.fromEntries((data || []).map((row: { room_id: string; remaining_units: number }) => [row.room_id, Number(row.remaining_units)])));
    };
    void loadAvailability();
    return () => { active = false; };
  }, [checkIn, checkOut]);

  const selectedRoom = rooms.find((room) => room.id === selectedRoomId && room.status === "published") || null;
  const totalNights = checkIn && checkOut ? Math.max(0, Math.round((Date.UTC(checkOut.getFullYear(), checkOut.getMonth(), checkOut.getDate()) - Date.UTC(checkIn.getFullYear(), checkIn.getMonth(), checkIn.getDate())) / 86400000)) : 0;
  const roomSubtotal = selectedRoom ? Number(selectedRoom.nightly_rate) * totalNights * Number(roomCount) : 0;
  const applicableDiscount = Math.max(0, ...offers.filter((offer) => totalNights >= offer.minimum_nights).map((offer) => Number(offer.discount_percentage)));
  const stayDiscount = roomSubtotal * applicableDiscount / 100;

  const startEditRoom = (room?: HotelRoom) => {
    setEditingRoomId(room?.id || null);
    setRoomForm(room ? {
      name: room.name,
      room_type: room.room_type,
      description: room.description,
      image_url: room.image_url || "",
      size_sqm: room.size_sqm ? String(room.size_sqm) : "",
      max_guests: String(room.max_guests),
      available_units: String(room.available_units),
      nightly_rate: String(room.nightly_rate),
      original_nightly_rate: room.original_nightly_rate ? String(room.original_nightly_rate) : "",
      currency_code: room.currency_code.trim(),
      amenities: room.amenities.join(", "),
      status: room.status,
    } : { name: "", room_type: "suite", description: "", image_url: "", size_sqm: "", max_guests: "2", available_units: "1", nightly_rate: "", original_nightly_rate: "", currency_code: "USD", amenities: "Wi-Fi, King bed", status: "published" });
    setRoomFormOpen(true);
  };

  const saveRoom = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!managerUserId || !managerOrganizationId) return;
    if (!hotelClassification) {
      toast({ title: "Set the hotel star classification first", description: "Add the property's official 1–5 star classification in your manager profile before publishing rooms.", variant: "destructive" });
      return;
    }
    setSavingRoom(true);
    const roomValues = {
      organization_id: managerOrganizationId,
      name: roomForm.name.trim(),
      room_type: roomForm.room_type,
      description: roomForm.description.trim(),
      image_url: roomForm.image_url.trim() || null,
      size_sqm: roomForm.size_sqm ? Number(roomForm.size_sqm) : null,
      max_guests: Number(roomForm.max_guests),
      available_units: Number(roomForm.available_units),
      nightly_rate: Number(roomForm.nightly_rate),
      original_nightly_rate: roomForm.original_nightly_rate ? Number(roomForm.original_nightly_rate) : null,
      currency_code: roomForm.currency_code,
      amenities: roomForm.amenities.split(",").map((item) => item.trim()).filter(Boolean),
      status: roomForm.status,
    };
    const result = editingRoomId
      ? await supabase.from("hotel_rooms").update(roomValues).eq("id", editingRoomId).eq("organization_id", managerOrganizationId)
      : await supabase.from("hotel_rooms").insert({ ...roomValues, created_by: managerUserId });
    setSavingRoom(false);
    if (result.error) {
      toast({ title: "Room could not be saved", description: result.error.message, variant: "destructive" });
      return;
    }
    toast({ title: editingRoomId ? "Room listing updated" : "Room listing created" });
    setRoomFormOpen(false);
    setEditingRoomId(null);
    await loadPage();
  };

  const togglePreference = (preference: string, checked: boolean) => setPreferences((current) => checked ? [...current, preference] : current.filter((item) => item !== preference));

  const resumeSavedBooking = async () => {
    if (!savedBooking) return;
    setRecoveringBooking(true);
    try {
      const recoveryResponse = await fetch("/api/hotel-bookings/recover", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ bookingId: savedBooking.bookingId, accessToken: savedBooking.accessToken }),
      });
      const recovery = await recoveryResponse.json() as { bookingStatus?: string; paymentStatus?: string; expiresAt?: string | null; error?: string };
      if (!recoveryResponse.ok) throw new Error(recovery.error || "This reservation could not be recovered.");
      if (recovery.paymentStatus === "paid") {
        localStorage.removeItem("hotel-booking-access");
        setSavedBooking(null);
        toast({ title: "This reservation is already paid", description: "Check your email for its confirmation and receipt." });
        return;
      }
      if (recovery.bookingStatus !== "pending" || !recovery.expiresAt || new Date(recovery.expiresAt).getTime() <= Date.now()) {
        localStorage.removeItem("hotel-booking-access");
        setSavedBooking(null);
        throw new Error("This room hold has expired. Select the dates and room again to make a new booking.");
      }
      const paymentResponse = await fetch("/api/payments/hotel/session", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ bookingId: savedBooking.bookingId, accessToken: savedBooking.accessToken }),
      });
      const payment = await paymentResponse.json() as { paymentUrl?: string; error?: string };
      if (!paymentResponse.ok || !payment.paymentUrl) throw new Error(payment.error || "Secure checkout could not be restarted.");
      window.location.assign(payment.paymentUrl);
    } catch (error) {
      toast({ title: "Reservation could not be resumed", description: error instanceof Error ? error.message : "Please start a new booking.", variant: "destructive" });
    } finally {
      setRecoveringBooking(false);
    }
  };

  const retryHotelAccounting = async (booking: ManagerBooking) => {
    const { data, error } = await supabase.rpc("retry_hotel_booking_accounting", { target_booking_id: booking.id });
    if (error) {
      toast({ title: "Books posting could not be retried", description: error.message, variant: "destructive" });
      return;
    }
    toast({ title: data === "posted" ? "Hotel invoice posted" : "Books posting retried" });
    await loadPage();
  };

  const updateRoomStatus = async (room: HotelRoom) => {
    if (!managerOrganizationId) return;
    const status = room.status === "published" ? "unavailable" : "published";
    const { error } = await supabase.from("hotel_rooms").update({ status }).eq("id", room.id).eq("organization_id", managerOrganizationId);
    if (error) {
      toast({ title: "Room listing could not be updated", description: error.message, variant: "destructive" });
      return;
    }
    toast({ title: status === "published" ? "Room listing published" : "Room listing unpublished" });
    await loadPage();
  };

  return (
    <div className="min-h-screen bg-gradient-to-b from-sheraton-cream/70 to-background">
      <div className="container max-w-7xl py-8 sm:py-10">
        <header className="mb-10 text-center">
          <div className="mb-4 flex items-center justify-center gap-2"><Crown className="h-7 w-7 text-sheraton-gold" /><Badge className="bg-sheraton-gold px-4 py-2 text-sheraton-navy">Special Guest Booking</Badge></div>
          <h1 className="mb-4 text-4xl font-bold tracking-tight text-sheraton-navy md:text-5xl">{settings.title}</h1>
          <p className="mx-auto max-w-2xl text-lg leading-8 text-muted-foreground">{settings.subtitle}</p>
        </header>

        {savedBooking && <Card className="mx-auto mb-8 max-w-3xl border-sheraton-gold/40"><CardContent className="flex flex-col gap-4 p-5 sm:flex-row sm:items-center sm:justify-between"><div><p className="font-semibold text-sheraton-navy">Continue your reservation</p><p className="mt-1 text-sm text-muted-foreground">Resume the secure payment for reservation <span className="font-mono">{savedBooking.confirmationNumber}</span>. Room holds expire after 20 minutes.</p></div><Button className="sheraton-gradient text-white" onClick={() => void resumeSavedBooking()} disabled={recoveringBooking}>{recoveringBooking ? "Checking reservation…" : "Resume secure checkout"}</Button></CardContent></Card>}

        {managerUserId && <Card className="mb-8"><CardHeader><CardTitle>Recent reservations</CardTitle><p className="text-sm text-muted-foreground">Latest guest reservations for your property.</p></CardHeader><CardContent>{managerBookings.length ? <div className="overflow-x-auto"><table className="w-full min-w-[760px] text-sm"><thead><tr className="border-b text-left text-muted-foreground"><th className="p-3">Confirmation</th><th className="p-3">Guest</th><th className="p-3">Room</th><th className="p-3">Stay</th><th className="p-3">Status</th><th className="p-3 text-right">Total</th></tr></thead><tbody>{managerBookings.map((booking) => <tr key={booking.id} className="border-b last:border-0"><td className="p-3 font-mono text-xs">{booking.confirmation_number}</td><td className="p-3"><p className="font-medium">{booking.guest_first_name} {booking.guest_last_name}</p><p className="text-xs text-muted-foreground">{booking.guest_email} · {booking.guest_count} guests</p></td><td className="p-3">{booking.hotel_rooms?.name || "Room"}</td><td className="p-3">{format(new Date(`${booking.check_in}T00:00:00`), "MMM d")} – {format(new Date(`${booking.check_out}T00:00:00`), "MMM d, yyyy")}</td><td className="p-3"><div className="flex flex-wrap gap-1"><Badge variant={booking.booking_status === "confirmed" ? "default" : "outline"}>{booking.booking_status} · {booking.payment_status}</Badge>{booking.hotel_payment_attempts?.some((attempt) => attempt.status === "manual_review") && <Badge variant="destructive">Payment review</Badge>}<Badge variant={booking.books_accounting_status === "posted" ? "outline" : "destructive"}>Books {booking.books_accounting_status}</Badge>{booking.books_accounting_status !== "posted" && booking.payment_status === "paid" && <Button variant="link" size="sm" className="h-auto p-0" onClick={() => void retryHotelAccounting(booking)}>Retry Books</Button>}</div>{booking.books_accounting_error && <p className="mt-1 max-w-xs text-xs text-destructive">{booking.books_accounting_error}</p>}</td><td className="p-3 text-right font-medium">{money(Number(booking.total_amount), booking.currency_code.trim())}</td></tr>)}</tbody></table></div> : <div className="rounded-lg border border-dashed p-6 text-center text-sm text-muted-foreground">No reservations have been received yet.</div>}</CardContent></Card>}

        {offers.length > 0 && <section aria-label="Special offers" className="sticky top-16 z-40 mb-6 flex items-center gap-3 overflow-x-auto rounded-xl border border-sheraton-gold/30 bg-background/95 p-2 shadow-sm backdrop-blur">
          <h2 className="shrink-0 px-2 text-sm font-semibold text-sheraton-gold">Special offers</h2>
          {offers.map((offer) => <div key={offer.id} className="min-w-[240px] rounded-lg bg-sheraton-gold/10 px-3 py-2"><p className="text-xs font-semibold text-sheraton-navy">{offer.title}</p><p className="mt-0.5 line-clamp-2 text-[11px] text-muted-foreground">{offer.description}{offer.discount_percentage > 0 ? ` · ${offer.discount_percentage}% off from ${offer.minimum_nights} nights` : ""}</p></div>)}
        </section>}

        {managerUserId && (
          <Card className="mb-8 border-sheraton-gold/40">
            <CardHeader className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between"><div><CardTitle className="flex items-center gap-2"><Hotel className="h-5 w-5 text-sheraton-gold" />Room listing management</CardTitle><p className="mt-1 text-sm text-muted-foreground">Manage published room types, capacity, nightly rates and availability.</p></div><Button className="sheraton-gradient text-white" onClick={() => startEditRoom()}><Plus className="mr-2 h-4 w-4" />Add room</Button></CardHeader>
            {hotelClassification ? <CardContent className="pt-0 text-sm text-muted-foreground">Tax rules use the saved <strong>{hotelClassification}-star</strong> property classification and the room’s nightly rate.</CardContent> : <CardContent className="pt-0 text-sm text-amber-700">Add your official hotel classification under <Link to="/profile" className="font-medium underline">Manager Profile</Link> before publishing listings.</CardContent>}
            {rooms.length > 0 && <CardContent className="border-t pt-4"><h3 className="mb-3 text-sm font-semibold">Your room listings</h3><div className="space-y-2">{rooms.map((room) => <div key={room.id} className="flex flex-wrap items-center justify-between gap-3 rounded-lg border p-3"><div><p className="font-medium">{room.name}</p><p className="text-xs text-muted-foreground">{room.currency_code.trim()} {Number(room.nightly_rate).toLocaleString()} per night · {room.available_units} room(s) · {room.status}</p></div><div className="flex gap-2"><Button type="button" variant="outline" size="sm" onClick={() => startEditRoom(room)}>Edit</Button><Button type="button" variant={room.status === "published" ? "outline" : "secondary"} size="sm" onClick={() => void updateRoomStatus(room)}>{room.status === "published" ? "Unpublish" : "Publish"}</Button></div></div>)}</div></CardContent>}
            {roomFormOpen && <CardContent className="border-t pt-6"><form onSubmit={saveRoom} className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
              <div className="space-y-2"><Label>Room name</Label><Input value={roomForm.name} onChange={(event) => setRoomForm({ ...roomForm, name: event.target.value })} placeholder="Deluxe Suite" required maxLength={100} /></div>
              <div className="space-y-2"><Label>Room category</Label><Select value={roomForm.room_type} onValueChange={(value) => setRoomForm({ ...roomForm, room_type: value })}><SelectTrigger><SelectValue /></SelectTrigger><SelectContent>{["standard", "deluxe", "suite", "villa", "presidential"].map((type) => <SelectItem key={type} value={type}>{type.replace(/^./, (letter) => letter.toUpperCase())}</SelectItem>)}</SelectContent></Select></div>
              <div className="space-y-2"><Label>Nightly rate</Label><div className="flex gap-2"><Input className="min-w-0" type="number" min="0.01" step={["UGX", "RWF"].includes(roomForm.currency_code) ? "1" : "0.01"} value={roomForm.nightly_rate} onChange={(event) => setRoomForm({ ...roomForm, nightly_rate: event.target.value })} required /><Select value={roomForm.currency_code} onValueChange={(value) => setRoomForm({ ...roomForm, currency_code: value })}><SelectTrigger className="w-28"><SelectValue /></SelectTrigger><SelectContent>{currencies.map((currency) => <SelectItem key={currency} value={currency}>{currency}</SelectItem>)}</SelectContent></Select></div></div>
              <div className="space-y-2"><Label>Original nightly rate (optional)</Label><Input type="number" min="0.01" step={["UGX", "RWF"].includes(roomForm.currency_code) ? "1" : "0.01"} value={roomForm.original_nightly_rate} onChange={(event) => setRoomForm({ ...roomForm, original_nightly_rate: event.target.value })} placeholder="Only if a genuine discount applies" /></div>
              <div className="space-y-2"><Label>Maximum guests</Label><Input type="number" min="1" max="20" value={roomForm.max_guests} onChange={(event) => setRoomForm({ ...roomForm, max_guests: event.target.value })} required /></div>
              <div className="space-y-2"><Label>Rooms in inventory</Label><Input type="number" min="1" max="500" value={roomForm.available_units} onChange={(event) => setRoomForm({ ...roomForm, available_units: event.target.value })} required /></div>
              <div className="space-y-2"><Label>Room size (m²)</Label><Input type="number" min="1" step="0.1" value={roomForm.size_sqm} onChange={(event) => setRoomForm({ ...roomForm, size_sqm: event.target.value })} /></div>
              <div className="space-y-2 sm:col-span-2 lg:col-span-3"><Label>Description</Label><Textarea value={roomForm.description} onChange={(event) => setRoomForm({ ...roomForm, description: event.target.value })} rows={2} required maxLength={1500} /></div>
              <div className="space-y-2"><Label>Photo URL</Label><Input type="url" value={roomForm.image_url} onChange={(event) => setRoomForm({ ...roomForm, image_url: event.target.value })} placeholder="https://…" /></div>
              <div className="space-y-2"><Label>Amenities (comma separated)</Label><Input value={roomForm.amenities} onChange={(event) => setRoomForm({ ...roomForm, amenities: event.target.value })} placeholder="Wi-Fi, King bed, City view" /></div>
              <div className="space-y-2"><Label>Listing status</Label><Select value={roomForm.status} onValueChange={(value: "draft" | "published" | "unavailable") => setRoomForm({ ...roomForm, status: value })}><SelectTrigger><SelectValue /></SelectTrigger><SelectContent><SelectItem value="published">Published</SelectItem><SelectItem value="draft">Draft</SelectItem><SelectItem value="unavailable">Temporarily unavailable</SelectItem></SelectContent></Select></div>
              <div className="flex gap-2 sm:col-span-2 lg:col-span-3"><Button type="submit" className="sheraton-gradient text-white" disabled={savingRoom}>{savingRoom ? "Saving…" : editingRoomId ? "Save changes" : "Create listing"}</Button><Button type="button" variant="outline" onClick={() => setRoomFormOpen(false)}>Cancel</Button></div>
            </form></CardContent>}
          </Card>
        )}

        <div className="grid gap-8 lg:grid-cols-[minmax(0,1fr)_360px]">
          <main className="space-y-8">
            <Card>
              <CardHeader><CardTitle className="flex items-center gap-2"><CalendarDays className="h-5 w-5 text-sheraton-gold" />When would you like to stay?</CardTitle></CardHeader>
              <CardContent className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
                <div className="space-y-2"><Label>Check-in</Label><Popover><PopoverTrigger asChild><Button variant="outline" className="w-full justify-start font-normal"><CalendarDays className="mr-2 h-4 w-4" />{checkIn ? format(checkIn, "PPP") : "Choose a date"}</Button></PopoverTrigger><PopoverContent className="w-auto p-0"><Calendar mode="single" selected={checkIn} disabled={{ before: today }} onSelect={(date) => { setCheckIn(date); if (date && checkOut && date >= checkOut) setCheckOut(undefined); }} initialFocus /></PopoverContent></Popover></div>
                <div className="space-y-2"><Label>Check-out</Label><Popover><PopoverTrigger asChild><Button variant="outline" className="w-full justify-start font-normal"><CalendarDays className="mr-2 h-4 w-4" />{checkOut ? format(checkOut, "PPP") : "Choose a date"}</Button></PopoverTrigger><PopoverContent className="w-auto p-0"><Calendar mode="single" selected={checkOut} disabled={{ before: checkIn || today }} onSelect={setCheckOut} initialFocus /></PopoverContent></Popover></div>
                <div className="space-y-2"><Label>Guests</Label><Select value={guests} onValueChange={setGuests}><SelectTrigger><SelectValue /></SelectTrigger><SelectContent>{Array.from({ length: 20 }, (_, index) => String(index + 1)).map((count) => <SelectItem key={count} value={count}>{count} {count === "1" ? "guest" : "guests"}</SelectItem>)}</SelectContent></Select></div>
                <div className="space-y-2"><Label>Rooms</Label><Select value={roomCount} onValueChange={setRoomCount}><SelectTrigger><SelectValue /></SelectTrigger><SelectContent>{Array.from({ length: 10 }, (_, index) => String(index + 1)).map((count) => <SelectItem key={count} value={count}>{count} {count === "1" ? "room" : "rooms"}</SelectItem>)}</SelectContent></Select></div>
              </CardContent>
            </Card>

            <Card>
              <CardHeader><CardTitle className="flex items-center gap-2"><Bed className="h-5 w-5 text-sheraton-gold" />Choose your room</CardTitle><p className="text-sm text-muted-foreground">Rates and room availability are provided by the property.</p></CardHeader>
              <CardContent className="space-y-5">
                {loading ? <div className="space-y-3" aria-busy="true"><div className="h-40 animate-pulse rounded-xl bg-muted" /><div className="h-40 animate-pulse rounded-xl bg-muted" /></div> : rooms.filter((room) => room.status === "published").length ? rooms.filter((room) => room.status === "published").map((room) => (
                  <article key={room.id} role="radio" aria-checked={selectedRoomId === room.id} tabIndex={0} onClick={() => { if (!checkIn || !checkOut || roomAvailability?.[room.id] !== 0) setSelectedRoomId(room.id); }} onKeyDown={(event) => { if ((event.key === "Enter" || event.key === " ") && (!checkIn || !checkOut || roomAvailability?.[room.id] !== 0)) setSelectedRoomId(room.id); }} aria-disabled={Boolean(checkIn && checkOut && roomAvailability?.[room.id] === 0)} className={cn("cursor-pointer overflow-hidden rounded-xl border transition-all hover:shadow-md", checkIn && checkOut && roomAvailability?.[room.id] === 0 && "cursor-not-allowed opacity-60", selectedRoomId === room.id ? "border-sheraton-gold bg-sheraton-gold/5 shadow-sm" : "border-border")}>
                    <div className="grid sm:grid-cols-[200px_1fr]">
                      <div className="relative min-h-40 bg-gradient-to-br from-sheraton-cream to-sheraton-gold/20">{room.image_url ? <img src={room.image_url} alt={room.name} className="h-full min-h-40 w-full object-cover" /> : <div className="flex h-full min-h-40 items-center justify-center"><Hotel className="h-12 w-12 text-sheraton-gold/70" /></div>}</div>
                      <div className="p-5"><div className="flex flex-wrap items-start justify-between gap-4"><div><div className="mb-1 flex flex-wrap items-center gap-2"><div><h3 className="text-lg font-semibold text-sheraton-navy">{room.name}</h3><p className="mt-0.5 text-xs text-muted-foreground">{room.hotel_name || "Hotel"}{room.hotel_city ? ` · ${room.hotel_city}` : ""}{room.hotel_country ? `, ${room.hotel_country}` : ""}{room.hotel_classification ? ` · ${room.hotel_classification}-star hotel` : ""}</p></div>{selectedRoomId === room.id && <Badge className="bg-sheraton-gold text-sheraton-navy"><Check className="mr-1 h-3 w-3" />Selected</Badge>}</div><p className="max-w-xl text-sm text-muted-foreground">{room.description}</p></div><div className="text-right">{room.original_nightly_rate && <p className="text-xs text-muted-foreground line-through">{money(Number(room.original_nightly_rate), room.currency_code.trim())}</p>}<p className="text-xl font-bold text-sheraton-navy">{money(Number(room.nightly_rate), room.currency_code.trim())}</p><p className="text-xs text-muted-foreground">per room / night</p></div></div><div className="mt-4 flex flex-wrap gap-x-4 gap-y-2 text-xs text-muted-foreground"><span className="inline-flex items-center gap-1"><Users className="h-3.5 w-3.5" />Up to {room.max_guests} guests</span>{checkIn && checkOut && roomAvailability && <Badge variant={roomAvailability[room.id] > 0 ? "outline" : "destructive"}>{roomAvailability[room.id] > 0 ? `${roomAvailability[room.id]} available for your dates` : "Sold out for these dates"}</Badge>}{availabilityError && checkIn && checkOut && <span className="text-xs text-muted-foreground">Availability confirmed at checkout</span>}{checkIn && checkOut && roomAvailability && <Badge variant={roomAvailability[room.id] > 0 ? "outline" : "destructive"}>{roomAvailability[room.id] > 0 ? `${roomAvailability[room.id]} available for your dates` : "Sold out for these dates"}</Badge>}{availabilityError && checkIn && checkOut && <span className="text-xs text-muted-foreground">Availability confirmed at checkout</span>}{room.size_sqm && <span className="inline-flex items-center gap-1"><MapPin className="h-3.5 w-3.5" />{room.size_sqm} m²</span>}{room.amenities.slice(0, 5).map((amenity) => <span key={amenity} className="inline-flex items-center gap-1"><Wifi className="h-3.5 w-3.5" />{amenity}</span>)}</div></div>
                    </div>
                  </article>
                )) : <div className="rounded-xl border border-dashed p-8 text-center"><Hotel className="mx-auto mb-3 h-9 w-9 text-muted-foreground" /><h3 className="font-semibold">No rooms are available yet</h3><p className="mt-1 text-sm text-muted-foreground">Published room listings will appear here as soon as the hotel adds them.</p></div>}
              </CardContent>
            </Card>

            <Card><CardHeader><CardTitle className="flex items-center gap-2"><Crown className="h-5 w-5 text-sheraton-gold" />Your preferences</CardTitle></CardHeader><CardContent className="space-y-5"><div className="grid grid-cols-2 gap-3 sm:grid-cols-3">{["High floor", "Quiet room", "Connecting rooms", "Balcony", "King bed", "Twin beds"].map((preference) => <label key={preference} className="flex items-center gap-2 text-sm"><Checkbox checked={preferences.includes(preference)} onCheckedChange={(checked) => togglePreference(preference, checked === true)} />{preference}</label>)}</div><div className="space-y-2"><Label>Special requests</Label><Textarea value={specialRequests} onChange={(event) => setSpecialRequests(event.target.value)} maxLength={2000} rows={3} placeholder="Share anything that would help us prepare for your stay." /></div></CardContent></Card>
          </main>

          <aside className="space-y-6 lg:sticky lg:top-32 lg:self-start">
            <Card>
              <CardHeader><CardTitle className="flex items-center gap-2"><Gift className="h-5 w-5 text-sheraton-gold" />Booking summary</CardTitle></CardHeader>
              <CardContent className="space-y-4">
                {selectedRoom ? <><div className="rounded-lg bg-sheraton-gold/10 p-3"><p className="font-semibold text-sheraton-navy">{selectedRoom.name}</p><p className="mt-1 text-sm text-muted-foreground">{guests} guests · {roomCount} {Number(roomCount) === 1 ? "room" : "rooms"}</p></div><div className="space-y-2 text-sm">{checkIn && <div className="flex justify-between"><span>Check-in</span><span>{format(checkIn, "MMM d, yyyy")}</span></div>}{checkOut && <div className="flex justify-between"><span>Check-out</span><span>{format(checkOut, "MMM d, yyyy")}</span></div>}{totalNights > 0 && <div className="flex justify-between"><span>Length of stay</span><span>{totalNights} {totalNights === 1 ? "night" : "nights"}</span></div>}<Separator /><div className="flex justify-between"><span>Room rate</span><span>{money(roomSubtotal, selectedRoom.currency_code.trim())}</span></div>{stayDiscount > 0 && <div className="flex justify-between text-green-700"><span>Extended-stay savings</span><span>−{money(stayDiscount, selectedRoom.currency_code.trim())}</span></div>}<div className="flex justify-between font-semibold"><span>Room subtotal</span><span>{money(roomSubtotal - stayDiscount, selectedRoom.currency_code.trim())}</span></div><p className="text-xs leading-5 text-muted-foreground">18% Uganda VAT and Local Hotel Tax are calculated securely at checkout using the hotel classification and nightly room rate. Applicable stay offers are loaded from the database; final taxes and amount due are confirmed before payment.</p></div></> : <div className="rounded-lg border border-dashed p-5 text-center text-sm text-muted-foreground">Choose a room and stay dates to see your estimate.</div>}
                <Button className="w-full sheraton-gradient text-white" size="lg" disabled={!selectedRoom || !checkIn || !checkOut || totalNights <= 0 || Number(guests) > selectedRoom.max_guests * Number(roomCount) || Boolean(checkIn && checkOut && roomAvailability && (roomAvailability[selectedRoom?.id || ""] ?? 0) < Number(roomCount))} onClick={() => setCheckoutOpen(true)}><CalendarDays className="mr-2 h-4 w-4" />Continue to guest details</Button>
                {selectedRoom && Number(guests) > selectedRoom.max_guests * Number(roomCount) && <p className="text-xs text-destructive">The selected room inventory cannot accommodate this number of guests.</p>}{selectedRoom && checkIn && checkOut && roomAvailability && (roomAvailability[selectedRoom.id] ?? 0) < Number(roomCount) && <p className="text-xs text-destructive">Only {roomAvailability[selectedRoom.id] ?? 0} room(s) are available for those dates.</p>}
                <div className="flex items-center justify-center gap-2 text-xs text-muted-foreground"><CheckCircle className="h-3.5 w-3.5 text-green-600" />Secure checkout · Payment via Flutterwave</div>
              </CardContent>
            </Card>

          </aside>
        </div>

        <BookingCheckoutModal isOpen={checkoutOpen} onClose={() => setCheckoutOpen(false)} roomData={selectedRoom} checkIn={checkIn} checkOut={checkOut} guests={guests} roomCount={roomCount} preferences={preferences} specialRequests={specialRequests} totalNights={totalNights} totalPrice={roomSubtotal - stayDiscount} savings={stayDiscount} />
      </div>
    </div>
  );
};

export default BookingPage;
