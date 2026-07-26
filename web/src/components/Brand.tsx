import { Route } from "lucide-react";

import { cn } from "@/lib/utils";

export function Brand({
  className,
  markClassName,
}: {
  className?: string;
  markClassName?: string;
}) {
  return (
    <a
      className={cn(
        "inline-flex items-center gap-2.5 text-foreground no-underline transition-opacity hover:opacity-75",
        className,
      )}
      href="/"
      aria-label="RunSync home"
    >
      <span
        className={cn(
          "grid size-9 place-items-center rounded-xl bg-foreground text-background shadow-sm",
          markClassName,
        )}
        aria-hidden="true"
      >
        <Route className="size-4.5" strokeWidth={2.25} />
      </span>
      <strong className="text-[15px] font-semibold tracking-[-0.02em]">RunSync</strong>
    </a>
  );
}
