import { useEffect, useState } from "react";
import {
  Activity,
  Check,
  ChevronRight,
  CircleGauge,
  Copy,
  Map,
  MonitorUp,
  Radio,
  SlidersHorizontal,
} from "lucide-react";

import type { PaceMode, Units } from "../lib/contracts";
import { cn } from "../lib/utils";
import { Brand } from "./Brand";
import { useLive } from "./LiveProvider";
import { MapPanel } from "./MapPanel";
import { MetricsPanel } from "./Metrics";
import { ThemeToggle } from "./ThemeToggle";
import { Badge } from "./ui/badge";
import { Button } from "./ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "./ui/card";
import { Separator } from "./ui/separator";

export function Preview({
  embedId,
  defaultUnits,
  defaultPace,
}: {
  embedId: string;
  defaultUnits: Units;
  defaultPace: PaceMode;
}) {
  const { state } = useLive();
  const [units, setUnits] = useState(defaultUnits);
  const [pace, setPace] = useState(defaultPace);
  const [origin, setOrigin] = useState("");
  useEffect(() => setOrigin(window.location.origin), []);
  const query = `units=${units}&pace=${pace}`;
  const base = `${origin}/embed/${embedId}`;
  const links: Array<[string, string, string]> = [
    ["Map", `${base}/map?${query}`, "1280 × 720"],
    ["Metrics panel", `${base}/metrics?${query}`, "920 × 360"],
    ["Pace", `${base}/metric/pace?${query}`, "420 × 180"],
    ["Heart rate", `${base}/metric/heart-rate?${query}`, "420 × 180"],
    ["Distance", `${base}/metric/distance?${query}`, "420 × 180"],
  ];
  return (
    <main className="min-h-svh bg-background text-foreground">
      <div className="mx-auto w-full max-w-[90rem] px-4 py-4 sm:px-7 sm:py-6 lg:px-10">
        <header className="flex items-center justify-between gap-4 border-b border-border/70 pb-5">
          <Brand />
          <div className="flex items-center gap-1">
            <ThemeToggle />
            <Badge className="h-7 gap-2 bg-card px-3 shadow-xs" variant="outline">
              <span className={`signal signal--${state.connection}`} />
              {state.connection}
            </Badge>
          </div>
        </header>

        <section className="flex flex-col gap-4 py-9 sm:flex-row sm:items-end sm:justify-between sm:py-11">
          <div>
            <p className="flex items-center gap-2 text-xs font-medium tracking-[0.13em] text-primary uppercase">
              <MonitorUp className="size-3.5" />
              Broadcast monitor
            </p>
            <h1 className="mt-3 text-4xl font-semibold tracking-[-0.055em] sm:text-6xl">
              Live output desk
            </h1>
          </div>
          <p className="max-w-sm text-sm leading-6 text-muted-foreground">
            Preview the current broadcast, tune its display settings, and copy browser-source URLs
            into OBS.
          </p>
        </section>

        <Card className="grid min-h-[34rem] overflow-hidden border-foreground/10 bg-card py-0 shadow-[0_24px_70px_rgb(45_37_24/10%)] xl:grid-cols-[minmax(0,1.55fr)_minmax(330px,0.62fr)]">
          <div className="relative min-h-[28rem] overflow-hidden xl:min-h-[42rem]">
            <div className="absolute inset-0">
              <MapPanel />
            </div>
          </div>
          <div className="border-t border-border/80 bg-muted/25 p-3 sm:p-4 xl:border-t-0 xl:border-l">
            <MetricsPanel state={state} units={units} paceMode={pace} />
          </div>
        </Card>

        <section className="mt-4 grid gap-4 lg:grid-cols-2">
          <Card className="gap-5 border-foreground/10">
            <CardHeader>
              <div className="flex items-center gap-3">
                <span className="grid size-9 place-items-center rounded-xl bg-primary/10 text-primary">
                  <SlidersHorizontal className="size-4" />
                </span>
                <div>
                  <CardTitle>Output controls</CardTitle>
                  <CardDescription className="mt-1">
                    These settings are written into every copied URL.
                  </CardDescription>
                </div>
              </div>
            </CardHeader>
            <CardContent className="grid gap-5 sm:grid-cols-2">
              <fieldset>
                <legend className="mb-2 text-xs font-medium text-muted-foreground">Units</legend>
                <Segment
                  value={units}
                  options={["imperial", "metric"]}
                  onChange={(value) => setUnits(value as Units)}
                />
              </fieldset>
              <fieldset>
                <legend className="mb-2 text-xs font-medium text-muted-foreground">
                  Pace source
                </legend>
                <Segment
                  value={pace}
                  options={["rolling", "average"]}
                  onChange={(value) => setPace(value as PaceMode)}
                />
              </fieldset>
              <p className="m-0 border-t border-border/80 pt-4 text-xs leading-5 text-muted-foreground sm:col-span-2">
                The embed ID is a public unlisted identifier, not a secret. URLs always include
                explicit settings.
              </p>
            </CardContent>
          </Card>

          <Card className="gap-5 border-foreground/10">
            <CardHeader>
              <div className="flex items-center gap-3">
                <span className="grid size-9 place-items-center rounded-xl bg-route/10 text-route">
                  <Activity className="size-4" />
                </span>
                <div>
                  <CardTitle>Diagnostics</CardTitle>
                  <CardDescription className="mt-1">
                    The current telemetry session at a glance.
                  </CardDescription>
                </div>
              </div>
            </CardHeader>
            <CardContent>
              <dl className="grid grid-cols-[auto_minmax(0,1fr)] gap-x-6 gap-y-3 text-xs">
                <dt className="text-muted-foreground">Sample age</dt>
                <dd className="m-0 truncate text-right font-mono">
                  <SampleAge receivedAt={state.sampleReceivedAt} />
                </dd>
                <dt className="text-muted-foreground">Activity</dt>
                <dd className="m-0 truncate text-right font-mono">{state.activityId ?? "none"}</dd>
                <dt className="text-muted-foreground">Envelope</dt>
                <dd className="m-0 truncate text-right font-mono">
                  {state.latestEnvelopeId ?? "none"}
                </dd>
                <dt className="text-muted-foreground">Location</dt>
                <dd className="m-0 truncate text-right font-mono">
                  {state.locationPolicy ?? "unknown"}
                </dd>
              </dl>
            </CardContent>
          </Card>
        </section>

        <section className="py-16 sm:py-20">
          <div className="mb-7 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <p className="flex items-center gap-2 text-xs font-medium tracking-[0.13em] text-primary uppercase">
                <Radio className="size-3.5" />
                OBS browser sources
              </p>
              <h2 className="mt-3 text-3xl font-semibold tracking-[-0.045em] sm:text-4xl">
                Composed outputs
              </h2>
            </div>
            <p className="max-w-sm text-xs leading-5 text-muted-foreground">
              Use “Refresh browser when scene becomes active.” Keep custom CSS empty.
            </p>
          </div>
          <Card className="gap-0 overflow-hidden border-foreground/10 py-0">
            {links.map(([label, url, size], index) => (
              <div key={label}>
                {index > 0 ? <Separator /> : null}
                <ObsLink label={label} url={url} size={size} />
              </div>
            ))}
          </Card>
        </section>
      </div>
    </main>
  );
}

