export type SpecialEventStatus = "draft" | "published" | "cancelled" | "completed";
export type SpecialEventBookingStatus = "pending" | "confirmed" | "cancelled" | "refunded" | "manual_review" | "expired";
export type SpecialEventPaymentStatus = "pending" | "paid" | "failed" | "cancelled" | "refunded" | "partially_refunded" | "chargeback" | "expired" | "manual_review";

export interface SpecialEventTicket {
  id: string;
  booking_id: string;
  event_id: string;
  ticket_number: number;
  ticket_token: string;
  attendee_name: string;
  attendee_email: string;
  status: "valid" | "checked_in" | "void" | "refunded";
  checked_in_at: string | null;
}

export interface SpecialEvent {
  id: string;
  title: string;
  description: string | null;
  starts_at: string;
  ends_at: string;
  timezone: string;
  location: string;
  facility_id?: string | null;
  organization_id?: string | null;
  is_private?: boolean;
  source_plan_id?: string | null;
  share_token?: string | null;
  invitation_id?: string | null;
  price: number;
  currency: string;
  capacity: number;
  ticket_type_capacity: number | null;
  max_tickets_per_order: number;
  default_ticket_type_id: string;
  attendees_count: number;
  category: string | null;
  image_url: string | null;
  featured: boolean;
  rating: number;
  host_name: string | null;
  status: SpecialEventStatus;
  organizer_id: string;
  created_by: string;
  created_at: string;
  updated_at: string;
}

export interface SpecialEventBooking {
  id: string;
  event_id: string;
  order_number: string;
  guest_first_name: string;
  guest_last_name: string;
  guest_email: string;
  guest_phone: string | null;
  special_requests: string | null;
  quantity: number;
  subtotal: number;
  service_fee: number;
  tax_amount: number;
  discount_amount: number;
  total_amount: number;
  currency: string;
  status: SpecialEventBookingStatus;
  payment_status: SpecialEventPaymentStatus;
  confirmation_number: string;
  ticket_code: string | null;
  expires_at: string | null;
  created_at: string;
  updated_at: string;
  event?: SpecialEvent;
}

export interface SpecialEventPlan {
  id: string;
  user_id: string;
  title: string;
  event_date: string;
  location: string;
  facility_id: string | null;
  category: string;
  starts_at: string | null;
  ends_at: string | null;
  timezone: string;
  expected_guests: number;
  entry_type: "free" | "paid";
  entry_fee: number;
  entry_currency: string;
  description: string | null;
  image_url: string | null;
  is_private: boolean;
  contact_name: string | null;
  contact_email: string | null;
  contact_phone: string | null;
  share_manager_operations: boolean;
  manager_note: string | null;
  suggested_title: string | null;
  suggested_description: string | null;
  suggested_category: string | null;
  suggested_starts_at: string | null;
  suggested_ends_at: string | null;
  suggested_facility_id: string | null;
  suggested_expected_guests: number | null;
  reviewed_by: string | null;
  reviewed_at: string | null;
  published_at: string | null;
  special_event_id: string | null;
  share_token: string;
  status: "draft" | "submitted" | "changes_requested" | "scheduled" | "declined" | "cancelled";
  created_at: string;
  updated_at: string;
}

export interface SpecialEventInvitationSummary {
  id: string;
  event_id: string;
  invitee_email: string;
  invitation_status: "pending" | "accepted" | "declined" | "revoked";
  event: SpecialEvent;
}

export const formatEventDate = (startsAt: string, timezone: string) => {
  try {
    return new Intl.DateTimeFormat(undefined, {
      dateStyle: "medium",
      timeStyle: "short",
      timeZone: timezone,
    }).format(new Date(startsAt));
  } catch {
    return new Intl.DateTimeFormat(undefined, {
      dateStyle: "medium",
      timeStyle: "short",
    }).format(new Date(startsAt));
  }
};

export const formatEventDay = (startsAt: string, timezone: string) => {
  try {
    return new Intl.DateTimeFormat(undefined, {
      dateStyle: "medium",
      timeZone: timezone,
    }).format(new Date(startsAt));
  } catch {
    return new Intl.DateTimeFormat(undefined, { dateStyle: "medium" }).format(new Date(startsAt));
  }
};
