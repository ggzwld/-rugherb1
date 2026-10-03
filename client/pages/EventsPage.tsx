import { useEffect, useMemo, useRef, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import {
  Calendar,
  MapPin,
  Users,
  Clock,
  Star,
  Award,
  CreditCard,
  Search,
  Filter,
  Plus,
  Share2,
  Heart,
  Copy,
  Mail,
} from "lucide-react";
import { Button } from "../components/ui/button";
import { Input } from "../components/ui/input";
import { Textarea } from "../components/ui/textarea";
import { Switch } from "../components/ui/switch";
import { Badge } from "../components/ui/badge";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "../components/ui/select";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "../components/ui/dialog";
import EventCheckoutModal from "../components/events/EventCheckoutModal";
import TicketQr from "../components/events/TicketQr";
import { useFileUpload } from "../hooks/useFileUpload";
import { supabase } from "../lib/supabase";
import {
  formatEventDate,
  formatEventDay,
  type SpecialEvent,
  type SpecialEventBooking,
  type SpecialEventInvitationSummary,
  type SpecialEventPlan,
  type SpecialEventTicket,
} from "../lib/events";

type EventPlanForm = {
  title: string;
  eventDate: string;
  startTime: string;
  endTime: string;
  facilityId: string;
  category: string;
  expectedGuests: string;
  entryType: "free" | "paid";
  entryFee: string;
  description: string;
  imageUrl: string;
  contactName: string;
  contactEmail: string;
  contactPhone: string;
  isPrivate: boolean;
  shareManagerOperations: boolean;
};

type ProposalReviewForm = {
  title: string;
  description: string;
  category: string;
  startsAt: string;
  endsAt: string;
  facilityId: string;
  expectedGuests: string;
};

type SpecialEventInvitationRow = {
  id: string;
  event_plan_id: string;
  event_id: string;
  invitee_email: string;
  created_by: string;
  status: "pending" | "accepted" | "declined" | "revoked";
};

const initialPlan: EventPlanForm = {
  title: "",
  eventDate: "",
  startTime: "09:00",
  endTime: "12:00",
  facilityId: "",
  category: "Social Gathering",
  expectedGuests: "",
  entryType: "free",
  entryFee: "",
  description: "",
  imageUrl: "",
  contactName: "",
  contactEmail: "",
  contactPhone: "",
  isPrivate: false,
  shareManagerOperations: false,
};

type EventForm = {
  title: string;
  description: string;
  category: string;
  startsAt: string;
  endsAt: string;
  timezone: string;
  facilityId: string;
  organizationId: string;
  price: string;
  currency: string;
  capacity: string;
  maxTicketsPerOrder: string;
  hostName: string;
  imageUrl: string;
  featured: boolean;
};

const initialEventForm: EventForm = {
  title: "",
  description: "",
  category: "Fine Dining",
  startsAt: "",
  endsAt: "",
  timezone: "Africa/Kampala",
  facilityId: "",
  organizationId: "",
  price: "0",
  currency: "UGX",
  capacity: "",
  maxTicketsPerOrder: "10",
  hostName: "",
  imageUrl: "",
  featured: false,
};

const formatMoney = (value: number, currency: string) =>
  new Intl.NumberFormat(undefined, { style: "currency", currency, maximumFractionDigits: 2 }).format(value || 0);

const formatEntry = (price: number, currency: string) => price > 0 ? formatMoney(price, currency) : "Free";

const toEventInstant = (date: string, time: string, timezone = "Africa/Kampala") => {
  const wallTime = new Date(`${date}T${time}:00Z`);
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(wallTime);
  const values = Object.fromEntries(parts.map(({ type, value }) => [type, value]));
  const timezoneOffset = Date.UTC(Number(values.year), Number(values.month) - 1, Number(values.day), Number(values.hour), Number(values.minute)) - wallTime.getTime();
  return new Date(wallTime.getTime() - timezoneOffset).toISOString();
};

const timeInEventZone = (instant: string, timezone = "Africa/Kampala") =>
  new Intl.DateTimeFormat("en-GB", { timeZone: timezone, hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).format(new Date(instant));

const dateTimeInputInEventZone = (instant: string, timezone: string) => {
  const values = Object.fromEntries(new Intl.DateTimeFormat("en-CA", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(instant)).map(({ type, value }) => [type, value]));
  return `${values.year}-${values.month}-${values.day}T${values.hour}:${values.minute}`;
};

const EventsPage: React.FC = () => {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const invitationToken = searchParams.get("invite");
  const invitationId = searchParams.get("invitationId");
  const sharedEventToken = searchParams.get("event");
  const { uploadFile, isUploading } = useFileUpload();
  const [activeTab, setActiveTab] = useState(searchParams.get("tab") || (searchParams.has("invite") || searchParams.has("invitationId") ? "my-events" : "browse"));
  const [selectedEvent, setSelectedEvent] = useState<string | null>(null);
  const [eventCart, setEventCart] = useState<Record<string, number>>({});
  const [showCheckout, setShowCheckout] = useState(false);
  const [events, setEvents] = useState<SpecialEvent[]>([]);
  const [bookedEvents, setBookedEvents] = useState<SpecialEvent[]>([]);
  const [sharedEvent, setSharedEvent] = useState<SpecialEvent | null>(null);
  const [shareEventTarget, setShareEventTarget] = useState<{ title: string; share_token?: string | null; is_private?: boolean } | null>(null);
  const [linkedEvents, setLinkedEvents] = useState<SpecialEvent[]>([]);
  const [incomingInvitations, setIncomingInvitations] = useState<SpecialEventInvitationSummary[]>([]);
  const [favoriteIds, setFavoriteIds] = useState<Set<string>>(new Set());
  const [operationalEventIds, setOperationalEventIds] = useState<Set<string>>(new Set());
  const [bookings, setBookings] = useState<SpecialEventBooking[]>([]);
  const [tickets, setTickets] = useState<SpecialEventTicket[]>([]);
  const [plans, setPlans] = useState<SpecialEventPlan[]>([]);
  const [proposalQueue, setProposalQueue] = useState<SpecialEventPlan[]>([]);
  const [scheduledProposals, setScheduledProposals] = useState<SpecialEventPlan[]>([]);
  const [facilities, setFacilities] = useState<Array<{ id: string; name: string }>>([]);
  const [hotelOrganizations, setHotelOrganizations] = useState<Array<{ id: string; name: string }>>([]);
  const [proposalReviewForms, setProposalReviewForms] = useState<Record<string, ProposalReviewForm>>({});
  const [proposalReviewNotes, setProposalReviewNotes] = useState<Record<string, string>>({});
  const [inviteEmails, setInviteEmails] = useState<Record<string, string>>({});
  const [createdInviteLinks, setCreatedInviteLinks] = useState<Record<string, string>>({});
  const [ownedInvitations, setOwnedInvitations] = useState<SpecialEventInvitationRow[]>([]);
  const [invitationInfo, setInvitationInfo] = useState<SpecialEventInvitationSummary | null>(null);
  const [activeInvitationBookingId, setActiveInvitationBookingId] = useState<string | null>(null);
  const [invitationLoading, setInvitationLoading] = useState(false);
  const [searchTerm, setSearchTerm] = useState("");
  const [selectedCategory, setSelectedCategory] = useState("All");
  const [planForm, setPlanForm] = useState<EventPlanForm>(initialPlan);
  const [editingPlanId, setEditingPlanId] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [isSavingPlan, setIsSavingPlan] = useState(false);
  const [retryingBookingId, setRetryingBookingId] = useState<string | null>(null);
  const [isSignedIn, setIsSignedIn] = useState(false);
  const [currentUserId, setCurrentUserId] = useState<string | null>(null);
  const [profileRole, setProfileRole] = useState<string | null>(null);
  const [eventForm, setEventForm] = useState<EventForm>(initialEventForm);
  const [editingEventId, setEditingEventId] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState("");
  const [notice, setNotice] = useState("");
  const [shouldScrollToQuickCreation, setShouldScrollToQuickCreation] = useState(false);
  const quickEventCreationRef = useRef<HTMLDivElement>(null);
  const planCardRefs = useRef(new Map<string, HTMLDivElement>());
  const pendingPlanScrollId = useRef<string | null>(null);

  const loadUserData = async (userId: string | null) => {
    if (!userId) {
      setIsSignedIn(false);
      setCurrentUserId(null);
      setFavoriteIds(new Set());
      setOperationalEventIds(new Set());
      setBookings([]);
      setBookedEvents([]);
      setTickets([]);
      setPlans([]);
      setLinkedEvents([]);
      setIncomingInvitations([]);
      setOwnedInvitations([]);
      setProposalQueue([]);
      setScheduledProposals([]);
      setFacilities([]);
      setHotelOrganizations([]);
      setProfileRole(null);
      return;
    }

    setIsSignedIn(true);
    setCurrentUserId(userId);
    const [profileResult, favoritesResult, bookingsResult, plansResult, staffResult, facilitiesResult, proposalQueueResult, invitationsResult, incomingInvitationsResult] = await Promise.all([
      supabase.from("user_profiles").select("role,first_name,last_name,email,phone").eq("user_id", userId).maybeSingle(),
      supabase.from("special_event_favorites").select("event_id").eq("user_id", userId),
      supabase.from("special_event_bookings").select("*").eq("user_id", userId).order("created_at", { ascending: false }),
      supabase.from("special_event_plans").select("*").eq("user_id", userId).order("event_date", { ascending: true }),
      supabase.from("special_event_staff").select("event_id").eq("user_id", userId).eq("status", "active"),
      supabase.from("special_event_facilities").select("id,name").eq("is_active", true).order("display_order"),
      supabase.from("special_event_plans").select("*").in("status", ["submitted", "scheduled"]).order("created_at", { ascending: true }),
      supabase.from("special_event_invitations").select("id,event_plan_id,event_id,invitee_email,created_by,status").eq("created_by", userId).order("created_at", { ascending: false }),
      supabase.rpc("get_my_special_event_invitations"),
    ]);

    if (profileResult.error) throw profileResult.error;
    if (favoritesResult.error) throw favoritesResult.error;
    if (bookingsResult.error) throw bookingsResult.error;
    if (plansResult.error) throw plansResult.error;
    if (staffResult.error) throw staffResult.error;
    if (facilitiesResult.error) throw facilitiesResult.error;
    if (invitationsResult.error) throw invitationsResult.error;
    if (incomingInvitationsResult.error) throw incomingInvitationsResult.error;

    const bookingRows = (bookingsResult.data || []) as SpecialEventBooking[];
    const bookedEventIds = Array.from(new Set(bookingRows.map((booking) => booking.event_id)));
    const bookedEventsResult = bookedEventIds.length
      ? await supabase.from("special_events").select("*").in("id", bookedEventIds)
      : { data: [], error: null };
    if (bookedEventsResult.error) throw bookedEventsResult.error;
    const ticketResult = bookingRows.length
      ? await supabase.from("special_event_tickets").select("id,booking_id,event_id,ticket_number,ticket_token,attendee_name,attendee_email,status,checked_in_at").in("booking_id", bookingRows.map((booking) => booking.id)).order("ticket_number")
      : { data: [], error: null };
    if (ticketResult.error) throw ticketResult.error;
    const role = profileResult.data?.role || null;
    setProfileRole(role);
    setFacilities((facilitiesResult.data || []) as Array<{ id: string; name: string }>);
    if (role === "manager" || role === "admin") {
      const { data: memberships } = await supabase.from("books_memberships").select("organization_id")
        .eq("user_id", userId).in("role", ["owner", "admin", "manager"]);
      const organizationIds = [...new Set((memberships || []).map((membership) => membership.organization_id))];
      const { data: organizations } = organizationIds.length
        ? await supabase.from("books_organizations").select("id,name").in("id", organizationIds).order("name")
        : { data: [] };
      const choices = (organizations || []).map((organization) => ({ id: organization.id, name: organization.name }));
      setHotelOrganizations(choices);
      if (choices.length === 1) setEventForm((form) => form.organizationId ? form : { ...form, organizationId: choices[0].id });
    } else {
      setHotelOrganizations([]);
    }
    const reviewRows = (proposalQueueResult.data || []) as SpecialEventPlan[];
    setProposalQueue(role === "manager" || role === "admin" ? reviewRows.filter((plan) => plan.status === "submitted") : []);
    setScheduledProposals(role === "manager" || role === "admin" ? reviewRows.filter((plan) => plan.status === "scheduled") : []);
    setPlanForm((form) => ({
      ...form,
      contactName: form.contactName || [profileResult.data?.first_name, profileResult.data?.last_name].filter(Boolean).join(" "),
      contactEmail: form.contactEmail || profileResult.data?.email || "",
      contactPhone: form.contactPhone || profileResult.data?.phone || "",
    }));
    setFavoriteIds(new Set((favoritesResult.data || []).map((favorite) => favorite.event_id)));
    setOperationalEventIds(new Set((staffResult.data || []).map((staff) => staff.event_id)));
    setBookings(bookingRows);
    setBookedEvents((bookedEventsResult.data || []) as SpecialEvent[]);
    setTickets((ticketResult.data || []) as SpecialEventTicket[]);
    setPlans((plansResult.data || []) as SpecialEventPlan[]);
    setOwnedInvitations((invitationsResult.data || []) as SpecialEventInvitationRow[]);
    const receivedInvitations = (incomingInvitationsResult.data || []) as SpecialEventInvitationSummary[];
    setIncomingInvitations(receivedInvitations);
    setLinkedEvents(receivedInvitations.map((invitation) => invitation.event));
  };

  const loadEvents = async () => {
    setIsLoading(true);
    setErrorMessage("");
    try {
      const [{ data: eventRows, error: eventsError }, { data: authData }] = await Promise.all([
        supabase
          .from("special_events")
          .select("*")
          .eq("status", "published")
          .eq("is_private", false)
          .gte("starts_at", new Date().toISOString())
          .order("featured", { ascending: false })
          .order("starts_at", { ascending: true }),
        supabase.auth.getUser(),
      ]);
      if (eventsError) throw eventsError;
      await loadUserData(authData.user?.id || null);
      setEvents((eventRows || []) as SpecialEvent[]);
    } catch (error) {
      console.error("Unable to load special events", error);
      setErrorMessage("Events are not available right now. Please try again shortly.");
    } finally {
      setIsLoading(false);
    }
  };

  useEffect(() => {
    const requestedTab = searchParams.get("tab");
    if (requestedTab === "my-tickets" || requestedTab === "my-events") setActiveTab(requestedTab);
    else if (searchParams.has("invite") || searchParams.has("invitationId")) setActiveTab("my-events");
  }, [searchParams]);

  useEffect(() => {
    let active = true;
    const loadLinkedEvent = async () => {
      setInvitationLoading(Boolean(invitationToken || invitationId));
      if (invitationToken) {
        const { data, error } = await supabase.rpc("get_special_event_invitation_by_token", { target_token: invitationToken });
        if (!active) return;
        if (error) setNotice(error.message);
        setInvitationInfo((data || null) as SpecialEventInvitationSummary | null);
      } else if (invitationId && currentUserId) {
        const { data, error } = await supabase.rpc("get_special_event_invitation_by_id", { target_invitation_id: invitationId });
        if (!active) return;
        if (error) setNotice(error.message);
        setInvitationInfo((data || null) as SpecialEventInvitationSummary | null);
      } else {
        setInvitationInfo(null);
      }

      if (sharedEventToken) {
        const { data, error } = await supabase.rpc("get_special_event_by_share_token", { target_share_token: sharedEventToken });
        if (!active) return;
        if (error) setNotice(error.message);
        const event = (data || null) as SpecialEvent | null;
        setSharedEvent(event);
        if (event) setSelectedEvent(event.id);
      } else {
        setSharedEvent(null);
      }
      setInvitationLoading(false);
    };
    void loadLinkedEvent();
    return () => { active = false; };
  }, [invitationToken, invitationId, sharedEventToken, currentUserId]);

  useEffect(() => {
    if (activeTab !== "my-events" || !shouldScrollToQuickCreation) return;
    quickEventCreationRef.current?.scrollIntoView({ behavior: "smooth", block: "start" });
    setShouldScrollToQuickCreation(false);
  }, [activeTab, shouldScrollToQuickCreation]);

  useEffect(() => {
    if (activeTab !== "my-events" || !pendingPlanScrollId.current) return;
    const card = planCardRefs.current.get(pendingPlanScrollId.current);
    if (!card) return;
    pendingPlanScrollId.current = null;
    card.scrollIntoView({ behavior: "smooth", block: "center" });
  }, [activeTab, plans]);

  useEffect(() => {
    void loadEvents();
    const { data: authListener } = supabase.auth.onAuthStateChange((_event, session) => {
      void loadUserData(session?.user?.id || null).catch((error) => {
        console.error("Unable to refresh event account data", error);
      });
    });
    const proposalChannel = supabase.channel("special-event-proposals")
      .on("postgres_changes", { event: "*", schema: "public", table: "special_event_plans" }, () => {
        void supabase.auth.getUser().then(({ data }) => loadUserData(data.user?.id || null));
      })
      .on("postgres_changes", { event: "*", schema: "public", table: "special_event_invitations" }, () => {
        void supabase.auth.getUser().then(({ data }) => loadUserData(data.user?.id || null));
      })
      .subscribe();
    return () => {
      authListener.subscription.unsubscribe();
      void proposalChannel.unsubscribe();
    };
  }, []);

  const eventCategories = useMemo(() => {
    const categories = events.map((event) => event.category).filter((category): category is string => Boolean(category));
    return ["All", ...Array.from(new Set(categories))];
  }, [events]);

  const filteredEvents = useMemo(() => {
    const query = searchTerm.trim().toLowerCase();
    return events.filter((event) => {
      const matchesSearch = !query || [event.title, event.description, event.location, event.host_name, event.category]
        .filter(Boolean)
        .some((value) => value!.toLowerCase().includes(query));
      const matchesCategory = selectedCategory === "All" || event.category === selectedCategory;
      return matchesSearch && matchesCategory;
    });
  }, [events, searchTerm, selectedCategory]);

  const featuredEvents = filteredEvents.filter((event) => event.featured);
  const getEvent = (eventId: string) => [...events, ...linkedEvents, ...bookedEvents, ...(sharedEvent ? [sharedEvent] : [])].find((event) => event.id === eventId);
  const getTotalEventItems = () => Object.values(eventCart).reduce((total, count) => total + count, 0);

  const canManageEvents = profileRole === "manager" || profileRole === "admin";

  const requireAuth = () => {
    if (isSignedIn) return true;
    const returnTo = `${window.location.pathname}${window.location.search}`;
    navigate(`/login?returnTo=${encodeURIComponent(returnTo)}`);
    return false;
  };

  const addToEventCart = (eventId: string) => {
    const event = getEvent(eventId);
    if (!event) return;
    const existingEventIds = Object.keys(eventCart).filter((id) => id !== eventId);
    if (existingEventIds.length) {
      setNotice("Book one event at a time so each payment and ticket remains unambiguous.");
      return;
    }
    const currentQuantity = eventCart[eventId] || 0;
    if (currentQuantity >= event.max_tickets_per_order) {
      setNotice(`You can book up to ${event.max_tickets_per_order} tickets per order.`);
      return;
    }
    if (currentQuantity + event.attendees_count >= event.capacity) {
      setNotice("This event has no more tickets available.");
      return;
    }
    setNotice("");
    setEventCart((previous) => ({ ...previous, [eventId]: currentQuantity + 1 }));
  };

  const updateEventCart = (eventId: string, quantity: number) => {
    const event = getEvent(eventId);
    if (!event) return;
    if (quantity <= 0) {
      setEventCart((previous) => {
        const next = { ...previous };
        delete next[eventId];
        return next;
      });
      return;
    }
    const existingEventIds = Object.keys(eventCart).filter((id) => id !== eventId);
    if (existingEventIds.length) {
      setNotice("Book one event at a time so each payment and ticket remains unambiguous.");
      return;
    }
    if (quantity > event.max_tickets_per_order) {
      setNotice(`You can book up to ${event.max_tickets_per_order} tickets per order.`);
      return;
    }
    if (event.attendees_count + quantity > event.capacity) {
      setNotice("The selected quantity exceeds the remaining capacity.");
      return;
    }
    setEventCart((previous) => ({ ...previous, [eventId]: quantity }));
  };

  const removeFromEventCart = (eventId: string) => {
    setEventCart((previous) => {
      const next = { ...previous };
      delete next[eventId];
      return next;
    });
  };

  const clearEventCart = () => setEventCart({});

  const toggleFavorite = async (eventId: string) => {
    if (!requireAuth()) return;
    setNotice("");
    const { data: authData } = await supabase.auth.getUser();
    if (!authData.user) return;
    const isFavorite = favoriteIds.has(eventId);
    const result = isFavorite
      ? await supabase.from("special_event_favorites").delete().eq("user_id", authData.user.id).eq("event_id", eventId)
      : await supabase.from("special_event_favorites").insert({ user_id: authData.user.id, event_id: eventId });
    if (result.error) {
      setNotice("We could not update your saved events.");
      return;
    }
    setFavoriteIds((previous) => {
      const next = new Set(previous);
      if (isFavorite) next.delete(eventId);
      else next.add(eventId);
      return next;
    });
  };

  const createPrivateInvitation = async (plan: SpecialEventPlan) => {
    if (!requireAuth()) return;
    const email = inviteEmails[plan.id]?.trim();
    if (!email) {
      setNotice("Enter the guest's email address to create an invitation.");
      return;
    }
    const { data, error } = await supabase.rpc("create_special_event_invitation", {
      target_plan_id: plan.id,
      invited_email: email,
    });
    if (error) {
      setNotice(error.message);
      return;
    }
    const row = Array.isArray(data) ? data[0] : data;
    const url = new URL("/events", window.location.origin);
    url.searchParams.set("invite", row.invitation_token);
    setCreatedInviteLinks((links) => ({ ...links, [plan.id]: url.toString() }));
    setInviteEmails((emails) => ({ ...emails, [plan.id]: "" }));
    setNotice("Invitation created. Copy the secure link and send it to the invited guest.");
    if (currentUserId) await loadUserData(currentUserId);
  };

  const respondToInvitation = async (invitationId: string, accept: boolean) => {
    if (!requireAuth()) return;
    setInvitationLoading(true);
    const { data, error } = await supabase.rpc("respond_to_special_event_invitation", {
      target_invitation_id: invitationId,
      accept_invitation: accept,
    });
    setInvitationLoading(false);
    if (error) {
      setNotice(error.message);
      return;
    }
    setInvitationInfo(data as SpecialEventInvitationSummary);
    setNotice(accept ? "Invitation accepted. You can now reserve your place." : "Invitation declined.");
    if (currentUserId) await loadUserData(currentUserId);
  };

  const shareEvent = (event: { title: string; share_token?: string | null; is_private?: boolean }) => {
    if (event.is_private || !event.share_token) return;
    setShareEventTarget(event);
  };

  const eventShareUrl = shareEventTarget?.share_token && !shareEventTarget.is_private
    ? new URL(`/events?event=${encodeURIComponent(shareEventTarget.share_token)}`, window.location.origin).toString()
    : null;

  const shareWithDevice = async () => {
    if (!shareEventTarget || !eventShareUrl || !navigator.share) return;
    try {
      await navigator.share({ title: shareEventTarget.title, text: `Join me at ${shareEventTarget.title}`, url: eventShareUrl });
    } catch (error) {
      if (error instanceof Error && error.name === "AbortError") return;
      setNotice("We could not share this event link.");
    }
  };

  const copyEventLink = async () => {
    if (!eventShareUrl) return;
    try {
      await navigator.clipboard.writeText(eventShareUrl);
      setNotice("Event link copied.");
    } catch {
      setNotice("We could not copy this event link.");
    }
  };

  const copyInviteLink = async (planId: string) => {
    const link = createdInviteLinks[planId];
    if (!link) return;
    try {
      await navigator.clipboard.writeText(link);
      setNotice("Invitation link copied.");
    } catch {
      setNotice("We could not copy the invitation link.");
    }
  };

  const bookEvent = (event: SpecialEvent, invitationId: string | null = null) => {
    if (invitationId) setActiveInvitationBookingId(invitationId);
    else setActiveInvitationBookingId(null);
    setSelectedEvent(event.id);
    setEventCart({ [event.id]: 1 });
    setShowCheckout(true);
  };

  const submitPlan = async () => {
    if (!requireAuth()) return;
    if (!planForm.title.trim() || !planForm.eventDate || !planForm.facilityId || !planForm.expectedGuests || !planForm.contactName.trim() || !planForm.contactEmail.trim() || (planForm.entryType === "paid" && Number(planForm.entryFee) <= 0)) {
      setNotice("Complete the event title, date and time, facility, guest count, and contact details.");
      return;
    }
    if (toEventInstant(planForm.eventDate, planForm.endTime) <= toEventInstant(planForm.eventDate, planForm.startTime)) {
      setNotice("The event end time must be after its start time.");
      return;
    }
    setIsSavingPlan(true);
    setNotice("");
    try {
      const { data: authData } = await supabase.auth.getUser();
      if (!authData.user) return;
      const { data: planId, error } = await supabase.rpc("submit_special_event_proposal", {
        target_plan_id: editingPlanId,
        proposal_title: planForm.title.trim(),
        proposal_description: planForm.description.trim() || null,
        proposal_category: planForm.category.trim() || "Social Gathering",
        proposal_starts_at: toEventInstant(planForm.eventDate, planForm.startTime),
        proposal_ends_at: toEventInstant(planForm.eventDate, planForm.endTime),
        proposal_timezone: "Africa/Kampala",
        proposal_facility_id: planForm.facilityId,
        proposal_expected_guests: Number(planForm.expectedGuests),
        proposal_contact_name: planForm.contactName.trim(),
        proposal_contact_email: planForm.contactEmail.trim(),
        proposal_contact_phone: planForm.contactPhone.trim() || null,
        proposal_image_url: planForm.imageUrl || null,
        proposal_is_private: planForm.isPrivate,
        proposal_entry_type: planForm.entryType,
        proposal_entry_fee: planForm.entryType === "paid" ? Number(planForm.entryFee) : 0,
        proposal_share_manager_operations: planForm.shareManagerOperations,
      });
      if (error) throw error;
      pendingPlanScrollId.current = planId;
      setEditingPlanId(null);
      setPlanForm(initialPlan);
      setNotice("Your event proposal has been sent to the hotel team for review.");
      setActiveTab("my-events");
      try {
        await loadUserData(authData.user.id);
      } catch (error) {
        pendingPlanScrollId.current = null;
        console.error("Unable to refresh event proposals", error);
        setNotice("Your proposal was submitted, but we could not refresh your event list.");
      }
    } catch (error) {
      console.error("Unable to create event proposal", error);
      const message = error && typeof error === "object" && "message" in error && typeof error.message === "string"
        ? error.message
        : "Please try again.";
      setNotice(`We could not submit your event proposal: ${message}`);
    } finally {
      setIsSavingPlan(false);
    }
  };

  const uploadPlanImage = async (file: File) => {
    const uploaded = await uploadFile(file, "special-events");
    if (!uploaded) {
      setNotice("We could not upload the event poster.");
      return;
    }
    setPlanForm((form) => ({ ...form, imageUrl: uploaded.publicUrl }));
    setNotice("Event poster uploaded.");
  };

  const uploadEventImage = async (file: File) => {
    const uploaded = await uploadFile(file, "special-events");
    if (!uploaded) {
      setNotice("We could not upload the event image.");
      return;
    }
    setEventForm((form) => ({ ...form, imageUrl: uploaded.publicUrl }));
    setNotice("Event image uploaded.");
  };

  const saveManagedEvent = async () => {
    if (!requireAuth() || !canManageEvents) return;
    if (!eventForm.title.trim() || !eventForm.startsAt || !eventForm.endsAt || !eventForm.facilityId || !eventForm.price || !eventForm.capacity || (hotelOrganizations.length > 1 && !eventForm.organizationId)) {
      setNotice("Complete the event title, dates, facility, price, and capacity.");
      return;
    }
    setIsSavingPlan(true);
    setNotice("");
    try {
      const { data: authData } = await supabase.auth.getUser();
      if (!authData.user) return;
      const values = {
        title: eventForm.title.trim(),
        description: eventForm.description.trim() || null,
        category: eventForm.category.trim() || null,
        starts_at: toEventInstant(eventForm.startsAt.slice(0, 10), eventForm.startsAt.slice(11, 16), eventForm.timezone),
        ends_at: toEventInstant(eventForm.endsAt.slice(0, 10), eventForm.endsAt.slice(11, 16), eventForm.timezone),
        timezone: eventForm.timezone.trim() || "UTC",
        location: facilities.find((facility) => facility.id === eventForm.facilityId)?.name || "",
        facility_id: eventForm.facilityId,
        organization_id: eventForm.organizationId || (hotelOrganizations.length === 1 ? hotelOrganizations[0].id : null),
        price: Number(eventForm.price),
        currency: eventForm.currency.trim().toUpperCase(),
        capacity: Number(eventForm.capacity),
        ticket_type_capacity: Number(eventForm.capacity),
        max_tickets_per_order: Number(eventForm.maxTicketsPerOrder),
        image_url: eventForm.imageUrl || null,
        host_name: eventForm.hostName.trim() || null,
        featured: eventForm.featured,
        status: "published" as const,
        organizer_id: authData.user.id,
        created_by: authData.user.id,
      };
      const result = editingEventId
        ? await supabase.from("special_events").update(values).eq("id", editingEventId).eq("created_by", authData.user.id)
        : await supabase.from("special_events").insert(values);
      if (result.error) throw result.error;
      setEventForm(initialEventForm);
      setEditingEventId(null);
      setNotice("The event is now published.");
      await loadEvents();
    } catch (error) {
      console.error("Unable to save special event", error);
      setNotice("We could not save the published event.");
    } finally {
      setIsSavingPlan(false);
    }
  };

  const editManagedEvent = (event: SpecialEvent) => {
    setEditingEventId(event.id);
    setEventForm({ title: event.title, description: event.description || "", category: event.category || "Fine Dining", startsAt: dateTimeInputInEventZone(event.starts_at, event.timezone), endsAt: dateTimeInputInEventZone(event.ends_at, event.timezone), timezone: event.timezone, facilityId: event.facility_id || facilities.find((facility) => facility.name === event.location)?.id || "", organizationId: event.organization_id || "", price: String(event.price), currency: event.currency, capacity: String(event.capacity), maxTicketsPerOrder: String(event.max_tickets_per_order || 10), hostName: event.host_name || "", imageUrl: event.image_url || "", featured: event.featured });
    setActiveTab("planning");
  };

  const deleteManagedEvent = async (eventId: string) => {
    if (!requireAuth() || !canManageEvents) return;
    const { data: authData } = await supabase.auth.getUser();
    if (!authData.user) return;
    const { error } = await supabase.from("special_events").update({ status: "cancelled" }).eq("id", eventId).eq("created_by", authData.user.id);
    if (error) setNotice("We could not cancel that event.");
    else await loadEvents();
  };

  const editPlan = (plan: SpecialEventPlan) => {
    setEditingPlanId(plan.id);
    setPlanForm({ title: plan.title, eventDate: plan.event_date, startTime: plan.starts_at ? timeInEventZone(plan.starts_at, plan.timezone) : "09:00", endTime: plan.ends_at ? timeInEventZone(plan.ends_at, plan.timezone) : "12:00", facilityId: plan.facility_id || "", category: plan.category || "Social Gathering", expectedGuests: String(plan.expected_guests), entryType: plan.entry_type, entryFee: plan.entry_type === "paid" ? String(plan.entry_fee) : "", description: plan.description || "", imageUrl: plan.image_url || "", contactName: plan.contact_name || "", contactEmail: plan.contact_email || "", contactPhone: plan.contact_phone || "", isPrivate: plan.is_private, shareManagerOperations: plan.share_manager_operations });
    setActiveTab("my-events");
    setShouldScrollToQuickCreation(true);
  };

  const deletePlan = async (planId: string) => {
    if (!requireAuth()) return;
    const { error } = await supabase.from("special_event_plans").delete().eq("id", planId).eq("status", "submitted");
    if (error) setNotice("We could not delete that event proposal.");
    else {
      const { data: authData } = await supabase.auth.getUser();
      if (authData.user) await loadUserData(authData.user.id);
    }
  };

  const getProposalReviewForm = (plan: SpecialEventPlan): ProposalReviewForm => proposalReviewForms[plan.id] || {
    title: plan.title,
    description: plan.description || "",
    category: plan.category,
    startsAt: plan.starts_at ? dateTimeInputInEventZone(plan.starts_at, plan.timezone) : "",
    endsAt: plan.ends_at ? dateTimeInputInEventZone(plan.ends_at, plan.timezone) : "",
    facilityId: plan.facility_id || "",
    expectedGuests: String(plan.expected_guests),
  };

  const reviewProposal = async (plan: SpecialEventPlan, action: "approve" | "decline" | "suggest_changes") => {
    if (!requireAuth() || !canManageEvents) return;
    const suggestion = getProposalReviewForm(plan);
    if (action === "suggest_changes" && (!suggestion.facilityId || !suggestion.startsAt || !suggestion.endsAt || Number(suggestion.expectedGuests) < 1)) {
      setNotice("Complete the suggested dates, facility, and guest capacity.");
      return;
    }
    setIsSavingPlan(true);
    setNotice("");
    const { error } = await supabase.rpc("review_special_event_proposal", {
      target_plan_id: plan.id,
      review_action: action,
      suggested_values: action === "suggest_changes" ? {
        title: suggestion.title,
        description: suggestion.description,
        category: suggestion.category,
        starts_at: toEventInstant(suggestion.startsAt.slice(0, 10), suggestion.startsAt.slice(11, 16), plan.timezone),
        ends_at: toEventInstant(suggestion.endsAt.slice(0, 10), suggestion.endsAt.slice(11, 16), plan.timezone),
        facility_id: suggestion.facilityId,
        expected_guests: Number(suggestion.expectedGuests),
      } : null,
      review_message: proposalReviewNotes[plan.id]?.trim() || null,
    });
    setIsSavingPlan(false);
    if (error) {
      setNotice(error.message);
      return;
    }
    setNotice(action === "approve" ? "Proposal approved and scheduled." : action === "decline" ? "Proposal declined." : "Your suggestions were sent to the proposer.");
    const { data: authData } = await supabase.auth.getUser();
    if (authData.user) await loadUserData(authData.user.id);
    await loadEvents();
  };

  const respondToProposal = async (plan: SpecialEventPlan, accept: boolean) => {
    setIsSavingPlan(true);
    setNotice("");
    const { error } = await supabase.rpc("respond_to_special_event_proposal", {
      target_plan_id: plan.id,
      accept_suggestions: accept,
    });
    setIsSavingPlan(false);
    if (error) {
      setNotice(error.message);
      return;
    }
    setNotice(accept ? "Suggested changes accepted and the event is scheduled." : "Suggested changes declined.");
    const { data: authData } = await supabase.auth.getUser();
    if (authData.user) await loadUserData(authData.user.id);
  };

  const publishProposal = async (plan: SpecialEventPlan) => {
    if (!requireAuth() || !canManageEvents) return;
    setIsSavingPlan(true);
    setNotice("");
    const { error } = await supabase.rpc("publish_special_event_proposal", {
      target_plan_id: plan.id,
    });
    setIsSavingPlan(false);
    if (error) {
      setNotice(error.message);
      return;
    }
    setNotice("The event is now published in Hotel Events.");
    const { data: authData } = await supabase.auth.getUser();
    if (authData.user) await loadUserData(authData.user.id);
    await loadEvents();
  };

  const retryBookingPayment = async (bookingId: string) => {
    setRetryingBookingId(bookingId);
    setNotice("");
    try {
      const { data: { session } } = await supabase.auth.getSession();
      if (!session?.access_token) {
        const returnTo = `${window.location.pathname}${window.location.search}`;
    navigate(`/login?returnTo=${encodeURIComponent(returnTo)}`);
        return;
      }
      const response = await fetch("/api/payments/special-events/session", {
        method: "POST",
        headers: { Authorization: `Bearer ${session.access_token}`, "content-type": "application/json" },
        body: JSON.stringify({ bookingId }),
      });
      const payload = await response.json() as { paymentUrl?: string; error?: string };
      if (!response.ok || !payload.paymentUrl) throw new Error(payload.error || "Unable to reopen secure payment.");
      if (window.top && window.top !== window.self) window.top.location.replace(payload.paymentUrl);
      else window.location.replace(payload.paymentUrl);
    } catch (error) {
      setNotice(error instanceof Error ? error.message : "Unable to retry event payment.");
    } finally {
      setRetryingBookingId(null);
    }
  };

  const handleBooked = async () => {
    clearEventCart();
    setShowCheckout(false);
    setActiveTab("my-tickets");
    const { data: authData } = await supabase.auth.getUser();
    if (authData.user) await loadUserData(authData.user.id);
    await loadEvents();
  };

  const renderEventCard = (event: SpecialEvent, featured = false) => {
    const isFavorite = favoriteIds.has(event.id);
    const remaining = Math.max(event.capacity - event.attendees_count, 0);
    return (
      <div key={event.id} className={featured ? "relative bg-white rounded-xl shadow-lg overflow-hidden hover:shadow-xl transition-shadow" : "bg-white rounded-lg shadow-md overflow-hidden hover:shadow-lg transition-shadow"}>
        {featured && <div className="absolute top-4 right-4 z-10"><Badge className="bg-sheraton-gold text-sheraton-navy">Featured</Badge></div>}
        {event.image_url ? <img src={event.image_url} alt={event.title} loading="lazy" className={featured ? "h-48 w-full object-cover" : "h-40 w-full object-cover"} /> : <div className={featured ? "h-48 bg-gradient-to-br from-sheraton-cream to-sheraton-pearl flex items-center justify-center" : "h-40 bg-gradient-to-br from-sheraton-cream to-sheraton-pearl flex items-center justify-center"}><Award className={featured ? "h-16 w-16 text-sheraton-gold" : "h-12 w-12 text-sheraton-gold"} /></div>}
        <div className={featured ? "p-6" : "p-4"}>
          {featured ? (
            <div className="flex items-center gap-2 mb-2"><Star className="h-4 w-4 text-yellow-500 fill-current" /><span className="text-sm text-gray-600">{event.rating.toFixed(1)}</span><span className="text-sm text-gray-400">• {event.host_name || "Sheraton"}</span></div>
          ) : <Badge variant="outline" className="mb-2">{event.category || "Experience"}</Badge>}
          <h4 className="font-semibold text-sheraton-navy mb-2">{event.title}</h4>
          {featured && <p className="text-gray-600 text-sm mb-3">{event.description}</p>}
          <div className="space-y-2 mb-4">
            <div className="flex items-center text-sm text-gray-600"><Calendar className="h-4 w-4 mr-2" />{formatEventDate(event.starts_at, event.timezone)}</div>
            <div className="flex items-center text-sm text-gray-600"><MapPin className="h-4 w-4 mr-2" />{event.location}</div>
            {featured && <div className="flex items-center text-sm text-gray-600"><Users className="h-4 w-4 mr-2" />{event.attendees_count}/{event.capacity} attending</div>}
          </div>
          <div className="flex items-center justify-between">
            <span className={featured ? "text-lg font-semibold text-sheraton-navy" : "font-semibold text-sheraton-navy"}>{formatEntry(event.price, event.currency)}</span>
            <div className="flex gap-2">
              {(event.created_by === currentUserId || operationalEventIds.has(event.id) || profileRole === "admin") && <Button variant="outline" size="sm" onClick={() => navigate(`/events/operations/${event.id}`)}>Operations</Button>}
              {!event.is_private && <Button variant="outline" size="sm" onClick={() => void shareEvent(event)} aria-label="Share event"><Share2 className="h-4 w-4" /></Button>}
              <Button variant="outline" size="sm" onClick={() => void toggleFavorite(event.id)} aria-label={isFavorite ? "Remove saved event" : "Save event"}><Heart className={`h-4 w-4 ${isFavorite ? "fill-sheraton-gold text-sheraton-gold" : ""}`} /></Button>
              <Button variant={featured ? "default" : "outline"} size="sm" className={featured ? "bg-sheraton-gold hover:bg-sheraton-gold/90 text-sheraton-navy" : ""} onClick={() => { setSelectedEvent(event.id); if (featured) bookEvent(event); }}>{featured ? "Book Now" : "Details"}</Button>
            </div>
          </div>
          {featured && remaining > 0 && remaining <= 5 && <p className="mt-3 text-xs text-amber-700">Only {remaining} places remaining</p>}
        </div>
      </div>
    );
  };

  const renderBrowseEvents = () => (
    <div className="space-y-6">
      <div className="flex flex-col md:flex-row gap-4 mb-6">
        <div className="relative flex-1"><Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 h-4 w-4" /><Input value={searchTerm} onChange={(event) => setSearchTerm(event.target.value)} placeholder="Search events..." className="pl-10" /></div>
        <div className="flex gap-2"><Button variant="outline" size="sm" onClick={() => { setSearchTerm(""); setSelectedCategory("All"); }}><Filter className="h-4 w-4 mr-2" />Filter</Button><select value={selectedCategory} onChange={(event) => setSelectedCategory(event.target.value)} className="px-3 py-2 border rounded-md">{eventCategories.map((category) => <option key={category} value={category}>{category}</option>)}</select></div>
      </div>
      {notice && <p role="status" className="rounded-md bg-sheraton-gold/20 p-3 text-sm text-sheraton-navy">{notice}</p>}
      {isLoading && <div className="rounded-lg bg-white p-10 text-center text-gray-600">Loading events...</div>}
      {!isLoading && errorMessage && <div className="rounded-lg bg-white p-10 text-center text-red-700">{errorMessage}</div>}
      {!isLoading && !errorMessage && !filteredEvents.length && <div className="rounded-lg bg-white p-10 text-center text-gray-600">No upcoming events match your search.</div>}
      {!isLoading && !errorMessage && featuredEvents.length > 0 && <div className="mb-8"><h3 className="text-xl font-semibold mb-4 text-sheraton-navy">Featured Events</h3><div className="grid md:grid-cols-2 gap-6">{featuredEvents.map((event) => renderEventCard(event, true))}</div></div>}
      {!isLoading && !errorMessage && filteredEvents.length > 0 && <div><h3 className="text-xl font-semibold mb-4 text-sheraton-navy">All Events</h3><div className="grid md:grid-cols-3 gap-4">{filteredEvents.map((event) => renderEventCard(event))}</div></div>}
      {selectedEvent && getEvent(selectedEvent) && <div className="bg-white rounded-lg shadow-md p-6">{getEvent(selectedEvent)?.image_url && <img src={getEvent(selectedEvent)!.image_url!} alt={getEvent(selectedEvent)!.title} loading="lazy" className="mb-5 max-h-80 w-full rounded-lg object-cover" />}<div className="flex items-start justify-between gap-4"><div><Badge variant="outline" className="mb-2">{getEvent(selectedEvent)?.category || "Experience"}</Badge><h3 className="text-xl font-semibold text-sheraton-navy">{getEvent(selectedEvent)?.title}</h3><p className="mt-2 text-gray-600">{getEvent(selectedEvent)?.description}</p></div><Button variant="outline" onClick={() => setSelectedEvent(null)}>Close</Button></div><div className="mt-4 flex flex-wrap gap-4 text-sm text-gray-600"><span><Calendar className="inline h-4 w-4 mr-1" />{formatEventDate(getEvent(selectedEvent)!.starts_at, getEvent(selectedEvent)!.timezone)}</span><span><MapPin className="inline h-4 w-4 mr-1" />{getEvent(selectedEvent)?.location}</span><span><Users className="inline h-4 w-4 mr-1" />{Math.max(getEvent(selectedEvent)!.capacity - getEvent(selectedEvent)!.attendees_count, 0)} places remaining</span><span>Entry: {formatEntry(getEvent(selectedEvent)!.price, getEvent(selectedEvent)!.currency)}</span></div>{!getEvent(selectedEvent)?.is_private || (invitationInfo?.event_id === selectedEvent && invitationInfo.invitation_status === "accepted") ? <Button className="mt-5 bg-sheraton-gold hover:bg-sheraton-gold/90 text-sheraton-navy" onClick={() => { const event = getEvent(selectedEvent); if (event) bookEvent(event, invitationInfo?.event_id === event.id && invitationInfo.invitation_status === "accepted" ? invitationInfo.id : null); }}>Reserve place</Button> : <p className="mt-5 text-sm text-gray-600">Accept a private invitation to reserve a place.</p>}{!getEvent(selectedEvent)?.is_private && <Button variant="outline" className="ml-2 mt-5" onClick={() => { const event = getEvent(selectedEvent); if (event) shareEvent(event); }}><Share2 className="mr-2 h-4 w-4" />Share event</Button>}</div>}
    </div>
  );

  const renderMyEvents = () => (
    <div className="space-y-6">
      <div className="flex items-center justify-between"><h3 className="text-xl font-semibold text-sheraton-navy">{activeTab === "my-tickets" ? "My Tickets" : "My Events"}</h3>{activeTab === "my-events" && <Button onClick={() => { setActiveTab("my-events"); setShouldScrollToQuickCreation(true); }} className="bg-sheraton-gold hover:bg-sheraton-gold/90 text-sheraton-navy"><Plus className="h-4 w-4 mr-2" />Create Event</Button>}</div>
      {!isSignedIn && <div className="bg-white rounded-lg shadow-md p-6 text-center text-gray-600">{activeTab === "my-tickets" ? "Sign in to view your event bookings and tickets." : "Sign in to view and manage your event proposals."}</div>}
      {isSignedIn && activeTab === "my-tickets" && !bookings.length && <div className="bg-white rounded-lg shadow-md p-6 text-center text-gray-600">Your event bookings and tickets will appear here.</div>}{isSignedIn && activeTab === "my-events" && !plans.length && <div className="bg-white rounded-lg shadow-md p-6 text-center text-gray-600">Your created event proposals will appear here.</div>}{activeTab === "my-events" && invitationInfo && <section className="space-y-3 rounded-xl border border-violet-200 bg-violet-50 p-5"><div><Badge variant="outline" className="mb-2">Private event invitation</Badge><h4 className="text-lg font-semibold text-sheraton-navy">{invitationInfo.event.title}</h4><p className="text-sm text-gray-700">{formatEventDate(invitationInfo.event.starts_at, invitationInfo.event.timezone)} · {invitationInfo.event.location} · {formatEntry(invitationInfo.event.price, invitationInfo.event.currency)}</p><p className="text-sm text-gray-600">Invitation for {invitationInfo.invitee_email}</p></div>{invitationInfo.invitation_status === "pending" ? <div className="flex flex-wrap gap-2"><Button onClick={() => void respondToInvitation(invitationInfo.id, true)} disabled={invitationLoading}>Accept invitation</Button><Button variant="outline" onClick={() => void respondToInvitation(invitationInfo.id, false)} disabled={invitationLoading}>Decline</Button></div> : invitationInfo.invitation_status === "accepted" && <Button onClick={() => bookEvent(invitationInfo.event, invitationInfo.id)}>Reserve place</Button>}</section>}{activeTab === "my-events" && incomingInvitations.filter((invitation) => invitation.id !== invitationInfo?.id).length > 0 && <section className="space-y-3 rounded-xl border bg-white p-5"><h4 className="font-semibold text-sheraton-navy">Private event invitations</h4>{incomingInvitations.filter((invitation) => invitation.id !== invitationInfo?.id).map((invitation) => <div key={invitation.id} className="flex flex-wrap items-center justify-between gap-3 rounded-lg border p-3"><div><p className="font-medium text-sheraton-navy">{invitation.event.title}</p><p className="text-sm text-gray-600">{formatEventDate(invitation.event.starts_at, invitation.event.timezone)} · {formatEntry(invitation.event.price, invitation.event.currency)}</p></div>{invitation.invitation_status === "pending" ? <div className="flex gap-2"><Button size="sm" onClick={() => void respondToInvitation(invitation.id, true)} disabled={invitationLoading}>Accept</Button><Button size="sm" variant="outline" onClick={() => void respondToInvitation(invitation.id, false)} disabled={invitationLoading}>Decline</Button></div> : <Button size="sm" onClick={() => bookEvent(invitation.event, invitation.id)}>Reserve place</Button>}</div>)}</section>}
      {activeTab === "my-events" && canManageEvents && <section className="space-y-4 rounded-xl border border-sheraton-gold/40 bg-white p-5 shadow-sm"><div><h4 className="text-lg font-semibold text-sheraton-navy">Event proposals awaiting review</h4><p className="text-sm text-gray-600">Review facility availability and event details before scheduling.</p></div>{proposalQueue.length === 0 && <p className="text-sm text-gray-500">No new proposals need review.</p>}{proposalQueue.map((plan) => {
        const review = getProposalReviewForm(plan);
        return <article key={plan.id} className="space-y-4 rounded-lg border p-4"><div className="flex flex-wrap items-start justify-between gap-3"><div><h5 className="font-semibold text-sheraton-navy">{plan.title}</h5><p className="text-sm text-gray-600">{plan.contact_name} · <a className="underline" href={`mailto:${plan.contact_email}`}>{plan.contact_email}</a>{plan.contact_phone && <> · {plan.contact_phone}</>}</p><p className="mt-1 text-sm text-gray-600">Requested: {plan.location} · {plan.expected_guests} guests · {plan.starts_at ? formatEventDate(plan.starts_at, plan.timezone) : plan.event_date}</p>{plan.is_private && <Badge variant="outline" className="mt-2">Private proposal</Badge>}</div></div><div className="grid gap-3 md:grid-cols-2"><Input aria-label="Suggested event title" value={review.title} onChange={(event) => setProposalReviewForms((forms) => ({ ...forms, [plan.id]: { ...getProposalReviewForm(plan), title: event.target.value } }))} placeholder="Suggested title" /><Input aria-label="Suggested event category" value={review.category} onChange={(event) => setProposalReviewForms((forms) => ({ ...forms, [plan.id]: { ...getProposalReviewForm(plan), category: event.target.value } }))} placeholder="Category" /><Input aria-label="Suggested start time" type="datetime-local" value={review.startsAt} onChange={(event) => setProposalReviewForms((forms) => ({ ...forms, [plan.id]: { ...getProposalReviewForm(plan), startsAt: event.target.value } }))} /><Input aria-label="Suggested end time" type="datetime-local" value={review.endsAt} onChange={(event) => setProposalReviewForms((forms) => ({ ...forms, [plan.id]: { ...getProposalReviewForm(plan), endsAt: event.target.value } }))} /><Select value={review.facilityId} onValueChange={(facilityId) => setProposalReviewForms((forms) => ({ ...forms, [plan.id]: { ...getProposalReviewForm(plan), facilityId } }))}><SelectTrigger><SelectValue placeholder="Suggested facility" /></SelectTrigger><SelectContent>{facilities.map((facility) => <SelectItem key={facility.id} value={facility.id}>{facility.name}</SelectItem>)}</SelectContent></Select><Input aria-label="Suggested guest capacity" type="number" min="1" value={review.expectedGuests} onChange={(event) => setProposalReviewForms((forms) => ({ ...forms, [plan.id]: { ...getProposalReviewForm(plan), expectedGuests: event.target.value } }))} placeholder="Guest capacity" /><Textarea className="md:col-span-2" value={review.description} onChange={(event) => setProposalReviewForms((forms) => ({ ...forms, [plan.id]: { ...getProposalReviewForm(plan), description: event.target.value } }))} placeholder="Suggested event description" /><Textarea className="md:col-span-2" value={proposalReviewNotes[plan.id] || ""} onChange={(event) => setProposalReviewNotes((notes) => ({ ...notes, [plan.id]: event.target.value }))} placeholder="Message for the proposer" /></div><div className="flex flex-wrap gap-2"><Button onClick={() => void reviewProposal(plan, "approve")} disabled={isSavingPlan}>Approve and schedule</Button><Button variant="outline" onClick={() => void reviewProposal(plan, "suggest_changes")} disabled={isSavingPlan}>Suggest changes</Button><Button variant="destructive" onClick={() => void reviewProposal(plan, "decline")} disabled={isSavingPlan}>Decline proposal</Button></div></article>;
      })}</section>}
      {activeTab === "my-events" && canManageEvents && <section className="space-y-3 rounded-xl bg-white p-5 shadow-sm"><div><h4 className="text-lg font-semibold text-sheraton-navy">Scheduled proposals</h4><p className="text-sm text-gray-600">Only the hotel can publish eligible public proposals in Hotel Events.</p></div>{scheduledProposals.map((plan) => <div key={plan.id} className="flex flex-wrap items-center justify-between gap-3 rounded-lg border p-4"><div><p className="font-medium text-sheraton-navy">{plan.title}</p><p className="text-sm text-gray-600">{plan.is_private ? "Private · not eligible for public listing" : plan.published_at ? "Published in Hotel Events" : "Approved · awaiting optional publication"}</p></div>{!plan.is_private && !plan.published_at && <Button onClick={() => void publishProposal(plan)} disabled={isSavingPlan}>Publish to Hotel Events</Button>}</div>)}</section>}
      <div className="grid md:grid-cols-2 gap-4">
        {activeTab === "my-tickets" && bookings.map((booking) => {
          const event = getEvent(booking.event_id);
          return <div key={booking.id} className="bg-white rounded-lg shadow-md p-6"><div className="flex items-center justify-between mb-4"><h4 className="font-semibold text-sheraton-navy">{event?.title || `Event booking ${booking.order_number}`}</h4><Badge variant={booking.status === "confirmed" ? "default" : "secondary"}>{booking.status}</Badge></div><div className="flex items-center text-sm text-gray-600 mb-2"><Calendar className="h-4 w-4 mr-2" />{event ? formatEventDay(event.starts_at, event.timezone) : "Date pending"}</div><p className="text-sm text-gray-600 mb-4">{booking.quantity} ticket{booking.quantity === 1 ? "" : "s"} • {Number(booking.total_amount) === 0 ? "Free registration" : booking.payment_status}</p>{booking.status === "pending" && booking.payment_status === "pending" && booking.expires_at && new Date(booking.expires_at).getTime() > Date.now() && <Button className="mb-3" onClick={() => void retryBookingPayment(booking.id)} disabled={retryingBookingId !== null}>{retryingBookingId === booking.id ? "Opening secure checkout…" : "Continue payment"}</Button>}{booking.payment_status === "manual_review" && <p className="mb-3 text-sm text-amber-700">Payment is verified and being reviewed by the event team.</p>}{tickets.filter((ticket) => ticket.booking_id === booking.id).map((ticket) => <div key={ticket.id} className="mb-4 rounded-lg border p-3"><div className="flex items-center gap-3"><TicketQr token={ticket.ticket_token} size={112} /><div><p className="font-medium text-sheraton-navy">Ticket {ticket.ticket_number}</p><p className="text-sm text-gray-600">{ticket.status === "checked_in" ? "Checked in" : ticket.status}</p><p className="break-all text-xs text-gray-500">{ticket.ticket_token}</p><Button variant="outline" size="sm" onClick={() => navigator.clipboard?.writeText(ticket.ticket_token)}>Copy ticket code</Button></div></div></div>)}<div className="flex gap-2"><Button variant="outline" size="sm" onClick={() => setActiveTab("browse")}>View Event</Button><Button variant="outline" size="sm" onClick={() => navigator.clipboard?.writeText(booking.confirmation_number)}><Share2 className="h-4 w-4" /></Button></div></div>;
        })}
        {activeTab === "my-events" && plans.map((plan) => <div key={plan.id} ref={(element) => { if (element) planCardRefs.current.set(plan.id, element); else planCardRefs.current.delete(plan.id); }} className={`rounded-lg shadow-md overflow-hidden border ${plan.is_private && plan.status === "scheduled" ? "border-violet-300 bg-violet-50" : "border-gray-100 bg-white"}`}><div className="p-6">{plan.image_url && <img src={plan.image_url} alt={plan.title} loading="lazy" className="mb-4 h-40 w-full rounded-lg object-cover" />}<div className="flex items-center justify-between mb-4"><h4 className="font-semibold text-sheraton-navy">{plan.title}</h4><div className="flex gap-2"><Badge variant={plan.status === "scheduled" ? "default" : "secondary"}>{plan.status === "changes_requested" ? "Changes requested" : plan.status}</Badge>{plan.is_private && <Badge variant="outline">Private event</Badge>}{plan.published_at && <Badge variant="outline">Published in Hotel Events</Badge>}</div></div><div className="flex items-center text-sm text-gray-600 mb-2"><Calendar className="h-4 w-4 mr-2" />{plan.starts_at ? formatEventDate(plan.starts_at, plan.timezone) : plan.event_date}</div><p className="text-sm text-gray-600 mb-2">{plan.location} • {plan.expected_guests} expected guests</p><p className="mb-4 text-sm font-medium text-sheraton-navy">Entry: {formatEntry(plan.entry_fee, plan.entry_currency)}</p>{plan.manager_note && <p className="mb-4 rounded-md bg-amber-50 p-3 text-sm text-amber-900">Hotel team: {plan.manager_note}</p>}{plan.status === "scheduled" && !plan.is_private && <Button variant="outline" size="sm" className="mb-4" onClick={() => void shareEvent(plan)}><Share2 className="mr-2 h-4 w-4" />Share event</Button>}{plan.status === "scheduled" && plan.is_private && <section className="mb-4 space-y-3 rounded-lg border border-violet-200 bg-white/80 p-4"><h5 className="font-medium text-sheraton-navy">Invite guests</h5><div className="flex flex-col gap-2 sm:flex-row"><Input type="email" value={inviteEmails[plan.id] || ""} onChange={(event) => setInviteEmails((emails) => ({ ...emails, [plan.id]: event.target.value }))} placeholder="Guest email address" /><Button onClick={() => void createPrivateInvitation(plan)} disabled={isSavingPlan}><Mail className="mr-2 h-4 w-4" />Create invitation</Button></div>{createdInviteLinks[plan.id] && <div className="flex flex-wrap gap-2"><Button variant="outline" size="sm" onClick={() => void copyInviteLink(plan.id)}><Copy className="mr-2 h-4 w-4" />Copy invite link</Button><a className="inline-flex items-center justify-center rounded-md border px-3 py-2 text-sm font-medium" href={`mailto:${encodeURIComponent(inviteEmails[plan.id] || ownedInvitations.find((invitation) => invitation.event_plan_id === plan.id && invitation.status === "pending")?.invitee_email || "")}?subject=${encodeURIComponent(`Invitation: ${plan.title}`)}&body=${encodeURIComponent(`You are invited to ${plan.title}. Accept or decline here: ${createdInviteLinks[plan.id]}`)}`}><Mail className="mr-2 h-4 w-4" />Email invitation</a></div>}{ownedInvitations.filter((invitation) => invitation.event_plan_id === plan.id).map((invitation) => <p key={invitation.id} className="text-sm text-gray-600">{invitation.invitee_email} · {invitation.status}</p>)}</section>}{plan.status === "changes_requested" && <div className="mb-4 rounded-md bg-amber-50 p-3 text-sm text-amber-900"><p className="font-medium">Hotel suggested</p><p>{plan.suggested_title || plan.title} · {plan.suggested_category || plan.category} · {plan.suggested_facility_id ? facilities.find((facility) => facility.id === plan.suggested_facility_id)?.name : plan.location} · {plan.suggested_expected_guests || plan.expected_guests} guests</p>{plan.suggested_starts_at && <p>{formatEventDate(plan.suggested_starts_at, plan.timezone)}{plan.suggested_ends_at ? ` – ${timeInEventZone(plan.suggested_ends_at, plan.timezone)}` : ""}</p>}{plan.suggested_description && <p className="mt-1">{plan.suggested_description}</p>}</div>}{plan.description && <p className="text-sm text-gray-600 mb-4">{plan.description}</p>}<div className="flex flex-wrap gap-2">{plan.status === "changes_requested" && <><Button size="sm" onClick={() => void respondToProposal(plan, true)} disabled={isSavingPlan}>Accept suggested changes</Button><Button variant="outline" size="sm" onClick={() => void respondToProposal(plan, false)} disabled={isSavingPlan}>Decline changes</Button></>}{plan.status === "scheduled" && plan.special_event_id && <Button variant="outline" size="sm" onClick={() => navigate(`/events/operations/${plan.special_event_id}`)}>Event Operations</Button>}{plan.status === "submitted" && <><Button variant="outline" size="sm" onClick={() => editPlan(plan)}>Edit proposal</Button><Button variant="outline" size="sm" onClick={() => void deletePlan(plan.id)}>Withdraw</Button></>}</div></div></div>)}
      </div>
      {activeTab === "my-events" && (
        <div ref={quickEventCreationRef} className="scroll-mt-6">
          <div className="bg-white rounded-lg shadow-md p-6"><h4 className="text-lg font-semibold text-sheraton-navy mb-4">Quick Event Creation</h4><div className="grid md:grid-cols-2 gap-4"><div><label className="block text-sm font-medium mb-2">Event Title</label><Input value={planForm.title} onChange={(event) => setPlanForm((form) => ({ ...form, title: event.target.value }))} placeholder="Enter event name" /></div><div><label className="block text-sm font-medium mb-2">Event date</label><Input type="date" value={planForm.eventDate} onChange={(event) => setPlanForm((form) => ({ ...form, eventDate: event.target.value }))} /></div><div><label className="block text-sm font-medium mb-2">Start time</label><Input type="time" value={planForm.startTime} onChange={(event) => setPlanForm((form) => ({ ...form, startTime: event.target.value }))} /></div><div><label className="block text-sm font-medium mb-2">End time</label><Input type="time" value={planForm.endTime} onChange={(event) => setPlanForm((form) => ({ ...form, endTime: event.target.value }))} /></div><div><label className="block text-sm font-medium mb-2">Event category</label><Input value={planForm.category} onChange={(event) => setPlanForm((form) => ({ ...form, category: event.target.value }))} placeholder="e.g. Conference, Celebration" /></div><div><label className="block text-sm font-medium mb-2">Hotel facility</label><Select value={planForm.facilityId} onValueChange={(facilityId) => setPlanForm((form) => ({ ...form, facilityId }))}><SelectTrigger><SelectValue placeholder="Choose a venue facility" /></SelectTrigger><SelectContent>{facilities.map((facility) => <SelectItem key={facility.id} value={facility.id}>{facility.name}</SelectItem>)}</SelectContent></Select></div><div><label className="block text-sm font-medium mb-2">Expected guests</label><Input type="number" min="1" value={planForm.expectedGuests} onChange={(event) => setPlanForm((form) => ({ ...form, expectedGuests: event.target.value }))} placeholder="Number of guests" /></div><div className="flex items-center gap-5 rounded-md border p-3"><label className="flex items-center gap-2"><input type="radio" name="event-entry-type" checked={planForm.entryType === "free"} onChange={() => setPlanForm((form) => ({ ...form, entryType: "free", entryFee: "" }))} />Free entry</label><label className="flex items-center gap-2"><input type="radio" name="event-entry-type" checked={planForm.entryType === "paid"} onChange={() => setPlanForm((form) => ({ ...form, entryType: "paid" }))} />Paid entry</label></div>{planForm.entryType === "paid" && <div><label className="block text-sm font-medium mb-2">Entry fee (UGX)</label><Input type="number" min="0.01" step="0.01" value={planForm.entryFee} onChange={(event) => setPlanForm((form) => ({ ...form, entryFee: event.target.value }))} placeholder="Amount per attendee" /></div>}<div><label className="block text-sm font-medium mb-2">Proposer name</label><Input value={planForm.contactName} onChange={(event) => setPlanForm((form) => ({ ...form, contactName: event.target.value }))} placeholder="Your name" required /></div><div><label className="block text-sm font-medium mb-2">Contact email</label><Input type="email" value={planForm.contactEmail} onChange={(event) => setPlanForm((form) => ({ ...form, contactEmail: event.target.value }))} placeholder="you@example.com" required /></div><div><label className="block text-sm font-medium mb-2">Contact phone</label><Input type="tel" value={planForm.contactPhone} onChange={(event) => setPlanForm((form) => ({ ...form, contactPhone: event.target.value }))} placeholder="Phone number" /></div><div className="md:col-span-2"><label className="block text-sm font-medium mb-2">Event Description</label><Textarea value={planForm.description} onChange={(event) => setPlanForm((form) => ({ ...form, description: event.target.value }))} placeholder="Describe your event" /></div><div className="md:col-span-2"><label className="block text-sm font-medium mb-2">Event poster (optional)</label><Input type="file" accept="image/*" disabled={isUploading} onChange={(event) => { const file = event.currentTarget.files?.[0]; if (file) void uploadPlanImage(file); event.currentTarget.value = ""; }} />{isUploading && <p className="mt-1 text-sm text-gray-500">Uploading poster…</p>}{planForm.imageUrl && <img src={planForm.imageUrl} alt="Event poster preview" className="mt-3 h-40 w-full rounded-lg object-cover" />}</div><div className="md:col-span-2 space-y-3"><div className="flex items-center justify-between"><div><span className="text-sm font-medium">Private event</span><p className="text-xs text-gray-500">Private events stay out of Hotel Events.</p></div><Switch checked={planForm.isPrivate} onCheckedChange={(checked) => setPlanForm((form) => ({ ...form, isPrivate: checked }))} /></div><div className="flex items-center justify-between"><div><span className="text-sm font-medium">Give the hotel manager Operations access</span><p className="text-xs text-gray-500">Otherwise, you will manage event Operations yourself.</p></div><Switch checked={planForm.shareManagerOperations} onCheckedChange={(checked) => setPlanForm((form) => ({ ...form, shareManagerOperations: checked }))} /></div></div></div>{notice && <p role="status" className="mt-4 rounded-md bg-sheraton-gold/20 p-3 text-sm text-sheraton-navy">{notice}</p>}<Button disabled={isSavingPlan || isUploading} onClick={() => void submitPlan()} className="w-full mt-4 bg-sheraton-gold hover:bg-sheraton-gold/90 text-sheraton-navy">{isSavingPlan ? "Saving..." : editingPlanId ? "Update Event Proposal" : "Create Event Proposal"}</Button></div>
        </div>
      )}
    </div>
  );

  const planningTools = [
    { title: "Budget Calculator", description: "Plan your event budget with our interactive tool", icon: CreditCard, action: "Calculate" },
    { title: "Vendor Directory", description: "Find trusted local vendors and service providers", icon: Users, action: "Browse" },
    { title: "Timeline Planner", description: "Create detailed event timelines and schedules", icon: Clock, action: "Plan" },
    { title: "Guest Manager", description: "Manage invitations and RSVPs efficiently", icon: Users, action: "Manage" },
  ];

  const renderPlanning = () => (
    <div className="space-y-6">
      <div className="text-center mb-8"><h3 className="text-2xl font-semibold text-sheraton-navy mb-2">Event Planning Tools</h3><p className="text-gray-600">Professional tools to help you plan the perfect event</p></div>
      <div className="grid md:grid-cols-2 gap-6">{planningTools.map((tool) => <div key={tool.title} className="bg-white rounded-lg shadow-md p-6 hover:shadow-lg transition-shadow"><div className="flex items-center mb-4"><div className="p-3 bg-sheraton-cream rounded-lg mr-4"><tool.icon className="h-6 w-6 text-sheraton-navy" /></div><div><h4 className="font-semibold text-sheraton-navy">{tool.title}</h4><p className="text-sm text-gray-600">{tool.description}</p></div></div><Button onClick={() => setNotice(`${tool.title} will be connected to your submitted event proposal.`)} className="w-full bg-sheraton-gold hover:bg-sheraton-gold/90 text-sheraton-navy">{tool.action}</Button></div>)}</div>

      {canManageEvents && <div className="bg-white rounded-lg shadow-md p-6"><div className="flex items-center justify-between mb-4"><div><h4 className="text-lg font-semibold text-sheraton-navy">Create a Hotel Event</h4><p className="text-sm text-gray-600">This price applies only to hotel-organized events; creators set fees for their own events.</p></div>{editingEventId && <Button variant="outline" onClick={() => { setEditingEventId(null); setEventForm(initialEventForm); }}>Cancel edit</Button>}</div><div className="grid md:grid-cols-2 gap-4"><Input value={eventForm.title} onChange={(event) => setEventForm((form) => ({ ...form, title: event.target.value }))} placeholder="Event title" /><Input value={eventForm.category} onChange={(event) => setEventForm((form) => ({ ...form, category: event.target.value }))} placeholder="Category" /><Input type="datetime-local" value={eventForm.startsAt} onChange={(event) => setEventForm((form) => ({ ...form, startsAt: event.target.value }))} /><Input type="datetime-local" value={eventForm.endsAt} onChange={(event) => setEventForm((form) => ({ ...form, endsAt: event.target.value }))} />{hotelOrganizations.length > 0 && <div><label className="mb-2 block text-sm font-medium">Hotel ownership</label><Select value={eventForm.organizationId} onValueChange={(organizationId) => setEventForm((form) => ({ ...form, organizationId }))}><SelectTrigger><SelectValue placeholder="Choose the hotel" /></SelectTrigger><SelectContent>{hotelOrganizations.map((organization) => <SelectItem key={organization.id} value={organization.id}>{organization.name}</SelectItem>)}</SelectContent></Select></div>}<div><label className="mb-2 block text-sm font-medium">Hotel facility</label><Select value={eventForm.facilityId} onValueChange={(facilityId) => setEventForm((form) => ({ ...form, facilityId }))}><SelectTrigger><SelectValue placeholder="Choose a venue facility" /></SelectTrigger><SelectContent>{facilities.map((facility) => <SelectItem key={facility.id} value={facility.id}>{facility.name}</SelectItem>)}</SelectContent></Select></div><Input value={eventForm.hostName} onChange={(event) => setEventForm((form) => ({ ...form, hostName: event.target.value }))} placeholder="Host name" /><div className="md:col-span-2 space-y-2"><label className="block text-sm font-medium text-gray-700">Event image (optional)</label><Input type="file" accept="image/*" disabled={isUploading} onChange={(event) => { const file = event.currentTarget.files?.[0]; if (file) void uploadEventImage(file); event.currentTarget.value = ""; }} />{isUploading && <p className="text-sm text-gray-500">Uploading to secure storage…</p>}{eventForm.imageUrl && <img src={eventForm.imageUrl} alt="Event preview" className="h-32 w-full rounded-lg object-cover" />}</div><Input type="number" min="0" step="0.01" value={eventForm.price} onChange={(event) => setEventForm((form) => ({ ...form, price: event.target.value }))} placeholder="General admission price" /><Input value={eventForm.currency} onChange={(event) => setEventForm((form) => ({ ...form, currency: event.target.value }))} placeholder="Currency, e.g. UGX" /><Input type="number" min="1" value={eventForm.capacity} onChange={(event) => setEventForm((form) => ({ ...form, capacity: event.target.value }))} placeholder="Capacity / ticket limit" /><Input type="number" min="1" max="50" value={eventForm.maxTicketsPerOrder} onChange={(event) => setEventForm((form) => ({ ...form, maxTicketsPerOrder: event.target.value }))} placeholder="Max tickets per order" /><Input value={eventForm.timezone} onChange={(event) => setEventForm((form) => ({ ...form, timezone: event.target.value }))} placeholder="Timezone, e.g. Africa/Kampala" /><Textarea className="md:col-span-2" value={eventForm.description} onChange={(event) => setEventForm((form) => ({ ...form, description: event.target.value }))} placeholder="Event description" /></div><label className="mt-4 block text-sm">Event poster (public B2 image)<Input type="file" accept="image/*" disabled={isUploading} onChange={async (change) => { const file = change.target.files?.[0]; if (!file) return; if (!file.type.startsWith("image/")) { setNotice("Choose an image file for the event poster."); return; } const uploaded = await uploadFile(file, "special-events/posters"); if (uploaded) setEventForm((form) => ({ ...form, imageUrl: uploaded.publicUrl })); else setNotice("We could not upload the event poster."); }} />{eventForm.imageUrl && <img src={eventForm.imageUrl} alt="Event poster preview" className="mt-2 h-28 rounded object-cover" />}</label><div className="mt-4 flex items-center justify-between"><span className="text-sm font-medium">Featured event</span><Switch checked={eventForm.featured} onCheckedChange={(checked) => setEventForm((form) => ({ ...form, featured: checked }))} /></div><div className="mt-4 flex gap-2"><Button disabled={isSavingPlan} onClick={() => void saveManagedEvent()} className="bg-sheraton-gold hover:bg-sheraton-gold/90 text-sheraton-navy">{isSavingPlan ? "Saving..." : editingEventId ? "Update Published Event" : "Publish Event"}</Button>{events.length > 0 && <span className="text-xs text-gray-500 self-center">Use the event cards below to view published records.</span>}</div><div className="mt-5 space-y-2">{events.map((event) => <div key={event.id} className="flex items-center justify-between rounded border p-3"><span className="text-sm font-medium text-sheraton-navy">{event.title}</span><span className="flex gap-2"><Button size="sm" variant="outline" onClick={() => editManagedEvent(event)}>Edit</Button><Button size="sm" variant="outline" onClick={() => void deleteManagedEvent(event.id)}>Cancel</Button></span></div>)}</div></div>}
    </div>
  );

  const tabs = [
    { id: "browse", label: "Hotel Events", content: renderBrowseEvents },
    { id: "my-tickets", label: "My Tickets", content: renderMyEvents },
    { id: "my-events", label: "My Events", content: renderMyEvents },
    { id: "planning", label: "Event Planning", content: renderPlanning },
  ];

  return <div className="min-h-screen bg-gradient-to-br from-sheraton-cream via-white to-sheraton-pearl"><div className="container mx-auto px-4 py-8"><div className="text-center mb-8"><h1 className="text-4xl font-bold text-sheraton-navy mb-4">Hotel Events & Experiences</h1><p className="text-lg text-gray-600 max-w-2xl mx-auto">Discover upcoming hotel events, create memorable experiences, and connect with fellow guests.</p></div><div className="flex justify-center mb-8"><div className="grid grid-cols-2 gap-1 rounded-lg bg-white p-1 shadow-md md:flex">{tabs.map((tab) => <button key={tab.id} onClick={() => setActiveTab(tab.id)} className={`px-3 py-2 text-sm rounded-md font-medium transition-colors md:px-6 md:py-3 md:text-base ${activeTab === tab.id ? "bg-sheraton-gold text-sheraton-navy shadow-sm" : "text-gray-600 hover:text-sheraton-navy"}`}>{tab.label}</button>)}</div></div><div>{tabs.find((tab) => tab.id === activeTab)?.content()}</div>{getTotalEventItems() > 0 && <div className="fixed bottom-6 right-6 z-50"><div className="bg-sheraton-gold text-sheraton-navy rounded-lg shadow-lg p-4"><div className="flex items-center gap-4"><div className="relative"><Calendar className="h-6 w-6" /><Badge className="absolute -top-2 -right-2 bg-sheraton-navy text-sheraton-gold min-w-[20px] h-5 p-0 flex items-center justify-center text-xs">{getTotalEventItems()}</Badge></div><div><div className="font-semibold">{getTotalEventItems()} {getTotalEventItems() === 1 ? "Event" : "Events"}</div><div className="text-xs opacity-80">Ready to book</div></div><Button size="sm" variant="secondary" className="bg-sheraton-navy text-sheraton-gold hover:bg-sheraton-navy/90" onClick={() => { if (requireAuth()) setShowCheckout(true); }}>Checkout</Button></div></div></div>}<Dialog open={Boolean(shareEventTarget)} onOpenChange={(open) => { if (!open) setShareEventTarget(null); }}><DialogContent className="max-w-md"><DialogHeader><DialogTitle>Share {shareEventTarget?.title}</DialogTitle></DialogHeader>{eventShareUrl && shareEventTarget && <div className="space-y-4"><Input readOnly value={eventShareUrl} aria-label="Event sharing link" /><div className="grid grid-cols-2 gap-2"><Button onClick={() => void copyEventLink()}><Copy className="mr-2 h-4 w-4" />Copy link</Button><a className="inline-flex items-center justify-center rounded-md border px-4 py-2 text-sm font-medium" href={`mailto:?subject=${encodeURIComponent(`Join me at ${shareEventTarget.title}`)}&body=${encodeURIComponent(`Join me at ${shareEventTarget.title}: ${eventShareUrl}`)}`}><Mail className="mr-2 h-4 w-4" />Email</a><a className="inline-flex items-center justify-center rounded-md border px-4 py-2 text-sm font-medium" href={`https://wa.me/?text=${encodeURIComponent(`Join me at ${shareEventTarget.title}: ${eventShareUrl}`)}`} target="_blank" rel="noreferrer">WhatsApp</a><a className="inline-flex items-center justify-center rounded-md border px-4 py-2 text-sm font-medium" href={`https://www.facebook.com/sharer/sharer.php?u=${encodeURIComponent(eventShareUrl)}`} target="_blank" rel="noreferrer">Facebook</a><a className="inline-flex items-center justify-center rounded-md border px-4 py-2 text-sm font-medium" href={`https://www.linkedin.com/sharing/share-offsite/?url=${encodeURIComponent(eventShareUrl)}`} target="_blank" rel="noreferrer">LinkedIn</a><a className="inline-flex items-center justify-center rounded-md border px-4 py-2 text-sm font-medium" href={`https://twitter.com/intent/tweet?text=${encodeURIComponent(`Join me at ${shareEventTarget.title}`)}&url=${encodeURIComponent(eventShareUrl)}`} target="_blank" rel="noreferrer">X</a>{typeof navigator !== "undefined" && navigator.share && <Button variant="outline" onClick={() => void shareWithDevice()}><Share2 className="mr-2 h-4 w-4" />More options</Button>}</div></div>}</DialogContent></Dialog><EventCheckoutModal isOpen={showCheckout} onClose={() => setShowCheckout(false)} cart={eventCart} events={[...events, ...linkedEvents, ...bookedEvents, ...(sharedEvent ? [sharedEvent] : [])]} onUpdateCart={updateEventCart} onRemoveFromCart={removeFromEventCart} onClearCart={clearEventCart} invitationId={activeInvitationBookingId} onBooked={() => void handleBooked()} /></div></div>;
};

export default EventsPage;
