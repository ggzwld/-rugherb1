import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { createContext, ReactNode, useContext, useEffect, useState } from "react";

export type HotelTenant = {
  organizationId: string;
  name: string;
  logoUrl: string | null;
  primaryColor: string;
  accentColor: string;
};

type HotelTenantState = {
  tenant: HotelTenant | null;
  loading: boolean;
  error: string | null;
};

const HotelTenantContext = createContext<HotelTenantState>({ tenant: null, loading: true, error: null });

export function HotelTenantProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<HotelTenantState>({ tenant: null, loading: true, error: null });

  useEffect(() => {
    let active = true;
    const resolveTenant = async () => {
      const response = await fetch("/api/hotel-tenant");
      const payload = await response.json().catch(() => null) as HotelTenant | { error?: string } | null;
      if (!active) return;
      if (!response.ok || !payload || !("organizationId" in payload)) {
        setState({ tenant: null, loading: false, error: payload && "error" in payload ? payload.error || "This hotel domain is not configured." : "This hotel domain is not configured." });
        return;
      }
      setState({ tenant: payload, loading: false, error: null });
    };

    void resolveTenant();
    return () => {
      active = false;
    };
  }, []);

  useEffect(() => {
    if (!state.tenant) return;
    const primaryColor = hexToHsl(state.tenant.primaryColor);
    const accentColor = hexToHsl(state.tenant.accentColor);
    if (primaryColor) {
      document.documentElement.style.setProperty("--primary", primaryColor);
      document.documentElement.style.setProperty("--ring", primaryColor);
      document.documentElement.style.setProperty("--sheraton-navy", primaryColor);
      document.documentElement.style.setProperty("--sheraton-navy-light", primaryColor);
    }
    if (accentColor) {
      document.documentElement.style.setProperty("--sheraton-gold", accentColor);
      document.documentElement.style.setProperty("--sheraton-gold-light", accentColor);
      document.documentElement.style.setProperty("--sheraton-gold-dark", accentColor);
    }
  }, [state.tenant]);

  return <HotelTenantContext.Provider value={state}>{children}</HotelTenantContext.Provider>;
}

const hexToHsl = (hex: string) => {
  const normalized = hex.replace("#", "");
  if (!/^[0-9a-f]{6}$/i.test(normalized)) return null;
  const [red, green, blue] = [0, 2, 4].map((index) => parseInt(normalized.slice(index, index + 2), 16) / 255);
  const maximum = Math.max(red, green, blue);
  const minimum = Math.min(red, green, blue);
  const lightness = (maximum + minimum) / 2;
  const delta = maximum - minimum;
  const saturation = delta === 0 ? 0 : delta / (1 - Math.abs(2 * lightness - 1));
  const hue = delta === 0 ? 0 : maximum === red ? 60 * (((green - blue) / delta) % 6) : maximum === green ? 60 * ((blue - red) / delta + 2) : 60 * ((red - green) / delta + 4);
  return `${Math.round((hue + 360) % 360)} ${Math.round(saturation * 100)}% ${Math.round(lightness * 100)}%`;
};

export function useHotelTenant() {
  return useContext(HotelTenantContext);
}
