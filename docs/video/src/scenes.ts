/**
 * The scenes of the video, in order. `shots` are pictures of docs/showcase
 * (copied into public/showcase by `npm run render`);
 * `clip` is a mark of public/marks.json: the scene plays the screen recording
 * from there instead.
 */
export type Scene = {
  title: string;
  line: string;
  /** Gradient of the background, top-left to bottom-right. */
  colors: [string, string];
  shots?: string[];
  clip?: string;
  /** A film of its own in public/ (Growing Up, exported on a device: a
   * simulator cannot run Vision), played from its start. */
  film?: string;
  /** Seconds on screen. */
  seconds: number;
};

export const scenes: Scene[] = [
  { title: "Your library", line: "Every photo of your Immich server, in a fast native timeline.", colors: ["#1d2671", "#c33764"], shots: ["timeline", "viewer"], seconds: 4 },
  { title: "Find anything", line: "Smart search, people, places and albums.", colors: ["#0f2027", "#2c5364"], shots: ["search", "people", "albums"], seconds: 4.5 },
  { title: "Road Trip", line: "An album becomes a travel film: the map, the route, the photos.", colors: ["#134e5e", "#71b280"], clip: "roadtrip", seconds: 6 },
  { title: "Reel", line: "Search “beach”, get every beach — cut on the beat.", colors: ["#ff512f", "#dd2476"], clip: "searchreel", seconds: 5 },
  { title: "Growing Up", line: "One face over the years, aligned eye to eye.", colors: ["#3a1c71", "#ffaf7b"], film: "growingup.mp4", seconds: 5.5 },
  { title: "Then & Now", line: "The places you came back to, years apart.", colors: ["#232526", "#414345"], clip: "thenandnow", seconds: 4.5 },
  { title: "Color Mosaic", line: "Any album as one picture, sorted by color.", colors: ["#fc466b", "#3f5efb"], shots: ["mosaic"], seconds: 3.5 },
  { title: "Photo Dump", line: "The best ten, picked for you, ready to post.", colors: ["#f7971e", "#ffd200"], shots: ["photodump"], seconds: 3.5 },
  { title: "Everywhere I’ve been", line: "Every place you photographed, on one poster.", colors: ["#000428", "#004e92"], shots: ["mapposter"], seconds: 3.5 },
  { title: "Wrapped", line: "Your year in photos, as a story to share.", colors: ["#8e2de2", "#ff6a00"], shots: ["wrapped-intro", "wrapped-months", "wrapped-people", "wrapped-colors", "wrapped-best"], seconds: 6 },
];

export const introSeconds = 3.5;
export const outroSeconds = 4;
