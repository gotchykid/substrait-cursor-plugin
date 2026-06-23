import { useEffect, useState } from "react";

// Always call the backend same-origin via relative /api paths. In production the
// ingress routes /api to the backend; in local dev the Vite proxy (vite.config.js)
// forwards /api to the backend on :8000. Never hardcode an absolute API URL.

export default function App() {
  const [message, setMessage] = useState("loading…");

  useEffect(() => {
    fetch("/api/hello")
      .then((r) => r.json())
      .then((d) => setMessage(d.message))
      .catch(() => setMessage("could not reach the backend"));
  }, []);

  return (
    <main className="flex min-h-screen items-center justify-center bg-slate-50">
      <div className="rounded-2xl bg-white p-8 shadow-sm ring-1 ring-slate-200">
        <h1 className="text-2xl font-semibold text-slate-900">My Substrait app</h1>
        <p className="mt-2 text-slate-600">{message}</p>
      </div>
    </main>
  );
}
