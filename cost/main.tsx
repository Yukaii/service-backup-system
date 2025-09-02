import React from "react";
import { createRoot } from "react-dom/client";
import S3CostEstimator from "./index";
import "./index.css";

const container = document.getElementById("root");
if (!container) {
  throw new Error("Missing #root element");
}

const root = createRoot(container);
root.render(
  <React.StrictMode>
    <S3CostEstimator />
  </React.StrictMode>
);
