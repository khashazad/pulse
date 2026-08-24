import { useEffect, useState } from "react";

const DESKTOP_QUERY = "(min-width: 900px)";

/** Track the desktop three-column breakpoint that also gates persistent Compare. */
export function useIsDesktop(): boolean {
  const [isDesktop, setIsDesktop] = useState(
    () => typeof window !== "undefined" && window.matchMedia(DESKTOP_QUERY).matches,
  );

  useEffect(() => {
    const media = window.matchMedia(DESKTOP_QUERY);
    const listener = (event: MediaQueryListEvent) => setIsDesktop(event.matches);
    media.addEventListener("change", listener);
    setIsDesktop(media.matches);
    return () => media.removeEventListener("change", listener);
  }, []);

  return isDesktop;
}
