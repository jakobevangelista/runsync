import { useEffect } from "react";
import { Moon, Sun } from "lucide-react";

import { Button } from "./ui/button";

const STORAGE_KEY = "runsync-theme";

export function ThemeToggle() {
  useEffect(() => {
    const preference = window.matchMedia?.("(prefers-color-scheme: dark)");
    if (!preference) return;
    const followSystem = (event: MediaQueryListEvent) => {
      if (window.localStorage.getItem(STORAGE_KEY) === null) {
        applyTheme(event.matches);
      }
    };
    preference.addEventListener("change", followSystem);
    return () => preference.removeEventListener("change", followSystem);
  }, []);

  return (
    <Button
      type="button"
      variant="ghost"
      size="icon-sm"
      className="text-muted-foreground"
      aria-label="Toggle color theme"
      title="Toggle color theme"
      onClick={() => {
        const dark = !document.documentElement.classList.contains("dark");
        window.localStorage.setItem(STORAGE_KEY, dark ? "dark" : "light");
        applyTheme(dark);
      }}
    >
      <Moon className="dark:hidden" />
      <Sun className="hidden dark:block" />
      <span className="sr-only">Toggle color theme</span>
    </Button>
  );
}

function applyTheme(dark: boolean) {
  document.documentElement.classList.toggle("dark", dark);
  document.documentElement.style.colorScheme = dark ? "dark" : "light";
  document
    .querySelector('meta[name="theme-color"]')
    ?.setAttribute("content", dark ? "#1c1916" : "#f7f3eb");
}
