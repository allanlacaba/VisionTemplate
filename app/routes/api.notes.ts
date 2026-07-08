import type { Route } from "./+types/api.notes";
import { createNote, listNotes } from "../lib/db.server";
import { checkRateLimit, getClientIp } from "../lib/rate-limit.server";

// GET /api/notes — list all notes as JSON
export async function loader(_: Route.LoaderArgs) {
  const notes = await listNotes();
  return Response.json({ notes });
}

// POST /api/notes — create a note ({ title, content })
export async function action({ request }: Route.ActionArgs) {
  if (request.method !== "POST") {
    return Response.json({ error: "Method not allowed" }, { status: 405 });
  }
  const body = await request.json();
  if (!body?.title || typeof body.title !== "string") {
    return Response.json({ error: "title is required" }, { status: 400 });
  }

  // Rate limit after cheap validation so malformed requests don't consume the
  // IP's budget (important for the shared "unknown" bucket). 20 / hour / IP.
  const ip = getClientIp(request);
  const rl = checkRateLimit(ip, { limit: 20, windowMs: 60 * 60 * 1000 });
  if (!rl.allowed) {
    return Response.json(
      { error: "Rate limit exceeded. Try again later." },
      { status: 429, headers: { "Retry-After": String(rl.retryAfterSec) } },
    );
  }

  const note = await createNote(body.title, body.content ?? "");
  return Response.json({ note }, { status: 201 });
}
