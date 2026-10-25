// The Glyph Studio wordmark (was the PREVAIL wordmark), extracted from App.tsx.
// Exported as BrandMark (not "Brand") so it never collides with the Brand *type*
// in ./types. The mark itself lives where it has room (app icon, Council hero,
// empty state).
export function BrandMark({ className = "" }: { className?: string }) {
  return (
    <span className={className} style={{ letterSpacing: "inherit" }}>
      Glyph Studio
    </span>
  );
}
