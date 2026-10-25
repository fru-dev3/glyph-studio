import { motion, MotionConfig } from "framer-motion";

/**
 * PrevailLogo - the Prevail mark (ascending chevrons + guiding star), drawn as
 * inline SVG so it stays crisp at any size and the guiding star can animate on
 * its own.
 *
 * The mark mirrors public/logo.svg exactly: a dark tile, two office-green chevrons
 * climbing toward a cyan star lifted clear of the apex. When animated, the
 * whole mark does a slow "rise" (gentle float + soft 3D tilt + glow) and the
 * star bounces above the chevrons like a guiding beacon.
 *
 * Drop-in usage:
 *   <PrevailLogo size={84} />                    // animated
 *   <PrevailLogo size={32} animated={false} />   // static mark
 *
 * `src` is accepted for backwards compatibility but ignored - the mark is now
 * vector, not a raster file.
 */
export function PrevailLogo({
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

  // The static artwork - tile + chevrons. The star is rendered separately so it
  // can animate independently when `animated`.
  const Star = animated ? (
    <motion.circle
      cx="256"
      r="22"
      fill="#3CD8FF"
      animate={{ cy: [106, 90, 106], opacity: [1, 0.75, 1] }}
      transition={{ duration: 1.9, ease: "easeInOut", repeat: Infinity }}
      style={{ filter: "drop-shadow(0 0 6px rgba(60,216,255,0.55))" }}
    />
  ) : (
    <circle cx="256" cy="106" r="22" fill="#3CD8FF" />
  );

  const svg = (
    <svg
      viewBox="0 0 512 512"
      width={size}
      height={size}
      style={{ width: size, height: size, display: "block" }}
      role="img"
      aria-label="Glyph Studio"
    >
      <rect x="0" y="0" width="512" height="512" rx="116" fill="#141416" />
      <g fill="none" strokeLinecap="round" strokeLinejoin="round">
        <path d="M116 312 L256 176 L396 312" stroke="#2E9E2E" strokeWidth="56" />
        <path d="M156 392 L256 296 L356 392" stroke="#1A5C1A" strokeWidth="34" />
      </g>
      {Star}
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
            "drop-shadow(0 2px 6px rgba(46,158,46,0.35))",
            "drop-shadow(0 8px 18px rgba(60,216,255,0.45))",
            "drop-shadow(0 2px 6px rgba(46,158,46,0.35))",
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

export default PrevailLogo;
