import express from "express";
import cors from "cors";
import { handleDemo } from "./routes/demo.js";
import {
  cancelFlutterwavePayment,
  createFlutterwaveHostedSession,
  handleFlutterwaveWebhook,
  verifyFlutterwavePayment,
} from "./routes/flutterwave.js";
import {
  cancelSpecialEventPayment,
  confirmFreeSpecialEventBooking,
  createSpecialEventBooking,
  handleSpecialEventWebhook,
  prepareSpecialEventPayment,
  verifySpecialEventPayment,
} from "./routes/specialEvents.js";
import {
  cancelHotelBookingHold,
  cancelHotelBookingPayment,
  createHotelBooking,
  createHotelPaymentSession,
  getExchangeRates,
  handleHotelBookingWebhook,
  recoverHotelBooking,
  verifyHotelBookingPayment,
} from "./routes/hotelBookings.js";
import { createMenuOrder } from "./routes/menuOrders.js";
import {
  getHotelTenant,
  getPublicHotelBookingData,
  submitHotelComplaint,
  getPublicMenuItems,
  getPublicSpecialEvents,
  getTenantRoomAvailability,
  publishHotelEventProposal,
  respondHotelEventProposal,
  reviewHotelEventProposal,
  submitHotelEventProposal,
} from "./routes/hotelTenant.js";

export function createServer() {
  const app = express();

  // Middleware
  app.use(cors());
  app.use(express.json());
  app.use(express.urlencoded({ extended: true }));

  // Example API routes
  app.get("/api/ping", (_req, res) => {
    res.json({ message: "Hello from Express server v2!" });
  });

  app.get("/api/demo", handleDemo);
  app.get("/api/hotel-tenant", getHotelTenant);
  app.post("/api/hotel-complaints", submitHotelComplaint);
  app.get("/api/hotel-booking-data", getPublicHotelBookingData);
  app.get("/api/hotel-menu-items", getPublicMenuItems);
  app.get("/api/hotel-events", getPublicSpecialEvents);
  app.post("/api/hotel-event-proposals/submit", submitHotelEventProposal);
  app.post("/api/hotel-event-proposals/review", reviewHotelEventProposal);
  app.post("/api/hotel-event-proposals/respond", respondHotelEventProposal);
  app.post("/api/hotel-event-proposals/publish", publishHotelEventProposal);
  app.post("/api/hotel-availability", getTenantRoomAvailability);
  app.post("/api/special-events/bookings/create", createSpecialEventBooking);
  app.post("/api/special-events/bookings/confirm-free", confirmFreeSpecialEventBooking);
  app.post("/api/payments/flutterwave/hosted-session", createFlutterwaveHostedSession);
  app.post("/api/payments/flutterwave/cancel", cancelFlutterwavePayment);
  app.post("/api/payments/flutterwave/verify", verifyFlutterwavePayment);
  app.post("/api/payments/flutterwave/webhook", handleFlutterwaveWebhook);
  app.post("/api/payments/special-events/session", prepareSpecialEventPayment);
  app.post("/api/payments/special-events/verify", verifySpecialEventPayment);
  app.post("/api/payments/special-events/cancel", cancelSpecialEventPayment);
  app.post("/api/payments/special-events/webhook", handleSpecialEventWebhook);
  app.post("/api/menu-orders/create", createMenuOrder);
  app.post("/api/hotel-bookings/create", createHotelBooking);
  app.post("/api/hotel-bookings/recover", recoverHotelBooking);
  app.post("/api/hotel-bookings/cancel-hold", cancelHotelBookingHold);
  app.post("/api/payments/hotel/session", createHotelPaymentSession);
  app.post("/api/payments/hotel/verify", verifyHotelBookingPayment);
  app.post("/api/payments/hotel/cancel", cancelHotelBookingPayment);
  app.post("/api/payments/hotel/webhook", handleHotelBookingWebhook);
  app.get("/api/books/fx-rates", getExchangeRates);

  return app;
}
