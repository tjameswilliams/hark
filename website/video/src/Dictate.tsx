import React from "react";
import {
  AbsoluteFill,
  Easing,
  Img,
  interpolate,
  spring,
  staticFile,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { T } from "./theme";

// The pitch in one breath: hold the key, talk, let go, the agent gets to
// work. Timings below are in frames at 30 fps; the whole thing is 14 s.
export const FPS = 30;
export const DICTATE_FRAMES = 14 * FPS;

const PRESS = 24; // key goes down, pill appears
const SPEAK_START = 40; // first word
const SPEAK_END = 165; // last word
const RELEASE = 178; // key comes up, pill collapses, text lands
const SUBMIT = 208; // the message goes up into the transcript
const WORK_START = 222; // agent starts
const END_CARD = 372; // lockup

const SPOKEN =
  "Add retry with exponential backoff to the upload client, and write a test for the timeout case.".split(
    " ",
  );

const ease = Easing.bezier(...T.ease);

// A stable pseudo-random per (index, frame) so the level meter looks alive
// without a real audio source.
const noise = (i: number, f: number) => {
  const x = Math.sin(i * 12.9898 + f * 0.7) * 43758.5453;
  return x - Math.floor(x);
};

const Keycap: React.FC<{ frame: number }> = ({ frame }) => {
  const down = frame >= PRESS && frame < RELEASE;
  const pressT = spring({ frame: frame - PRESS, fps: FPS, config: { damping: 18, stiffness: 240 } });
  const releaseT = spring({ frame: frame - RELEASE, fps: FPS, config: { damping: 12, stiffness: 200 } });
  const depth = down ? interpolate(pressT, [0, 1], [0, 1]) : frame >= RELEASE ? 1 - releaseT : 0;
  const y = depth * 10;
  return (
    <div style={{ position: "relative", width: 132, height: 132 }}>
      <div
        style={{
          position: "absolute",
          inset: 0,
          top: 12,
          borderRadius: 22,
          background: "#0f0e0d",
        }}
      />
      <div
        style={{
          position: "absolute",
          inset: 0,
          borderRadius: 22,
          background: down ? T.surfaceRaised : T.surface,
          border: `1px solid ${T.hairline}`,
          transform: `translateY(${y}px)`,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          fontFamily: T.sans,
          fontSize: 58,
          color: down ? T.rufous : T.ink,
          boxShadow: down ? `0 0 0 6px rgba(217, 103, 74, 0.18)` : "none",
        }}
      >
        ⌘
      </div>
    </div>
  );
};

const Listening: React.FC<{ frame: number }> = ({ frame }) => {
  const inT = spring({ frame: frame - PRESS - 4, fps: FPS, config: { damping: 14, stiffness: 220 } });
  const outT = spring({ frame: frame - RELEASE, fps: FPS, config: { damping: 20, stiffness: 260 } });
  const scale = frame < RELEASE ? inT : 1 - outT;
  if (scale <= 0.01) return null;
  // Asymmetric heartbeat from docs/brand.md §3.5: fast rise, bright hold,
  // slow decay, dim hold.
  const cycle = ((frame - PRESS) % 54) / 54;
  const beat = interpolate(cycle, [0, 0.1, 0.25, 0.65, 1], [0.55, 1, 1, 0.55, 0.55]);
  const speaking = frame >= SPEAK_START && frame < SPEAK_END;
  return (
    <div
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 12,
        padding: "12px 22px 12px 18px",
        borderRadius: 999,
        background: T.rufous,
        color: "#fff",
        fontFamily: T.sans,
        fontWeight: 600,
        fontSize: 22,
        opacity: beat,
        transform: `scale(${scale})`,
        transformOrigin: "left center",
      }}
    >
      <div style={{ display: "flex", gap: 4, alignItems: "flex-end", height: 22 }}>
        {[0, 1, 2, 3, 4].map((i) => {
          const base = [0.35, 0.8, 0.6, 0.9, 0.45][i];
          const h = speaking ? 0.25 + 0.75 * (base * 0.5 + noise(i, Math.floor(frame / 2)) * 0.5) : 0.2;
          return (
            <div
              key={i}
              style={{ width: 4, height: 22 * h, borderRadius: 2, background: "#fff" }}
            />
          );
        })}
      </div>
      Listening
    </div>
  );
};

