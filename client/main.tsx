import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import { HotelTenantProvider } from "./lib/hotelTenant";
import "./global.css";

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <HotelTenantProvider>
      <App />
    </HotelTenantProvider>
  </React.StrictMode>,
);
