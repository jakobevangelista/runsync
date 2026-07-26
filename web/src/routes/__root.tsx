import { HeadContent, Scripts, createRootRoute } from "@tanstack/react-router";

import appCss from "../styles.css?url";

const themeScript = `
(() => {
  try {
    const saved = localStorage.getItem("runsync-theme");
    const dark = saved === "dark" ||
      (saved === null && matchMedia("(prefers-color-scheme: dark)").matches);
    document.documentElement.classList.toggle("dark", dark);
    document.documentElement.style.colorScheme = dark ? "dark" : "light";
    document.querySelector('meta[name="theme-color"]')
      ?.setAttribute("content", dark ? "#1c1916" : "#f7f3eb");
  } catch {}
})();
`;

export const Route = createRootRoute({
  head: () => ({
    meta: [
      {
        charSet: "utf-8",
      },
      {
        name: "viewport",
        content: "width=device-width, initial-scale=1",
      },
      {
        title: "RunSync Live",
      },
      {
        name: "description",
        content: "Follow a live run and see the completed route and metrics in one shared link.",
      },
      {
        name: "theme-color",
        content: "#f7f3eb",
      },
      {
        name: "referrer",
        content: "strict-origin-when-cross-origin",
      },
    ],
    links: [
      {
        rel: "stylesheet",
        href: appCss,
      },
    ],
  }),
  shellComponent: RootDocument,
  notFoundComponent: NotFound,
});

function RootDocument({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <HeadContent />
        <script dangerouslySetInnerHTML={{ __html: themeScript }} />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  );
}

function NotFound() {
  return <main className="not-found">Not found</main>;
}
