import { Composition } from "remotion";
import { Showcase, showcaseDuration } from "./Showcase";

export const RemotionRoot = () => (
  <Composition
    id="Showcase"
    component={Showcase}
    durationInFrames={showcaseDuration}
    fps={30}
    width={1920}
    height={1080}
  />
);
