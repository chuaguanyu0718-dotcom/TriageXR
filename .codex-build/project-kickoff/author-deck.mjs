import fs from "node:fs/promises";
import { FileBlob, PresentationFile } from "@oai/artifact-tool";

process.on("uncaughtException", (error) => {
  console.error("AUTHOR_ERROR", error?.message ?? String(error), error?.stack?.split("\n").slice(-3).join(" | "));
  process.exit(1);
});
process.on("unhandledRejection", (error) => {
  console.error("AUTHOR_ERROR", error?.message ?? String(error));
  process.exit(1);
});

const root = "/Users/shreeraj/projects/triagexr/TriageXR";
const work = `${root}/.codex-build/project-kickoff`;
const starter = `${work}/template-starter.pptx`;
const output = `${root}/TriageXR-Spatial-Hack-AI.pptx`;
const image1 = "/var/folders/p_/p663ljhn16l7xm3y7c77vgvm0000gp/T/TemporaryItems/NSIRD_screencaptureui_c4iEZ1/Screenshot 2026-08-10 at 10.35.18 AM.png";
const image2 = "/var/folders/p_/p663ljhn16l7xm3y7c77vgvm0000gp/T/TemporaryItems/NSIRD_screencaptureui_zi9gR1/Screenshot 2026-08-10 at 10.35.30 AM.png";

const presentation = await PresentationFile.importPptx(await FileBlob.load(starter));

const shapeRefs = {
  "sh/nep47i1g":[0,0], "sh/pg7m9sjm":[0,1], "sh/0belcni5":[0,2],
  "sh/pkvidgru":[1,0], "sh/2pkvy10r":[1,1], "sh/3qtw761c":[1,2], "sh/qloj6lsf":[1,3], "sh/rmx0fq90":[1,4],
  "sh/cbm18fa9":[2,0], "sh/e1wj6x4z":[2,1], "sh/f250f25k":[2,2], "sh/sze14nm9":[2,3], "sh/2lkz2lsr":[2,4], "sh/3mt0bqtc":[2,5], "sh/bqd0fato":[2,6], "sh/sfihwbap":[2,7], "sh/tgri5gba":[2,8],
  "sh/8jeh0vah":[3,0], "sh/43y5ore9":[3,1], "sh/p47mxwfu":[3,2], "sh/lcb6d0zi":[3,3], "sh/al0nelgv":[3,4], "sh/xor690z6":[3,5], "sh/wni5gvyl":[3,6], "sh/vidojuhk":[3,7], "sh/uhk7qpgz":[3,8], "sh/qdorit07":[3,9], "sh/rex8ry1s":[3,10], "sh/9knit0r2":[3,11],
  "sh/mxwv2dwr":[4,1], "sh/90nex8f2":[4,2], "sh/netwriho":[4,3], "sh/wnydsnet":[4,8], "sh/pgbetsze":[4,9], "sh/ah4v2x0z":[4,10], "sh/xo7e1sve":[4,11], "sh/bidwv2hk":[4,12], "sh/rm9cjyhg":[4,13],
  "sh/lwje54zy":[5,0], "sh/ylcr6hoj":[5,1], "sh/zm58fmp4":[5,2], "sh/q58v6pgb":[5,3], "sh/b6hwzuhw":[5,4],
  "sh/do36pc3a":[6,0], "sh/5kj6ls3e":[6,1], "sh/4zapsnmt":[6,2], "sh/ozq9kze9":[6,3], "sh/p0zad4ve":[6,4], "sh/rm1on2lk":[6,5], "sh/qls7ux4z":[6,6],
  "sh/gbutcfeh":[7,3], "sh/hc3u5kv2":[7,4], "sh/bups3qhc":[7,5], "sh/qtgrulg7":[7,6], "sh/dw7a5gzi":[7,7], "sh/cvy9wvyx":[7,8], "sh/6lsb65wf":[7,9], "sh/7mlczad0":[7,10], "sh/zy9s7qho":[7,11], "sh/ji1cvqdo":[7,12],
  "sh/apgze18j":[8,0], "sh/gfu50zyd":[8,1], "sh/hg3m94fy":[8,2], "sh/nqdcnexc":[8,3], "sh/ormdgjex":[8,4], "sh/9svupofi":[8,5], "sh/e1kva9wv":[8,6], "sh/zmtcjexg":[8,7], "sh/bqp0n694":[8,8],
  "sh/t4vq5gre":[9,0], "sh/r2t83698":[9,1], "sh/ep47e18z":[9,2]
};
const imageRefs = { "im/lkvuhc3q":[1,0], "im/18zy9oj2":[5,0] };

function set(id, value) {
  const [slide, index] = shapeRefs[id];
  const el = presentation.slides.getItem(slide).shapes.items[index];
  el.text = value;
}

function footer(id, value = "TriageXR  •  Spatial Hack AI") {
  const [slide, index] = shapeRefs[id];
  const el = presentation.slides.getItem(slide).shapes.items[index];
  el.text = value;
}

