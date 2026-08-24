import type { ReactNode } from "react";

interface DesktopLayoutProps {
  sidebar: ReactNode;
  center: ReactNode;
}

/** Render the desktop Browse composition: a sticky history sidebar beside the feed. */
export function DesktopLayout({ sidebar, center }: DesktopLayoutProps) {
  return (
    <div className="desktop-layout">
      <aside className="desktop-layout__sidebar">{sidebar}</aside>
      <div className="desktop-layout__center">{center}</div>
    </div>
  );
}