function SampleAge({ receivedAt }: { receivedAt: number | undefined }) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    const interval = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(interval);
  }, []);
  return receivedAt === undefined
    ? "waiting"
    : `${Math.max(0, Math.round((now - receivedAt) / 1000))}s`;
}

function Segment({
  value,
  options,
  onChange,
}: {
  value: string;
  options: string[];
  onChange: (value: string) => void;
}) {
  return (
    <div className="grid grid-cols-2 rounded-lg border border-border bg-muted/60 p-1">
      {options.map((option) => (
        <button
          type="button"
          className={cn(
            "h-8 rounded-md px-3 text-xs font-medium text-muted-foreground capitalize transition-all outline-none focus-visible:ring-2 focus-visible:ring-ring/50",
            value === option && "bg-card text-foreground shadow-xs",
          )}
          onClick={() => onChange(option)}
          aria-pressed={value === option}
          key={option}
        >
          {option}
        </button>
      ))}
    </div>
  );
}

function ObsLink({ label, url, size }: { label: string; url: string; size: string }) {
  const [copied, setCopied] = useState(false);
  const Icon = label === "Map" ? Map : label === "Metrics panel" ? CircleGauge : ChevronRight;
  return (
    <div className="grid items-center gap-4 px-5 py-4 sm:grid-cols-[minmax(150px,0.45fr)_minmax(0,1fr)_auto] sm:px-6">
      <div className="flex items-center gap-3">
        <span className="grid size-9 shrink-0 place-items-center rounded-xl bg-muted text-muted-foreground">
          <Icon className="size-4" />
        </span>
        <div className="min-w-0">
          <strong className="block text-sm font-semibold">{label}</strong>
          <small className="mt-0.5 block text-[10px] text-muted-foreground">{size} · 30 FPS</small>
        </div>
      </div>
      <code className="row-start-2 min-w-0 truncate rounded-lg bg-muted/60 px-3 py-2 text-[11px] text-muted-foreground sm:row-start-auto">
        {url}
      </code>
      <Button
        type="button"
        variant={copied ? "secondary" : "outline"}
        size="sm"
        className="row-span-2 justify-self-end sm:row-span-1"
        disabled={!url.startsWith("http")}
        onClick={() =>
          void navigator.clipboard.writeText(url).then(() => {
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1200);
          })
        }
      >
        {copied ? <Check data-icon="inline-start" /> : <Copy data-icon="inline-start" />}
        {copied ? "Copied" : "Copy URL"}
      </Button>
    </div>
  );
}
