import { CalendarDays, LogOut } from "lucide-react";
import type { ReactNode } from "react";

import type { Identity } from "../types";

interface AppShellProps {
  identity: Identity;
  onOpenCalendar: () => void;
  onLogout: () => void;
  children: ReactNode;
}

/** Derive one uppercase initial from an email address for compact account display. */
function emailInitial(email: string): string {
  return email.trim().charAt(0).toUpperCase() || "?";
}

/** Render the signed-in Pulse shell: a minimal top bar plus routed content. */
export function AppShell({ identity, onOpenCalendar, onLogout, children }: AppShellProps) {
  return (
    <div className="app-shell">
      <header className="topbar">
        <a className="brand" href="/" aria-label="Pulse Progress home">
          <span className="brand-mark" aria-hidden="true">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round">
              <rect x="3" y="3" width="7" height="7" rx="1.5" />
              <rect x="14" y="3" width="7" height="7" rx="1.5" />
              <rect x="3" y="14" width="7" height="7" rx="1.5" />
              <rect x="14" y="14" width="7" height="7" rx="1.5" />
            </svg>
          </span>
          <span className="brand-word">Pulse</span>
        </a>

        <div className="account">
          <button
            type="button"
            className="icon-button"
            aria-label="Open photo calendar"
            onClick={onOpenCalendar}
          >
            <CalendarDays aria-hidden="true" size={18} />
          </button>
          <span className="account__email" title={identity.email}>
            {identity.email}
          </span>
          <span className="account__avatar" aria-hidden="true">
            {emailInitial(identity.email)}
          </span>
          <button type="button" className="icon-button" aria-label="Sign out" onClick={onLogout}>
            <LogOut aria-hidden="true" size={18} />
          </button>
        </div>
      </header>

      <main className="page-shell">{children}</main>
    </div>
  );
}
