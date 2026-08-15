import { ArrowRight, Images } from "lucide-react";
import { useState } from "react";

interface LoginViewProps {
  error?: string;
  onLogin: () => Promise<void>;
}

/** Render the single-action Google sign-in experience for the Progress client. */
export function LoginView({ error, onLogin }: LoginViewProps) {
  const [starting, setStarting] = useState(false);

  /** Start the redirect flow while preventing duplicate button presses. */
  async function handleLogin(): Promise<void> {
    setStarting(true);
    try {
      await onLogin();
    } finally {
      setStarting(false);
    }
  }

  return (
    <main className="login-page">
      <div className="login-glow login-glow--one" />
      <div className="login-glow login-glow--two" />
      <section className="login-card" aria-labelledby="login-title">
        <div className="brand-mark brand-mark--large" aria-hidden="true">
          <Images size={30} strokeWidth={1.8} />
        </div>
        <span className="login-card__brand">Pulse</span>
        <h1 id="login-title">Your progress, in perspective.</h1>
        <p>
          A private visual timeline for the photos that show what daily effort can’t.
        </p>
        {error ? <div className="login-error" role="alert">{error}</div> : null}
        <button
          className="google-button"
          type="button"
          disabled={starting}
          onClick={() => void handleLogin()}
        >
          <span className="google-g" aria-hidden="true">G</span>
          <span>{starting ? "Opening Google…" : "Continue with Google"}</span>
          <ArrowRight aria-hidden="true" size={18} />
        </button>
        <small>Only your allowlisted Google account can access Pulse.</small>
      </section>
    </main>
  );
}
