import { Images, LogOut } from "lucide-react";
import type { ReactNode } from "react";

import type { Identity } from "../types";
import { SegmentedControl, type ProgressView } from "./SegmentedControl";

interface AppShellProps {
  identity: Identity;
  view: ProgressView;
  onViewChange: (view: ProgressView) => void;
  onLogout: () => void;
  children: ReactNode;
}

/** Render the signed-in Pulse shell around the selected Progress experience. */
export function AppShell({
  identity,
  view,
  onViewChange,
  onLogout,
  children,
}: AppShellProps) {
  return (
    <div className="app-shell">
      <header className="topbar">
        <a className="brand" href="/" aria-label="Pulse Progress home">
          <span className="brand-mark" aria-hidden="true">
            <Images size={19} strokeWidth={2} />
          </span>
          <span>Pulse</span>
        </a>
        <div className="account">
          <span>{identity.email}</span>
          <button type="button" aria-label="Sign out" onClick={onLogout}>
            <LogOut aria-hidden="true" size={18} />
          </button>
        </div>
      </header>

      <main className="page-shell">
        <section className="hero" aria-labelledby="page-title">
          <div>
            <span className="eyebrow">Progress photos</span>
            <h1 id="page-title">Progress, made visible.</h1>
            <p>Step back from the day-to-day. See the change that only time reveals.</p>
          </div>
          <div className="hero-orbit" aria-hidden="true">
            <span />
            <span />
          </div>
        </section>

        <div className="view-switcher">
          <SegmentedControl value={view} onChange={onViewChange} />
        </div>
        {children}
      </main>

      <footer className="footer">Private by design · Read-only on web</footer>
    </div>
  );
}
