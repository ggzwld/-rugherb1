import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import { supabase } from "./supabase";

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
      const { data, error } = await supabase.rpc("resolve_hotel_tenant", {
        target_hostname: window.location.hostname.toLowerCase(),
      });
      if (!active) return;
      if (error || !data) {
        setState({ tenant: null, loading: false, error: error?.message || "This hotel domain is not configured." });
        return;
      }
      setState({ tenant: data as HotelTenant, loading: false, error: null });
    };

    void resolveTenant();
    return () => {
      active = false;
    };
  }, []);

  return <HotelTenantContext.Provider value={state}>{children}</HotelTenantContext.Provider>;
}

export function useHotelTenant() {
  return useContext(HotelTenantContext);
}
