import { motion, MotionConfig } from "framer-motion";

/**
 * GlyphStudioLogo - the Glyph Studio mark (a petroglyph figure beside a
 * spiral on an office-green tile), drawn as inline SVG so it stays crisp at
 * any size. It mirrors public/logo.svg (the family's studio-tile.svg).
 *
 * When animated, the whole mark does a slow float with a soft 3D tilt and
 * glow, and the spark at the spiral's heart pulses.
 *
 *   <GlyphStudioLogo size={84} />                    // animated
 *   <GlyphStudioLogo size={32} animated={false} />   // static mark
 *
 * `src` is accepted for backwards compatibility but ignored.
 */
export function GlyphStudioLogo({
  size = 84,
  src: _src,
  animated = true,
  /** Play even when the OS "Reduce Motion" setting is on (decorative mark). */
  forceMotion = true,
}: {
  size?: number;
  src?: string;
  animated?: boolean;
  forceMotion?: boolean;
}) {
  void _src;

  const Spark = animated ? (
    <motion.circle
      cx="66"
      cy="53"
      r="5.5"
      fill="#b9f0b0"
      animate={{ opacity: [1, 0.55, 1], r: [5.5, 6.5, 5.5] }}
      transition={{ duration: 1.9, ease: "easeInOut", repeat: Infinity }}
    />
  ) : (
    <circle cx="66" cy="53" r="5.5" fill="#b9f0b0" />
  );

  const svg = (
    <svg
      viewBox="0 0 100 100"
      width={size}
      height={size}
      style={{ width: size, height: size, display: "block" }}
      role="img"
      aria-label="Glyph Studio"
    >
      <rect width="100" height="100" rx="22" fill="#008000" />
      <g transform="translate(10 10) scale(.8)">
        <g fill="none" stroke="#fff" strokeLinecap="round" strokeLinejoin="round">
          <circle cx="26" cy="17" r="8" fill="#fff" stroke="none" />
          <path d="M9 22v4a17 17 0 0 0 34 0v-4M26 43v21M26 64 15 89M26 64l11 25" strokeWidth="7" />
          <path d="M66 53a6.25 6.25 0 0 1 12.5 0 12.5 12.5 0 0 1-25 0 18.75 18.75 0 0 1 37.5 0" strokeWidth="6.5" />
        </g>
        {Spark}
      </g>
    </svg>
  );

  if (!animated) return svg;

  const T = 6; // gentle loop seconds
  const float = Math.max(2, size * 0.045); // vertical travel scales with size

  const content = (
    <span
      style={{
        position: "relative",
        display: "inline-block",
        perspective: size * 6,
        width: size,
        height: size,
      }}
    >
      <motion.span
        style={{
          position: "relative",
          display: "inline-block",
          transformStyle: "preserve-3d",
          willChange: "transform, filter",
        }}
        animate={{
          y: [0, -float, 0],
          rotateX: [7, 2, 7],
          rotateY: [-5, 5, -5],
          filter: [
            "drop-shadow(0 2px 6px rgba(0,128,0,0.30))",
            "drop-shadow(0 8px 18px rgba(63,163,77,0.45))",
            "drop-shadow(0 2px 6px rgba(0,128,0,0.30))",
          ],
        }}
        transition={{ duration: T, ease: "easeInOut", repeat: Infinity }}
        whileHover={{ scale: 1.1 }}
      >
        {svg}
      </motion.span>
    </span>
  );

  return forceMotion ? (
    <MotionConfig reducedMotion="never">{content}</MotionConfig>
  ) : (
    content
  );
}

export default GlyphStudioLogo;