async function replaceImage(id, path, alt) {
  const [slide, index] = imageRefs[id];
  const targetSlide = presentation.slides.getItem(slide);
  const el = targetSlide.images.items[index];
  const bytes = await fs.readFile(path);
  const blob = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
  const frame = el.frame;
  const crop = el.crop;
  const fit = el.fit;
  const geometry = el.geometry;
  const borderRadius = el.borderRadius;
  const replacement = targetSlide.images.add({
    blob,
    contentType: "image/png",
    alt,
    position: frame,
    ...(fit ? { fit } : {}),
    ...(geometry ? { geometry } : {}),
    ...(borderRadius ? { borderRadius } : {})
  });
  if (crop) replacement.crop = crop;
  el.delete();
}

function notes(slideIndex, body) {
  presentation.slides.getItem(slideIndex).speakerNotes.textFrame.setText(
    `${body}\n\n[Sources]\n- Local project source: ${root}/README.md and Swift implementation files.\n- User-supplied images are identified on the relevant slide.\n[/Sources]`
  );
}

// 1 — opening
set("sh/nep47i1g", "TriageXR\nTrain for the chaos before it happens");
set("sh/pg7m9sjm", "Spatial computing + AI for mass-casualty incident readiness");
set("sh/0belcni5", "SPATIAL HACK AI");
notes(0, "Team: Weishuo, Guan, and Shreeraj. Brief 8: How might we train first responders for a mass casualty incident with spatial computing and AI?");

// 2 — problem
footer("sh/pkvidgru");
set("sh/2pkvy10r", "02");
set("sh/3qtw761c", "Live drills are scarce. Decisions still need practice.");
set("sh/qloj6lsf", "High-stakes, low-frequency\nLive exercises need space, actors, equipment, instructors, and reset time.");
set("sh/rmx0fq90", "Decisions happen under pressure\nTrainees must survey hazards, prioritise casualties, coordinate roles, and reassess as conditions change.");
await replaceImage("im/lkvuhc3q", image1, "First-responder mass-casualty training exercise with casualty mannequins");
notes(1, `The photograph was supplied by the user: ${image1}.`);

// 3 — solution
footer("sh/cbm18fa9");
set("sh/e1wj6x4z", "03");
set("sh/f250f25k", "TriageXR turns any safe room into a repeatable, evidence-rich incident");
set("sh/bqd0fato", "SPATIAL");
set("sh/sfihwbap", "ADAPTIVE");
set("sh/tgri5gba", "ACCOUNTABLE");
set("sh/sze14nm9", "See the whole scene\nA mixed-reality roadside collision surrounds the trainee with casualties, vehicles, hazards, and sector beacons.");
set("sh/3mt0bqtc", "Feel time pressure\nCasualty state changes on a clinically meaningful clock; reassessment and sustained team action alter outcomes.");
set("sh/2lkz2lsr", "Explain every choice\nEvery action becomes attributed evidence for a deterministic score and grounded AI coaching.");
notes(2, "TriageXR is a visionOS prototype for Apple Vision Pro. It trains scene awareness, prioritisation, reassessment, and communication—not physical medical procedures.");

// 4 — experience flow
footer("sh/8jeh0vah");
set("sh/43y5ore9", "04");
set("sh/p47mxwfu", "One incident. Four trainable decisions.");
set("sh/9knit0r2", "The trainee moves from briefing to immersive action, then finishes with a reconstructable after-action review. Each step produces evidence—not just completion.");
set("sh/al0nelgv", "01\nSURVEY");
set("sh/lcb6d0zi", "Turn through front, left, rear, and right sectors; identify the fuel spill and request resources.");
set("sh/wni5gvyl", "02\nASSESS");
set("sh/xor690z6", "Reach to 3D targets; hand tracking verifies response, breathing, perfusion, and injury checks.");
set("sh/uhk7qpgz", "03\nTRIAGE");
set("sh/vidojuhk", "Assign P1, P2, P3, or Expectant, then reassess when visible evidence changes.");
set("sh/rex8ry1s", "04\nDEBRIEF");
set("sh/qdorit07", "Replay actions, consequences, role ownership, score breakdown, and the next best drill.");
notes(3, "The flow is implemented across the briefing window, mixed immersive space, spatial verification coordinator, incident state engine, and after-action review.");

// 5 — demo
footer("sh/mxwv2dwr");
set("sh/90nex8f2", "05");
set("sh/netwriho", "The demo proves perception, coordination, and learning in one loop");
set("sh/wnydsnet", "ENTER");
set("sh/pgbetsze", "RESPOND");
set("sh/ah4v2x0z", "LEARN");
set("sh/bidwv2hk", "Immersive scene survey\nScan four sectors, identify the fuel hazard, and establish a safe approach.");
set("sh/xo7e1sve", "Verified team action\nAssess and tag three casualties while another responder sustains simulated CPR coverage.");
set("sh/rm9cjyhg", "Evidence replay\nStep through successful, failed, corrected, and system-generated events with causal explanations.");
notes(4, "The default Demo 8x pace compresses the clinically meaningful deterioration clock for a stage-ready demonstration while keeping the simulated CPR hold duration in real time.");

