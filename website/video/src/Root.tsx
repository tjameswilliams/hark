import { Composition } from "remotion";
import { Dictate, DICTATE_FRAMES, FPS } from "./Dictate";

export const Root = () => (
  <Composition
    id="Dictate"
    component={Dictate}
    durationInFrames={DICTATE_FRAMES}
    fps={FPS}
    width={1280}
    height={720}
  />
);