// The spoken words, arriving one at a time as they are heard, above the key.
const Speech: React.FC<{ frame: number }> = ({ frame }) => {
  const per = (SPEAK_END - SPEAK_START) / SPOKEN.length;
  const fade = frame >= RELEASE ? 1 - spring({ frame: frame - RELEASE, fps: FPS, config: { damping: 20 } }) : 1;
  if (frame < SPEAK_START || fade <= 0.01) return null;
  return (
    <div
      style={{
        fontFamily: T.sans,
        fontSize: 30,
        lineHeight: 1.35,
        color: T.inkMuted,
        maxWidth: 420,
        opacity: fade,
      }}
    >
      <span style={{ color: T.inkFaint }}>“</span>
      {SPOKEN.map((w, i) => {
        const start = SPEAK_START + i * per;
        // Unheard words take no space yet, so the line wraps as it grows.
        if (frame < start) return null;
        const t = spring({ frame: frame - start, fps: FPS, config: { damping: 16, stiffness: 200 } });
        return (
          <span
            key={i}
            style={{
              display: "inline-block",
              opacity: t,
              transform: `translateY(${(1 - t) * 8}px)`,
              marginRight: i === SPOKEN.length - 1 ? 0 : "0.3em",
            }}
          >
            {w}
          </span>
        );
      })}
      {frame >= SPEAK_END && <span style={{ color: T.inkFaint }}>”</span>}
    </div>
  );
};

type Step = { at: number; label: string; kind: "read" | "edit" | "test" | "done"; diff?: string[] };
const STEPS: Step[] = [
  { at: WORK_START, label: "Reading src/upload/client.rs", kind: "read" },
  {
    at: WORK_START + 28,
    label: "Editing src/upload/client.rs",
    kind: "edit",
    diff: [
      "+ let mut delay = Duration::from_millis(200);",
      "+ for attempt in 0..MAX_RETRIES {",
      "+     match self.try_upload(&body).await {",
      "+         Err(e) if e.is_timeout() => sleep(delay).await,",
      "+     }",
      "+     delay *= 2;",
    ],
  },
  { at: WORK_START + 74, label: "Writing tests/upload_timeout.rs", kind: "edit" },
  { at: WORK_START + 104, label: "cargo test upload::  ·  3 passed", kind: "test" },
];

const Agent: React.FC<{ frame: number }> = ({ frame }) => {
  const inT = spring({ frame: frame - 6, fps: FPS, config: { damping: 18, stiffness: 120 } });
  // The transcript lands in the input at RELEASE, then rises into the
  // conversation at SUBMIT.
  const landT = spring({ frame: frame - RELEASE - 6, fps: FPS, config: { damping: 16, stiffness: 180 } });
  const submitT = spring({ frame: frame - SUBMIT, fps: FPS, config: { damping: 18, stiffness: 160 } });
  const text = SPOKEN.join(" ");
  const typed = Math.round(landT * text.length);
  const inInput = frame >= RELEASE + 6 && frame < SUBMIT;
  const inThread = frame >= SUBMIT;
  const visibleSteps = STEPS.filter((s) => frame >= s.at);
  return (
    <div
      style={{
        width: 720,
        height: 520,
        borderRadius: 16,
        background: T.surface,
        border: `1px solid ${T.hairline}`,
        opacity: inT,
        transform: `translateY(${(1 - inT) * 24}px)`,
        display: "flex",
        flexDirection: "column",
        overflow: "hidden",
        fontFamily: T.mono,
        fontSize: 19,
        color: T.ink,
      }}
    >
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 8,
          padding: "14px 18px",
          borderBottom: `1px solid ${T.hairline}`,
          fontFamily: T.sans,
          fontSize: 15,
          color: T.inkFaint,
        }}
      >
        {["#5c5854", "#5c5854", "#5c5854"].map((c, i) => (
          <span key={i} style={{ width: 11, height: 11, borderRadius: 6, background: c, display: "inline-block" }} />
        ))}
        <span style={{ marginLeft: 8 }}>your coding agent</span>
      </div>

      <div style={{ flex: 1, padding: "20px 22px", display: "flex", flexDirection: "column", gap: 14 }}>
        {inThread && (
          <div
            style={{
              alignSelf: "flex-end",
              maxWidth: 560,
              background: T.surfaceRaised,
              borderRadius: 12,
              padding: "12px 16px",
              fontFamily: T.sans,
              fontSize: 19,
              lineHeight: 1.4,
              opacity: submitT,
              transform: `translateY(${(1 - submitT) * 40}px)`,
            }}
          >
            {text}
          </div>
        )}
        {visibleSteps.map((s, i) => {
          const t = spring({ frame: frame - s.at, fps: FPS, config: { damping: 16, stiffness: 200 } });
          const next = STEPS[i + 1];
          const done = next ? frame >= next.at : s.kind === "test" && frame >= s.at + 18;
          const color = s.kind === "test" ? T.positive : T.inkMuted;
          return (
            <div key={s.at} style={{ opacity: t, transform: `translateX(${(1 - t) * -12}px)` }}>
              <div style={{ display: "flex", alignItems: "center", gap: 12, color }}>
                <Dot done={done} frame={frame} kind={s.kind} />
                <span style={{ color: s.kind === "test" ? T.positive : T.ink }}>{s.label}</span>
              </div>
              {s.diff && (
                <div style={{ marginLeft: 30, marginTop: 8, fontSize: 16, lineHeight: 1.5, color: T.positive }}>
                  {s.diff.map((line, j) => {
                    const lt = spring({ frame: frame - s.at - 6 - j * 4, fps: FPS, config: { damping: 20, stiffness: 240 } });
                    return (
                      <div key={j} style={{ opacity: lt, whiteSpace: "pre" }}>
                        {line}
                      </div>
                    );
                  })}
                </div>
              )}
            </div>
          );
        })}
      </div>

      <div style={{ padding: "0 22px 20px" }}>
        <div
          style={{
            border: `1px solid ${inInput ? T.rufous : T.hairline}`,
            borderRadius: 12,
            padding: "14px 16px",
            minHeight: 54,
            fontFamily: T.sans,
            fontSize: 19,
            lineHeight: 1.4,
            color: inInput ? T.ink : T.inkFaint,
            background: T.canvas,
            transition: "border-color 0.2s",
          }}
        >
          {inInput ? (
            <>
              {text.slice(0, typed)}
              <span style={{ opacity: Math.floor(frame / 8) % 2 ? 0 : 1, color: T.rufous }}>▍</span>
            </>
          ) : (
            "Ask the agent anything…"
          )}
        </div>
      </div>
    </div>
  );
};

