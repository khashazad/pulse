import { CalendarDays, Images, LogOut } from "lucide-react";
import type { ReactNode } from "react";

import type { Identity } from "../types";
import { SegmentedControl, type ProgressView } from "./SegmentedControl";

interface AppShellProps {
  identity: Identity;
  view: ProgressView;
  onViewChange: (view: ProgressView) => void;
  onOpenCalendar: () => void;
  onLogout: () => void;
  children: ReactNode;
}

/** Derive one uppercase initial from an email address for compact account display. */
function emailInitial(email: string): string {
  return email.trim().charAt(0).toUpperCase() || "?";
}

/** Render the signed-in Pulse shell with top-bar navigation only. */
export function AppShell({
  identity,
  view,
  onViewChange,
  onOpenCalendar,
  onLogout,
  children,
}: AppShellProps) {
  return (
    <div className="app-shell">
      <header className="topbar">
        <a className="brand" href="/" aria-label="Pulse Progress home">
          <span className="brand-mark" aria-hidden="true">
            <Images size={18} strokeWidth={2} />
          </span>
          <span className="brand-word">Pulse</span>
        </a>

        <div className="topbar__center">
          <SegmentedControl value={view} onChange={onViewChange} />
        </div>

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

      <footer className="footer">Private · Read-only</footer>
    </div>
  );
}
