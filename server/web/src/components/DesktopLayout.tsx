import type { ReactNode } from "react";

interface DesktopLayoutProps {
  sidebar: ReactNode;
  center: ReactNode;
  tray: ReactNode;
}

/** Render the desktop three-column composition: history, browse, and a persistent compare tray. */
export function DesktopLayout({ sidebar, center, tray }: DesktopLayoutProps) {
  return (
    <div className="desktop-layout">
      <aside className="desktop-layout__sidebar">{sidebar}</aside>
      <div className="desktop-layout__center">{center}</div>
      <aside className="desktop-layout__tray">{tray}</aside>
    </div>
  );
}