const Dot: React.FC<{ done: boolean; frame: number; kind: Step["kind"] }> = ({ done, frame, kind }) => {
  if (done || kind === "test") {
    return (
      <span
        style={{
          width: 18,
          height: 18,
          borderRadius: 9,
          background: kind === "test" ? T.positive : T.inkFaint,
          color: T.canvas,
          fontSize: 12,
          display: "inline-flex",
          alignItems: "center",
          justifyContent: "center",
          fontWeight: 700,
        }}
      >
        ✓
      </span>
    );
  }
  return (
    <span
      style={{
        width: 18,
        height: 18,
        borderRadius: 9,
        border: `2px solid ${T.rufous}`,
        borderTopColor: "transparent",
        display: "inline-block",
        transform: `rotate(${(frame * 14) % 360}deg)`,
      }}
    />
  );
};

const EndCard: React.FC<{ frame: number }> = ({ frame }) => {
  const t = spring({ frame: frame - END_CARD, fps: FPS, config: { damping: 18, stiffness: 120 } });
  if (frame < END_CARD) return null;
  return (
    <AbsoluteFill
      style={{
        background: T.canvas,
        opacity: t,
        alignItems: "center",
        justifyContent: "center",
        gap: 28,
      }}
    >
      <Img src={staticFile("lockup-ivory.svg")} style={{ width: 460, transform: `translateY(${(1 - t) * 16}px)` }} />
      <div style={{ fontFamily: T.sans, fontSize: 40, fontWeight: 600, letterSpacing: -0.8, color: T.ink }}>
        Hold a key. Speak. Release.
      </div>
      <div
        style={{
          fontFamily: T.mono,
          fontSize: 20,
          color: T.inkMuted,
          background: T.surface,
          border: `1px solid ${T.hairline}`,
          borderRadius: 10,
          padding: "12px 20px",
        }}
      >
        brew install --cask tjameswilliams/tap/hark
      </div>
    </AbsoluteFill>
  );
};

export const Dictate: React.FC = () => {
  const frame = useCurrentFrame();
  const { width, height } = useVideoConfig();
  // Fade the working scene into the end card.
  const sceneOpacity = interpolate(frame, [END_CARD - 12, END_CARD + 8], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
    easing: ease,
  });
  return (
    <AbsoluteFill style={{ background: T.canvas }}>
      <AbsoluteFill style={{ opacity: sceneOpacity }}>
        <div
          style={{
            position: "absolute",
            left: 72,
            top: 0,
            height,
            width: 420,
            display: "flex",
            flexDirection: "column",
            justifyContent: "center",
            gap: 36,
          }}
        >
          <div style={{ minHeight: 170, display: "flex", alignItems: "flex-end" }}>
            <Speech frame={frame} />
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: 28 }}>
            <Keycap frame={frame} />
            <Listening frame={frame} />
          </div>
          <div style={{ fontFamily: T.sans, fontSize: 18, color: T.inkFaint, minHeight: 26 }}>
            {frame < PRESS && "Hold right ⌘"}
            {frame >= PRESS && frame < RELEASE && "Talking…"}
            {frame >= RELEASE && frame < SUBMIT && "Released. Text lands where the cursor is."}
            {frame >= SUBMIT && "The agent gets to work."}
          </div>
        </div>
        <div style={{ position: "absolute", left: width - 48 - 720, top: (height - 520) / 2, width: 720 }}>
          <Agent frame={frame} />
        </div>
      </AbsoluteFill>
      <EndCard frame={frame} />
    </AbsoluteFill>
  );
};
