import { motion, MotionConfig } from "framer-motion";

/**
 * GlyphStudioLogo - the Glyph Studio mark (the family's stick figure on an
 * office-green tile, its head an AI sparkle), drawn as inline SVG so it stays
 * crisp at any size. It mirrors public/logo.svg (glyph-studio.svg); at 32 px
 * and below it draws glyph-studio-small.svg instead.
 *
 * When animated, the whole mark does a slow float with a soft 3D tilt and
 * glow, and the small sparkle pulses.
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

  // At 32 px and below the small master: one bold sparkle and thicker lines.
  const small = size <= 32;

  const Spark = small ? null : animated ? (
    <motion.path
      d="M64 15Q64.6 19 68 19.5Q64.6 20 64 24Q63.4 20 60 19.5Q63.4 19 64 15Z"
      fill="#fff"
      animate={{ opacity: [1, 0.35, 1] }}
      transition={{ duration: 1.9, ease: "easeInOut", repeat: Infinity }}
    />
  ) : (
    <path d="M64 15Q64.6 19 68 19.5Q64.6 20 64 24Q63.4 20 60 19.5Q63.4 19 64 15Z" fill="#fff" />
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
      {small ? (
        <>
          <path d="M50 9Q53 28 72 31Q53 34 50 53Q47 34 28 31Q47 28 50 9Z" fill="#fff" />
          <path d="M22 32v3a28 28 0 0 0 56 0v-3M50 63v8M50 71L38 86M50 71L62 86" fill="none" stroke="#fff" strokeWidth="9" strokeLinecap="round" strokeLinejoin="round" />
        </>
      ) : (
        <>
          <path d="M50 18Q52 32 66 34Q52 36 50 50Q48 36 34 34Q48 32 50 18Z" fill="#fff" />
          {Spark}
          <path d="M26 30v4a24 24 0 0 0 48 0v-4M50 58v11M50 69L39 84M50 69L61 84" fill="none" stroke="#fff" strokeWidth="6" strokeLinecap="round" strokeLinejoin="round" />
        </>
      )}
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
