import { useEffect, useState } from "react";

import { useAuthorizedImage } from "../../hooks/useAuthorizedImage";

interface CalendarDayThumbProps {
  token: string;
  photoId: string;
  enabled: boolean;
}

/** Lazy-load one authorized thumbnail for a populated calendar cell. */
export function CalendarDayThumb({ token, photoId, enabled }: CalendarDayThumbProps) {
  const [active, setActive] = useState(false);
  const image = useAuthorizedImage(token, photoId, "thumb");

  useEffect(() => {
    if (!enabled) return;
    const timer = window.setTimeout(() => setActive(true), 40);
    return () => window.clearTimeout(timer);
  }, [enabled]);

  if (!active || !image.url) return null;
  return <img className="calendar-day__thumb" src={image.url} alt="" aria-hidden="true" />;
}
