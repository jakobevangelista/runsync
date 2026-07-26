import { cn } from "../lib/utils";

export const STREAMSYNC_PROGRAM_URL =
  "https://media.streamsync.studio/live/prg_022461db42ba/" +
  "?controls=true&muted=true&autoplay=true&playsinline=true";

export function StreamsyncPlayer({ className }: { className?: string }) {
  return (
    <div
      className={cn(
        "relative aspect-video w-full overflow-hidden border-2 border-foreground/25 bg-black",
        className,
      )}
    >
      <iframe
        className="absolute inset-0 size-full border-0"
        title="Live video"
        src={STREAMSYNC_PROGRAM_URL}
        allow="autoplay; fullscreen; picture-in-picture"
        allowFullScreen
      />
    </div>
  );
}
