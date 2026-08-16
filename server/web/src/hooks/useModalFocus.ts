import type { RefObject } from "react";
import { useEffect, useRef } from "react";

interface UseModalFocusOptions {
  /** Whether the modal is currently open. */
  open: boolean;
  /** Called when the user presses Escape. */
  onClose: () => void;
  /** Element that opened the modal and should regain focus on close. */
  restoreFocusTo?: HTMLElement | null;
}

/** Lock page scroll, trap Tab, and restore focus for modal dialogs. */
export function useModalFocus({
  open,
  onClose,
  restoreFocusTo,
}: UseModalFocusOptions): RefObject<HTMLDivElement | null> {
  const dialogRef = useRef<HTMLDivElement>(null);
  const initialFocusRef = useRef<HTMLElement | null>(null);

  useEffect(() => {
    if (!open) return;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    initialFocusRef.current = dialogRef.current?.querySelector<HTMLElement>(
      "[data-autofocus], button:not([disabled])",
    ) ?? dialogRef.current;
    initialFocusRef.current?.focus();

    /** Handle Escape and keep keyboard focus inside the dialog. */
    function handleKeyDown(event: KeyboardEvent): void {
      if (event.key === "Escape") {
        event.preventDefault();
        onClose();
        return;
      }
      if (event.key !== "Tab") return;
      const controls = dialogRef.current?.querySelectorAll<HTMLElement>(
        'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
      );
      if (!controls?.length) return;
      const first = controls[0];
      const last = controls[controls.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }

    window.addEventListener("keydown", handleKeyDown);
    return () => {
      document.body.style.overflow = previousOverflow;
      window.removeEventListener("keydown", handleKeyDown);
      restoreFocusTo?.focus();
    };
  }, [open, onClose, restoreFocusTo]);

  return dialogRef;
}
