// Central place to set the demo's name + description. Rename this when you
// spin up a new repo from the template and the navbar, footer, and document
// title all update together.
export const SITE = {
  name: "Vision Template",
  description: "Vision Template test.",
} as const;

// Top navigation links. Add routes in app/routes.ts and list them here.
export const NAV_LINKS: { href: string; label: string }[] = [
  { href: "/db-demo", label: "DB Demo" },
  { href: "/api-demo", label: "API Demo" },
];
