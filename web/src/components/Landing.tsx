export function Landing({ shareId, studioId }: { shareId: string; studioId: string }) {
  const shareHref = `/share/${encodeURIComponent(shareId)}`;
  const studioHref = `/studio/${encodeURIComponent(studioId)}`;
  return (
    <main className="landing-shell">
      <div className="landing-glow landing-glow--lime" />
      <div className="landing-glow landing-glow--cyan" />
      <section className="landing-hero">
        <div className="landing-mark" aria-hidden="true">
          <span>RS</span>
        </div>
        <div className="landing-copy">
          <span className="eyebrow">RunSync · live run tracking</span>
          <h1>Follow the run, as it happens.</h1>
          <p>
            See the current route, pace, heart rate, distance, and the completed run when it
            finishes.
          </p>
          <a className="landing-primary" href={shareHref}>
            View the current run
            <span aria-hidden="true">→</span>
          </a>
          <p className="landing-note">Anyone with the shared link can view this run.</p>
        </div>
        <div className="landing-route" aria-hidden="true">
          <span className="landing-route__start" />
          <span className="landing-route__finish" />
        </div>
      </section>
      <aside className="landing-tools">
        <div>
          <span className="eyebrow">For broadcasting</span>
          <strong>Setting up OBS?</strong>
          <p>Open the broadcast desk for map and metric browser-source links.</p>
        </div>
        <a href={studioHref}>Broadcast tools</a>
      </aside>
    </main>
  );
}
