import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createHotelBooking } from "./hotelBookings";

const idempotencyKey = "f4d77e69-3a94-4c6f-b311-3c832206c0fd";
const accessToken = "a".repeat(48);
const userId = "bd15af7a-93a0-4618-bd1f-4dc72c7f88c6";
const organizationId = "cd4d5b85-0559-4ee0-8fcf-c2b3454d0811";

const jsonResponse = (body: unknown) => new Response(JSON.stringify(body), { status: 200 });

describe("createHotelBooking", () => {
  beforeEach(() => {
    vi.stubEnv("VITE_SUPABASE_URL", "https://supabase.example.test");
    vi.stubEnv("VITE_SUPABASE_ANON_KEY", "anon-key");
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "service-role-key");
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  it("replays an authenticated booking without fetching exchange rates", async () => {
    const fetchMock = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      const url = String(input);
      if (url.endsWith("/rpc/resolve_hotel_tenant")) return jsonResponse([{
        organization_id: organizationId,
        name: "Sheraspace",
        logo_url: null,
        primary_color: null,
        accent_color: null,
      }]);
      if (url.endsWith("/auth/v1/user")) return jsonResponse({ id: userId });
      if (url.includes("hotel_bookings?idempotency_key=")) {
        return jsonResponse([{
          organization_id: organizationId,
          user_id: userId,
          access_token_hash: createHash("sha256").update(accessToken).digest("hex"),
          fx_rates_snapshot: { as_of: "2026-09-30T00:00:00.000Z" },
        }]);
      }
      if (url.endsWith("/rpc/create_hotel_booking_for_tenant")) {
        expect(JSON.parse(String(init?.body)).target_organization_id).toBe(organizationId);
        expect(JSON.parse(String(init?.body)).target_fx_rates).toBeNull();
        return jsonResponse([{
          booking_id: "d536669f-7c9c-4885-a438-71ba7723f5e9",
          confirmation_number: "ST-1234567890",
          currency_code: "TZS",
          nights: 2,
          nightly_subtotal: 20000,
          discount_amount: 0,
          taxable_subtotal: 20000,
          vat_amount: 3600,
          lht_amount: 3000,
          total_amount: 26600,
          hotel_classification: 3,
          expires_at: "2026-09-30T00:20:00.000Z",
        }]);
      }
      throw new Error(`Unexpected request: ${url}`);
    });
    vi.stubGlobal("fetch", fetchMock);

    const result = { statusCode: 200, body: null as unknown };
    const response = {
      status(code: number) {
        result.statusCode = code;
        return this;
      },
      json(body: unknown) {
        result.body = body;
        return this;
      },
    };

    await createHotelBooking({
      headers: { authorization: "Bearer user-token", host: "sheraspace.example.test" },
      hostname: "sheraspace.example.test",
      body: {
        roomId: "e1600390-b355-4ca4-ae0a-5e18dd449f6f",
        guest: { firstName: "Test", lastName: "Guest", email: "guest@example.com", phone: "+256700000000" },
        checkIn: "2020-10-01",
        checkOut: "2020-10-03",
        guestCount: 1,
        roomCount: 1,
        preferences: [],
        idempotencyKey,
        accessToken,
      },
      ip: "192.0.2.10",
    } as Parameters<typeof createHotelBooking>[0], response as Parameters<typeof createHotelBooking>[1], (() => undefined) as Parameters<typeof createHotelBooking>[2]);

    expect(result.statusCode).toBe(200);
    expect(result.body).toMatchObject({ booking_id: "d536669f-7c9c-4885-a438-71ba7723f5e9", fxAsOf: "2026-09-30T00:00:00.000Z" });
    expect(fetchMock).toHaveBeenCalledTimes(4);
    expect(fetchMock.mock.calls.some(([input]) => String(input).includes("open.er-api.com"))).toBe(false);
  });
});
