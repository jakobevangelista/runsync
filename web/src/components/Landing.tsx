import { ArrowRight, ExternalLink, HeartPulse, MapPinned, Radio, Timer } from "lucide-react";

import { Brand } from "./Brand";
import { ThemeToggle } from "./ThemeToggle";
import { Badge } from "./ui/badge";
import { buttonVariants } from "./ui/button";
import { Card, CardContent } from "./ui/card";

export function Landing({ shareId, studioId }: { shareId: string; studioId: string }) {
  const shareHref = `/share/${encodeURIComponent(shareId)}`;
  const studioHref = `/studio/${encodeURIComponent(studioId)}`;
  return (
    <main className="min-h-svh overflow-hidden bg-background text-foreground">
      <div className="pointer-events-none fixed inset-x-0 top-0 h-[28rem] bg-[radial-gradient(circle_at_70%_-10%,color-mix(in_oklch,var(--primary)_18%,transparent),transparent_62%)]" />
      <div className="relative mx-auto flex min-h-svh w-full max-w-7xl flex-col px-5 sm:px-8 lg:px-12">
        <header className="flex h-20 items-center justify-between border-b border-border/70">
          <Brand />
          <div className="flex items-center gap-1">
            <ThemeToggle />
            <a
              className={buttonVariants({
                variant: "ghost",
                size: "sm",
                className: "text-muted-foreground",
              })}
              href={studioHref}
            >
              Broadcast tools
              <ExternalLink data-icon="inline-end" />
            </a>
          </div>
        </header>

        <section className="grid flex-1 items-center gap-14 py-16 lg:grid-cols-[minmax(0,1.02fr)_minmax(420px,0.98fr)] lg:py-20">
          <div className="max-w-2xl">
            <Badge
              className="mb-7 gap-2 border-primary/20 bg-primary/8 text-primary"
              variant="outline"
            >
              <Radio className="size-3.5" />
              Live run tracking
            </Badge>
            <h1 className="max-w-[12ch] text-5xl leading-[0.94] font-semibold tracking-[-0.065em] text-balance sm:text-7xl lg:text-[5.4rem]">
              Every mile, shared in real time.
            </h1>
            <p className="mt-7 max-w-xl text-base leading-7 text-muted-foreground sm:text-lg">
              Follow the current route, pace, heart rate, and distance—then come back to the same
              link for the completed run.
            </p>
            <div className="mt-9 flex flex-col items-start gap-4 sm:flex-row sm:items-center">
              <a
                className={buttonVariants({
                  size: "lg",
                  className:
                    "h-12 min-w-56 justify-between rounded-xl px-5 shadow-[0_12px_32px_color-mix(in_oklch,var(--primary)_22%,transparent)]",
                })}
                href={shareHref}
              >
                View the current run
                <ArrowRight data-icon="inline-end" />
              </a>
              <span className="text-xs leading-5 text-muted-foreground">
                No account needed.
                <br />
                Anyone with the link can view.
              </span>
            </div>
          </div>

          <Card className="relative min-h-[31rem] overflow-hidden border-foreground/10 bg-card/95 py-0 shadow-[0_32px_90px_rgb(38_30_20/12%)]">
            <div className="absolute inset-0 landing-map-grid" aria-hidden="true" />
            <div
              className="pointer-events-none absolute -top-24 -right-24 size-72 rounded-full bg-primary/12 blur-3xl"
              aria-hidden="true"
            />
            <CardContent className="relative flex min-h-[31rem] flex-col justify-between p-6 sm:p-8">
              <div className="flex items-start justify-between gap-4">
                <div>
                  <p className="text-xs font-medium tracking-[0.12em] text-muted-foreground uppercase">
                    One link
                  </p>
                  <p className="mt-1 text-lg font-semibold tracking-[-0.025em]">
                    The whole run, live.
                  </p>
                </div>
                <Badge className="border-live/20 bg-live/10 text-live" variant="outline">
                  <span className="signal signal--live" />
                  Updates automatically
                </Badge>
              </div>

              <div className="relative my-6 min-h-60" aria-hidden="true">
                <svg
                  className="absolute inset-0 h-full w-full overflow-visible"
                  viewBox="0 0 520 280"
                  fill="none"
                  preserveAspectRatio="xMidYMid meet"
                >
                  <path
                    d="M57 235C84 196 105 207 131 168C157 129 130 94 177 82C224 70 230 124 277 119C330 113 304 48 359 47C415 45 421 103 465 75"
                    stroke="var(--border)"
                    strokeWidth="16"
                    strokeLinecap="round"
                  />
                  <path
                    className="landing-route-line"
                    d="M57 235C84 196 105 207 131 168C157 129 130 94 177 82C224 70 230 124 277 119C330 113 304 48 359 47C415 45 421 103 465 75"
                    stroke="var(--primary)"
                    strokeWidth="7"
                    strokeLinecap="round"
                  />
                  <circle
                    cx="57"
                    cy="235"
                    r="10"
                    fill="var(--card)"
                    stroke="var(--foreground)"
                    strokeWidth="5"
                  />
                  <circle
                    cx="465"
                    cy="75"
                    r="13"
                    fill="var(--primary)"
                    stroke="var(--card)"
                    strokeWidth="6"
                  />
                </svg>
              </div>

              <div className="grid grid-cols-3 gap-2 sm:gap-3">
                <Feature icon={MapPinned} label="Route" />
                <Feature icon={Timer} label="Pace" />
                <Feature icon={HeartPulse} label="Heart rate" />
              </div>
            </CardContent>
          </Card>
        </section>

        <footer className="flex flex-col gap-4 border-t border-border/70 py-6 text-xs text-muted-foreground sm:flex-row sm:items-center sm:justify-between">
          <span>Live telemetry from Garmin via RunSync.</span>
          <a
            className="inline-flex items-center gap-1.5 font-medium text-foreground no-underline hover:text-primary"
            href={studioHref}
          >
            Setting up OBS?
            <ArrowRight className="size-3.5" />
          </a>
        </footer>
      </div>
    </main>
  );
}

function Feature({ icon: Icon, label }: { icon: typeof MapPinned; label: string }) {
  return (
    <div className="flex flex-col gap-3 rounded-xl border border-border/80 bg-background/65 p-3.5 backdrop-blur">
      <Icon className="size-4 text-primary" strokeWidth={2} />
      <span className="text-xs font-medium">{label}</span>
    </div>
  );
}
