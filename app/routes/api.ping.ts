import type { Route } from "./+types/api.ping";

// GET /api/ping — health check, proves the backend is answering
export async function loader(_: Route.LoaderArgs) {
  return Response.json({
    pong: true,
    serverTime: new Date().toISOString(),
    uptimeSeconds: Math.round(process.uptime()),
  });
}

// POST /api/ping — echoes back whatever { message } you send
export async function action({ request }: Route.ActionArgs) {
  const body = await request.json().catch(() => ({}));
  return Response.json({
    pong: true,
    echo: body?.message ?? null,
    serverTime: new Date().toISOString(),
  });
}
