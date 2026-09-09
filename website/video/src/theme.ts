// Brand tokens, dark set, from docs/brand.md §3.1. The clip is always dark:
// it reads as a screen on the light site and as canvas on the dark one.
export const T = {
  canvas: "#161412",
  surface: "#211e1b",
  surfaceRaised: "#2a2622",
  ink: "#f3eee6",
  inkMuted: "#b3aa9e",
  inkFaint: "#8b847b",
  hairline: "rgba(243, 238, 230, 0.1)",
  rufous: "#d9674a",
  positive: "#7fd88f",
  sans: 'ui-sans-serif, -apple-system, BlinkMacSystemFont, "Helvetica Neue", Helvetica, Arial, sans-serif',
  mono: 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace',
  // easeOutQuart, the house curve.
  ease: [0.165, 0.84, 0.44, 1] as [number, number, number, number],
};