// 6 — triage
footer("sh/lwje54zy");
set("sh/ylcr6hoj", "06");
set("sh/zm58fmp4", "Triage logic must be visible—and revisited");
set("sh/q58v6pgb", "A structured decision path\nThe experience mirrors adult triage reasoning: mobility, breathing, perfusion, response, catastrophic bleeding, and priority assignment.");
set("sh/b6hwzuhw", "Reassessment changes the answer\nJordan’s untreated cardiac arrest progresses over time. The learner must respond to new evidence—not memorise a static label.");
await replaceImage("im/18zy9oj2", image2, "Adult triage sieve and adult triage decision chart");
notes(5, `The adult triage chart was supplied by the user: ${image2}. The prototype encodes deterministic assessment, priority, deterioration, and reassessment rules.`);

// 7 — differentiation
footer("sh/do36pc3a");
set("sh/5kj6ls3e", "07");
set("sh/4zapsnmt", "Built beyond a simulation: TriageXR measures how teams think");
set("sh/ozq9kze9", "Verified spatial assessment\nARKit confirms sustained reach and hand poses at casualty-specific 3D targets.");
set("sh/p0zad4ve", "Collaborative incident command\nSharePlay synchronises a host-authoritative scene with role permissions and shared spatial placement.");
set("sh/rm1on2lk", "Causal evidence replay\nEvery material action records the cue, actor, outcome, consequence, and spatial snapshot.");
set("sh/qls7ux4z", "Grounded AI coaching\nThe AI can only cite verified replay event IDs; it never changes the deterministic score.");
notes(6, "The prototype also supports a simulator fallback for repeatable demos and a deterministic local coaching fallback when the secure AI relay is unavailable.");

// 8 — proof
footer("sh/ji1cvqdo");
set("sh/gbutcfeh", "08");
set("sh/hc3u5kv2", "The hackathon build already delivers the full training loop");
set("sh/zy9s7qho", "WORKING PROTOTYPE\nNative visionOS experience with three casualties, an interactive hazard, role-aware equipment, scenario timing, collaboration, scoring, and an evidence-grounded debrief.");
set("sh/cvy9wvyx", "4");
set("sh/6lsb65wf", "3");
set("sh/7mlczad0", "100");
set("sh/bups3qhc", "spatial survey sectors must be inspected");
set("sh/dw7a5gzi", "casualties with distinct, changing evidence");
set("sh/qtgrulg7", "point deterministic score across five domains");
notes(7, "The five score domains are Safety, Assessment, Triage, Treatment, and Communication. The local Swift package includes deterministic tests for spatial verification, timing, roles, transport policy, collaboration encoding, and AI citation validation.");

// 9 — roadmap
footer("sh/apgze18j");
set("sh/gfu50zyd", "09");
set("sh/hg3m94fy", "From hackathon prototype to deployable training platform");
const table = presentation.slides.getItem(8).tables.items[0];
["PROTOTYPE", "VALIDATE", "EXPAND", "PILOT", "SCALE"].forEach((v, c) => table.cells.set(0, c, v));
set("sh/bqp0n694", "Vision Pro scenario + evidence loop");
set("sh/zmtcjexg", "Test with first responders and instructors");
set("sh/e1kva9wv", "Add authoring tools and scenario library");
set("sh/nqdcnexc", "Run station-level pilot");
set("sh/9svupofi", "Measure skill transfer and team performance");
set("sh/ormdgjex", "Multi-agency deployment with governance and analytics");
notes(8, "Roadmap items are proposed next steps, not completed capabilities. Validation should include clinical governance, accessibility, privacy, facilitator workflow, and measurable transfer to live exercises.");

// 10 — close
set("sh/t4vq5gre", "Train decisions.\nRehearse teamwork. Save time when it matters.");
set("sh/r2t83698", "TriageXR  •  Weishuo, Guan & Shreeraj");
set("sh/ep47e18z", "SPATIAL HACK AI");
notes(9, "Closing ask: partner with first-responder instructors to validate the scenario, triage logic, debrief usefulness, and operational fit.");

await fs.mkdir(`${work}/final-render`, { recursive: true });
for (const [index, slide] of presentation.slides.items.entries()) {
  const num = String(index + 1).padStart(2, "0");
  const png = await presentation.export({ slide, format: "png", scale: 1 });
  await fs.writeFile(`${work}/final-render/slide-${num}.png`, new Uint8Array(await png.arrayBuffer()));
  const layout = await slide.export({ format: "layout" });
  await fs.writeFile(`${work}/final-render/slide-${num}.layout.json`, await layout.text());
}
const montage = await presentation.export({ format: "webp", montage: true, scale: 1 });
await fs.writeFile(`${work}/final-render/montage.webp`, new Uint8Array(await montage.arrayBuffer()));
const pptx = await PresentationFile.exportPptx(presentation);
await pptx.save(output);
console.log(output);
