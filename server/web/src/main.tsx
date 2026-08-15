import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { App } from "./App";
import "./styles/tokens.css";
import "./styles/global.css";
import "./styles/components.css";

const root = document.getElementById("root");
if (!root) throw new Error("Pulse root element is missing");

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
