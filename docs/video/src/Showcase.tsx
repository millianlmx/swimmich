import { AbsoluteFill, Img, OffthreadVideo, Sequence, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import marks from "../public/marks.json";
import { introSeconds, outroSeconds, scenes, type Scene } from "./scenes";

const FPS = 30;
const frames = (seconds: number) => Math.round(seconds * FPS);

export const showcaseDuration =
  frames(introSeconds) + scenes.reduce((sum, scene) => sum + frames(scene.seconds), 0) + frames(outroSeconds);

const font = "-apple-system, 'SF Pro Display', 'Helvetica Neue', Arial, sans-serif";

/** An iPhone: the bezel, the rounded screen, whatever plays in it. */
const Phone = ({ children }: { children: React.ReactNode }) => (
  <div
    style={{
      width: 430,
      height: 935,
      borderRadius: 72,
      background: "#0b0b0d",
      padding: 16,
      boxShadow: "0 40px 120px rgba(0,0,0,0.55), inset 0 0 0 3px #2a2a2e",
    }}
  >
    <div style={{ width: "100%", height: "100%", borderRadius: 58, overflow: "hidden", position: "relative", background: "#000" }}>
      {children}
    </div>
  </div>
);

/** The pictures of a scene, one after the other, each sliding in. */
const Shots = ({ shots, duration }: { shots: string[]; duration: number }) => {
  const frame = useCurrentFrame();
  const each = duration / shots.length;
  return (
    <>
      {shots.map((shot, index) => {
        const local = frame - index * each;
        const x = interpolate(local, [0, 10], [100, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
        const visible = local >= 0 && (index === shots.length - 1 || local < each + 10);
        return visible ? (
          <Img
            key={shot}
            src={staticFile(`showcase/${shot}.png`)}
            style={{ position: "absolute", inset: 0, width: "100%", height: "100%", objectFit: "cover", transform: `translateX(${x}%)` }}
          />
        ) : null;
      })}
    </>
  );
};

const SceneView = ({ scene }: { scene: Scene }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const duration = frames(scene.seconds);
  const enter = spring({ frame, fps, config: { damping: 200 } });
  const leave = interpolate(frame, [duration - 8, duration], [1, 0], { extrapolateLeft: "clamp" });
  const start = scene.clip ? (marks as Record<string, number>)[scene.clip] : undefined;
  return (
    <AbsoluteFill
      style={{
        background: `linear-gradient(135deg, ${scene.colors[0]}, ${scene.colors[1]})`,
        flexDirection: "row",
        alignItems: "center",
        justifyContent: "center",
        gap: 140,
        fontFamily: font,
        opacity: leave,
      }}
    >
      <div style={{ width: 760, color: "white", transform: `translateY(${(1 - enter) * 40}px)`, opacity: enter }}>
        <div style={{ fontSize: 92, fontWeight: 800, letterSpacing: -2, lineHeight: 1.05 }}>{scene.title}</div>
        <div style={{ fontSize: 42, fontWeight: 500, opacity: 0.88, marginTop: 28, lineHeight: 1.25 }}>{scene.line}</div>
      </div>
      <div style={{ transform: `translateY(${(1 - enter) * 80}px) scale(${0.94 + enter * 0.06})` }}>
        <Phone>
          {scene.film ? (
            <OffthreadVideo src={staticFile(scene.film)} muted style={{ width: "100%", height: "100%", objectFit: "cover" }} />
          ) : start !== undefined ? (
            <OffthreadVideo
              src={staticFile("walk.mp4")}
              startFrom={frames(start)}
              muted
              style={{ width: "100%", height: "100%", objectFit: "cover" }}
            />
          ) : (
            <Shots shots={scene.shots ?? []} duration={duration} />
          )}
        </Phone>
      </div>
    </AbsoluteFill>
  );
};

const Intro = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const pop = spring({ frame, fps, config: { damping: 14 } });
  const line = interpolate(frame, [18, 36], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <AbsoluteFill style={{ background: "linear-gradient(135deg, #4c1d95, #db2777)", alignItems: "center", justifyContent: "center", fontFamily: font, color: "white" }}>
      <Img src={staticFile("logo.svg")} style={{ width: 220, height: 220, transform: `scale(${pop})`, borderRadius: 48 }} />
      <div style={{ fontSize: 120, fontWeight: 800, letterSpacing: -3, marginTop: 36, transform: `scale(${0.9 + pop * 0.1})` }}>Swimmich</div>
      <div style={{ fontSize: 46, fontWeight: 500, opacity: line, marginTop: 12 }}>Your Immich library, native on iPhone.</div>
    </AbsoluteFill>
  );
};

const Outro = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const pop = spring({ frame, fps, config: { damping: 200 } });
  return (
    <AbsoluteFill style={{ background: "linear-gradient(135deg, #db2777, #4c1d95)", alignItems: "center", justifyContent: "center", fontFamily: font, color: "white", textAlign: "center" }}>
      <div style={{ fontSize: 96, fontWeight: 800, letterSpacing: -2, opacity: pop }}>Free, with its code on GitHub.</div>
      <div style={{ fontSize: 48, fontWeight: 500, opacity: pop * 0.9, marginTop: 24 }}>For your own Immich server.</div>
      <div style={{ fontSize: 40, fontWeight: 700, marginTop: 64, padding: "18px 40px", borderRadius: 999, background: "rgba(0,0,0,0.25)", opacity: pop }}>
        github.com/millianlmx/swimmich
      </div>
    </AbsoluteFill>
  );
};

export const Showcase = () => {
  let at = frames(introSeconds);
  return (
    <AbsoluteFill style={{ background: "black" }}>
      <Sequence durationInFrames={frames(introSeconds)}>
        <Intro />
      </Sequence>
      {scenes.map((scene) => {
        const from = at;
        at += frames(scene.seconds);
        return (
          <Sequence key={scene.title} from={from} durationInFrames={frames(scene.seconds)}>
            <SceneView scene={scene} />
          </Sequence>
        );
      })}
      <Sequence from={at} durationInFrames={frames(outroSeconds)}>
        <Outro />
      </Sequence>
    </AbsoluteFill>
  );
};
