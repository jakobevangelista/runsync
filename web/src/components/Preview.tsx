import { useEffect, useState } from "react";
import type { PaceMode, Units } from "../lib/contracts";
import { useLive } from "./LiveProvider";
import { MapPanel } from "./MapPanel";
import { MetricsPanel } from "./Metrics";

export function Preview({
  overlayId,
  defaultUnits,
  defaultPace,
}: {
  overlayId: string;
  defaultUnits: Units;
  defaultPace: PaceMode;
}) {
  const { state } = useLive();
  const [units, setUnits] = useState(defaultUnits);
  const [pace, setPace] = useState(defaultPace);
  const [origin, setOrigin] = useState("");
  useEffect(() => setOrigin(window.location.origin), []);
  const query = `units=${units}&pace=${pace}`;
  const base = `${origin}/live/${overlayId}`;
  const links: Array<[string, string, string]> = [
    ["Map", `${base}/map?${query}`, "1280 × 720"],
    ["Metrics panel", `${base}/metrics?${query}`, "920 × 360"],
    ["Pace", `${base}/metric/pace?${query}`, "420 × 180"],
    ["Heart rate", `${base}/metric/heart-rate?${query}`, "420 × 180"],
    ["Distance", `${base}/metric/distance?${query}`, "420 × 180"],
  ];
  return (
    <main className="preview-shell">
      <header className="preview-header">
        <div>
          <span className="eyebrow">RunSync · broadcast monitor</span>
          <h1>Live output desk</h1>
        </div>
        <div className="connection-badge">
          <span className={`signal signal--${state.connection}`} />
          {state.connection}
        </div>
      </header>
      <section className="preview-stage">
        <div className="preview-stage__map">
          <MapPanel />
        </div>
        <div className="preview-stage__metrics">
          <MetricsPanel state={state} units={units} paceMode={pace} />
        </div>
      </section>
      <section className="preview-grid">
        <div className="preview-card controls-card">
          <span className="eyebrow">Output controls</span>
          <fieldset>
            <legend>Units</legend>
            <Segment
              value={units}
              options={["imperial", "metric"]}
              onChange={(value) => setUnits(value as Units)}
            />
          </fieldset>
          <fieldset>
            <legend>Pace source</legend>
            <Segment
              value={pace}
              options={["rolling", "average"]}
              onChange={(value) => setPace(value as PaceMode)}
            />
          </fieldset>
          <p>
            URLs always include explicit settings. The overlay ID is a public unlisted identifier,
            not a secret.
          </p>
        </div>
        <div className="preview-card diagnostics-card">
          <span className="eyebrow">Diagnostics</span>
          <dl>
            <dt>Sample age</dt>
            <dd>
              <SampleAge receivedAt={state.sampleReceivedAt} />
            </dd>
            <dt>Activity</dt>
            <dd>{state.activityId ?? "none"}</dd>
            <dt>Envelope</dt>
            <dd>{state.latestEnvelopeId ?? "none"}</dd>
            <dt>Location</dt>
            <dd>{state.locationPolicy ?? "unknown"}</dd>
          </dl>
        </div>
      </section>
      <section className="obs-links">
        <div className="section-heading">
          <div>
            <span className="eyebrow">OBS browser sources</span>
            <h2>Composed outputs</h2>
          </div>
          <p>Use “Refresh browser when scene becomes active.” Keep custom CSS empty.</p>
        </div>
        {links.map(([label, url, size]) => (
          <ObsLink key={label} label={label} url={url} size={size} />
        ))}
      </section>
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
    <div className="segment">
      {options.map((option) => (
        <button
          type="button"
          className={value === option ? "is-active" : ""}
          onClick={() => onChange(option)}
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
  return (
    <div className="obs-link">
      <div>
        <strong>{label}</strong>
        <small>{size} recommended · 30 FPS</small>
      </div>
      <code>{url}</code>
      <button
        type="button"
        disabled={!url.startsWith("http")}
        onClick={() =>
          void navigator.clipboard.writeText(url).then(() => {
            setCopied(true);
            window.setTimeout(() => setCopied(false), 1200);
          })
        }
      >
        {copied ? "Copied" : "Copy URL"}
      </button>
    </div>
  );
}
