import fs from "node:fs/promises";
import { FileBlob, PresentationFile } from "@oai/artifact-tool";

const root = "/Users/shreeraj/projects/triagexr/TriageXR";
const work = `${root}/.codex-build/existing-pitch`;
const starter = `${work}/template-starter.pptx`;
const output = `${root}/TriageXR-Hackathon-Judges.pptx`;
const trainingPhoto = "/var/folders/p_/p663ljhn16l7xm3y7c77vgvm0000gp/T/TemporaryItems/NSIRD_screencaptureui_c4iEZ1/Screenshot 2026-08-10 at 10.35.18 AM.png";

process.on("uncaughtException", (error) => {
  console.error("AUTHOR_ERROR", error?.message ?? String(error));
  process.exit(1);
});

const deck = await PresentationFile.importPptx(await FileBlob.load(starter));

const C = {
  white: "#FFFFFF",
  muted: "#A7B0BE",
  blue: "#00A9E8",
  cyan: "#37E6FF",
  navy: "#071425",
  panel: "#081A2A",
  panel2: "#0A2235",
  line: "#1F4562",
  green: "#66E4B3",
  amber: "#F2C14E",
  red: "#FF6B6B"
};

function addText(slide, name, text, position, style = {}) {
  const shape = slide.shapes.add({
    geometry: "textbox",
    name,
    position,
    fill: "none",
    line: { style: "solid", fill: "none", width: 0 }
  });
  shape.text = text;
  shape.text.style = {
    typeface: style.typeface ?? "Aileron",
    fontSize: style.fontSize ?? 28,
    bold: style.bold ?? false,
    color: style.color ?? C.white,
    alignment: style.alignment ?? "left",
    verticalAlignment: style.verticalAlignment ?? "middle",
    wrap: true,
    autoFit: "shrinkText",
    ...style
  };
  return shape;
}

function addBox(slide, name, position, fill = C.panel, line = C.line, radius = "rounded-xl") {
  return slide.shapes.add({
    geometry: "roundRect",
    name,
    position,
    fill,
    line: { style: "solid", fill: line, width: 1.5 },
    borderRadius: radius
  });
}

function addRule(slide, name, position, fill = C.blue) {
  return slide.shapes.add({
    geometry: "rect",
    name,
    position,
    fill,
    line: { style: "solid", fill: "none", width: 0 }
  });
}

function addDot(slide, name, x, y, fill = C.cyan) {
  return slide.shapes.add({
    geometry: "ellipse",
    name,
    position: { left: x, top: y, width: 22, height: 22 },
    fill,
    line: { style: "solid", fill, width: 1 }
  });
}

function title(slide, eyebrow, headline) {
  addText(slide, "eyebrow", eyebrow.toUpperCase(), { left: 108, top: 78, width: 760, height: 42 }, {
    fontSize: 21, bold: true, color: C.cyan, typeface: "Aileron Bold"
  });
  addText(slide, "headline", headline, { left: 108, top: 125, width: 1660, height: 130 }, {
    fontSize: 56, bold: true, color: C.white, typeface: "Aileron Bold", verticalAlignment: "top"
  });
}

function footer(slide, number) {
  addText(slide, `footer-${number}`, `TRIAGEXR   •   SPATIAL HACK AI`, { left: 108, top: 1016, width: 600, height: 28 }, {
    fontSize: 14, bold: true, color: C.muted
  });
  addText(slide, `page-${number}`, String(number).padStart(2, "0"), { left: 1730, top: 1016, width: 82, height: 28 }, {
    fontSize: 14, bold: true, color: C.muted, alignment: "right"
  });
}

function setNotes(slide, body, extra = "") {
  slide.speakerNotes.textFrame.setText(`${body}\n\n[Sources]\n- Local project: ${root}/README.md and relevant Swift/relay implementation files.\n${extra}[/Sources]`);
}

// Slides 1 and 2 intentionally remain untouched.

// Slide 3 — training gap
{
  const slide = deck.slides.getItem(2);
  title(slide, "The training gap", "Live exercises are essential—but difficult to repeat");
  addText(slide, "problem-lead", "Mass-casualty readiness depends on decisions made under pressure: survey the scene, identify hazards, prioritise casualties, coordinate roles, and reassess.", { left: 108, top: 286, width: 720, height: 150 }, {
    fontSize: 29, color: C.white, verticalAlignment: "top"
  });
  const items = [
    ["COSTLY TO STAGE", "Space, actors, equipment, instructors, and reset time."],
    ["HARD TO REPEAT", "Every live run varies, making deliberate practice difficult."],
    ["DIFFICULT TO MEASURE", "A final score rarely explains what the learner saw or missed."]
  ];
  items.forEach(([head, body], i) => {
    const y = 492 + i * 145;
    addRule(slide, `problem-rule-${i}`, { left: 108, top: y + 5, width: 10, height: 95 }, i === 2 ? C.cyan : C.blue);
    addText(slide, `problem-head-${i}`, head, { left: 146, top: y, width: 580, height: 34 }, { fontSize: 21, bold: true, color: C.cyan, typeface: "Aileron Bold" });
    addText(slide, `problem-body-${i}`, body, { left: 146, top: y + 38, width: 620, height: 72 }, { fontSize: 22, color: C.muted, verticalAlignment: "top" });
  });
  const bytes = await fs.readFile(trainingPhoto);
  slide.images.add({
    blob: bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
    contentType: "image/png",
    alt: "First responder mass-casualty training exercise with casualty mannequins",
    fit: "cover",
    position: { left: 910, top: 300, width: 850, height: 610 },
    geometry: "roundRect",
    borderRadius: "rounded-2xl"
  });
  addText(slide, "photo-caption", "LIVE TRAINING EXERCISE", { left: 935, top: 835, width: 360, height: 38 }, { fontSize: 17, bold: true, color: C.white, typeface: "Aileron Bold" });
  footer(slide, 3);
  setNotes(slide, "This slide frames the operational training problem without claiming that spatial simulation replaces live exercises.", `- User-supplied training photograph: ${trainingPhoto}.\n`);
}

// Slide 4 — product experience
{
  const slide = deck.slides.getItem(3);
  title(slide, "The product", "TriageXR turns a safe room into a dynamic incident");
  addText(slide, "product-lead", "A native Apple Vision Pro experience trains the decision loop—not physical medical procedures.", { left: 108, top: 255, width: 1320, height: 62 }, { fontSize: 26, color: C.muted });

  // Connectors first, behind nodes.
  addRule(slide, "flow-line", { left: 250, top: 484, width: 1415, height: 6 }, C.line);
  const steps = [
    ["01", "SURVEY", "Turn through four spatial sectors and identify the fuel hazard."],
    ["02", "ASSESS", "Reach to 3D targets; hand tracking verifies sustained checks."],
    ["03", "TRIAGE", "Tag P1, P2, P3, or Expectant from revealed evidence."],
    ["04", "REASSESS", "Respond when casualty condition and the correct priority change."],
    ["05", "DEBRIEF", "Replay the cue, actor, consequence, and next best action."]
  ];
  steps.forEach(([num, head, body], i) => {
    const x = 108 + i * 350;
    addDot(slide, `flow-dot-${i}`, x + 64, 476, i === 4 ? C.green : C.cyan);
    addText(slide, `flow-num-${i}`, num, { left: x, top: 350, width: 150, height: 55 }, { fontSize: 42, bold: true, color: C.cyan, typeface: "Aileron Bold" });
    addText(slide, `flow-head-${i}`, head, { left: x, top: 415, width: 260, height: 40 }, { fontSize: 23, bold: true, color: C.white, typeface: "Aileron Bold" });
    addText(slide, `flow-body-${i}`, body, { left: x, top: 535, width: 285, height: 170 }, { fontSize: 21, color: C.muted, verticalAlignment: "top" });
  });
  addBox(slide, "demo-band", { left: 108, top: 765, width: 1650, height: 145 }, C.panel2, C.line, "rounded-2xl");
  addText(slide, "demo-band-label", "DEMO MOMENT", { left: 150, top: 793, width: 260, height: 32 }, { fontSize: 19, bold: true, color: C.cyan, typeface: "Aileron Bold" });
  addText(slide, "demo-band-copy", "Jordan deteriorates on a meaningful clock while sustained simulated CPR coverage pauses the decline—forcing the team to notice, communicate, and act.", { left: 150, top: 832, width: 1530, height: 58 }, { fontSize: 24, color: C.white });
  footer(slide, 4);
  setNotes(slide, "The experience flow is implemented in the briefing window, immersive space, spatial assessment coordinator, incident engine, and after-action review.");
}

// Slide 5 — dynamic casualty
{
  const slide = deck.slides.getItem(4);
  title(slide, "Dynamic scenario", "A casualty can change—and the learner must notice");
  addText(slide, "timeline-lead", "Jordan begins in untreated cardiac arrest. The evidence evolves with elapsed scenario time and sustained team response.", { left: 108, top: 255, width: 1500, height: 62 }, { fontSize: 26, color: C.muted });

  addRule(slide, "timeline-line", { left: 205, top: 515, width: 1500, height: 8 }, C.line);
  const points = [
    [220, C.cyan, "0 MIN", "Recognise", "Unresponsive, not breathing normally, no palpable pulse."],
    [700, C.amber, "6 MIN", "Risk escalates", "Visible deterioration makes reassessment urgent."],
    [1180, C.red, "10 MIN", "Outcome changes", "Without effective team response, the simulation reaches a fatal outcome."],
    [1590, C.green, "ACTION", "Team intervention", "Sustained simulated CPR coverage pauses deterioration and becomes replay evidence."]
  ];
  points.forEach(([x, color, time, head, body], i) => {
    addDot(slide, `timeline-dot-${i}`, x, 508, color);
    addText(slide, `timeline-time-${i}`, time, { left: x - 30, top: 405, width: 220, height: 42 }, { fontSize: 22, bold: true, color, typeface: "Aileron Bold" });
    addText(slide, `timeline-head-${i}`, head, { left: x - 30, top: 570, width: 275, height: 42 }, { fontSize: 25, bold: true, color: C.white, typeface: "Aileron Bold" });
    addText(slide, `timeline-body-${i}`, body, { left: x - 30, top: 625, width: i === 3 ? 255 : 330, height: 140 }, { fontSize: 21, color: C.muted, verticalAlignment: "top" });
  });
  addBox(slide, "timeline-callout", { left: 108, top: 825, width: 1650, height: 105 }, C.panel, C.line, "rounded-xl");
  addText(slide, "timeline-callout-copy", "The learning objective is not memorising a label. It is seeing new evidence, updating the shared picture, and changing the decision.", { left: 150, top: 846, width: 1560, height: 65 }, { fontSize: 25, bold: true, color: C.white, typeface: "Aileron Bold" });
  footer(slide, 5);
  setNotes(slide, "The 6-minute neurological-risk and 10-minute simulation-outcome thresholds are scenario rules in the repository. They are used for training logic, not presented as a general medical protocol.");
}

// Slide 6 — architecture
{
  const slide = deck.slides.getItem(5);
  title(slide, "Technical design", "Spatial, shared, and explainable by design");
  addText(slide, "architecture-lead", "Three connected systems turn immersive interaction into reliable training evidence.", { left: 108, top: 255, width: 1300, height: 62 }, { fontSize: 26, color: C.muted });

  // Relationship line first.
  addRule(slide, "architecture-spine", { left: 365, top: 496, width: 1185, height: 6 }, C.line);
  const layers = [
    [108, "01", "SPATIAL INPUT", "RealityKit scene + ARKit hand tracking", "Sector beacons and casualty-specific 3D targets verify what the trainee physically inspected."],
    [655, "02", "AUTHORITATIVE STATE", "Deterministic incident engine + SharePlay", "One host owns the clock and scene state; role permissions and targeted commands keep teams aligned."],
    [1202, "03", "GROUNDED REVIEW", "Evidence replay + secure AI relay", "The score stays deterministic. AI coaching must cite exact replay event IDs or it is rejected."]
  ];
  layers.forEach(([x, num, head, sub, body], i) => {
    addBox(slide, `architecture-box-${i}`, { left: x, top: 365, width: 510, height: 430 }, "none", C.line, "rounded-2xl");
    addText(slide, `architecture-num-${i}`, num, { left: x + 38, top: 395, width: 100, height: 60 }, { fontSize: 42, bold: true, color: C.cyan, typeface: "Aileron Bold" });
    addText(slide, `architecture-head-${i}`, head, { left: x + 38, top: 470, width: 420, height: 50 }, { fontSize: 25, bold: true, color: C.white, typeface: "Aileron Bold" });
    addText(slide, `architecture-sub-${i}`, sub, { left: x + 38, top: 535, width: 420, height: 72 }, { fontSize: 22, bold: true, color: C.cyan, typeface: "Aileron Bold", verticalAlignment: "top" });
    addText(slide, `architecture-body-${i}`, body, { left: x + 38, top: 625, width: 420, height: 130 }, { fontSize: 21, color: C.muted, verticalAlignment: "top" });
  });
  addText(slide, "architecture-footer", "Works offline with deterministic local coaching; the optional AI relay adds grounded narrative without becoming a single point of failure.", { left: 108, top: 840, width: 1650, height: 70 }, { fontSize: 24, color: C.white, bold: true, typeface: "Aileron Bold" });
  footer(slide, 6);
  setNotes(slide, "Architecture is grounded in SpatialAssessmentCoordinator.swift, IncidentCollaboration.swift, Core/TriageDomain.swift, AICoachService.swift, and relay/src/worker.js.");
}

// Slide 7 — differentiation
{
  const slide = deck.slides.getItem(6);
  title(slide, "Why TriageXR", "We measure how teams think—not just what they clicked");
  const differentiators = [
    [108, 320, "VERIFIED ACTION", "Findings unlock only after a sustained pose at the correct spatial target."],
    [975, 320, "TEAM COORDINATION", "Incident commander, triage, airway, and instructor roles have explicit responsibilities and permissions."],
    [108, 650, "CAUSAL REPLAY", "Each material action preserves the visible cue, responsible role, consequence, and reconstructed scene."],
    [975, 650, "SAFE AI", "Coaching is grounded in verified event IDs and cannot alter the deterministic 100-point score."]
  ];
  differentiators.forEach(([x, y, head, body], i) => {
    addRule(slide, `diff-rule-${i}`, { left: x, top: y, width: 10, height: 215 }, i % 2 === 0 ? C.cyan : C.blue);
    addText(slide, `diff-head-${i}`, head, { left: x + 40, top: y - 4, width: 710, height: 48 }, { fontSize: 26, bold: true, color: C.cyan, typeface: "Aileron Bold" });
    addText(slide, `diff-body-${i}`, body, { left: x + 40, top: y + 58, width: 690, height: 140 }, { fontSize: 25, color: C.white, verticalAlignment: "top" });
  });
  footer(slide, 7);
  setNotes(slide, "Differentiators are implemented capabilities. The deck does not claim improved clinical outcomes or replacement of certified practical training.");
}

// Slide 8 — prototype proof
{
  const slide = deck.slides.getItem(7);
  title(slide, "Working prototype", "The complete training loop already runs end to end");
  addText(slide, "proof-lead", "Built natively for visionOS, with deterministic tests and a stage-ready simulator path.", { left: 108, top: 255, width: 1350, height: 62 }, { fontSize: 26, color: C.muted });
  const metrics = [
    ["4", "spatial sectors", "must be inspected before the survey is complete"],
    ["3", "casualties", "with distinct findings and changing evidence"],
    ["5", "score domains", "Safety, Assessment, Triage, Treatment, Communication"],
    ["100", "points", "deterministic and separated from AI-written coaching"]
  ];
  metrics.forEach(([value, label, body], i) => {
    const x = 108 + i * 420;
    addText(slide, `metric-value-${i}`, value, { left: x, top: 350, width: 330, height: 135 }, { fontSize: value === "100" ? 86 : 100, bold: true, color: C.cyan, typeface: "Aileron Bold", verticalAlignment: "bottom" });
    addText(slide, `metric-label-${i}`, label.toUpperCase(), { left: x, top: 500, width: 330, height: 40 }, { fontSize: 21, bold: true, color: C.white, typeface: "Aileron Bold" });
    addText(slide, `metric-body-${i}`, body, { left: x, top: 555, width: 335, height: 100 }, { fontSize: 20, color: C.muted, verticalAlignment: "top" });
  });
  addBox(slide, "proof-band", { left: 108, top: 720, width: 1650, height: 205 }, C.panel2, C.line, "rounded-2xl");
  addText(slide, "proof-band-title", "DEMO IN 75 SECONDS", { left: 150, top: 752, width: 420, height: 45 }, { fontSize: 24, bold: true, color: C.cyan, typeface: "Aileron Bold" });
  addText(slide, "proof-band-copy", "Survey → assess → coordinate → watch Jordan change → finish → replay the exact decision trail. Demo 8× compresses scenario deterioration while keeping the responder hold interaction in real time.", { left: 150, top: 812, width: 1520, height: 85 }, { fontSize: 25, color: C.white, verticalAlignment: "top" });
  footer(slide, 8);
  setNotes(slide, "The 75-second stage duration refers to the repository's Demo 8× timing, where the ten-minute scenario threshold arrives after 75 real seconds. It is a demo configuration, not a product-performance claim.");
}

// Slide 9 — close
{
  const slide = deck.slides.getItem(8);
  const inheritedTitle = slide.shapes.items.find((shape) => shape.text?.trim?.() === "Big Thanks!") ?? slide.shapes.items[1];
  inheritedTitle.delete();
  addText(slide, "closing-headline", "Ready to train?", { left: 108, top: 515, width: 1420, height: 245 }, { fontSize: 112, color: C.white, bold: true, typeface: "Aileron Bold", verticalAlignment: "middle", autoFit: "shrinkText" });
  addText(slide, "closing-ask", "Help us validate the scenario, decision logic, and after-action review with first-responder instructors.", { left: 108, top: 800, width: 1310, height: 105 }, { fontSize: 28, color: C.white, bold: true, typeface: "Aileron Bold", verticalAlignment: "top" });
  addText(slide, "closing-team", "WEISHUO   •   GUAN   •   SHREERAJ", { left: 108, top: 955, width: 800, height: 40 }, { fontSize: 18, color: C.cyan, bold: true, typeface: "Aileron Bold" });
  setNotes(slide, "Closing ask: secure domain-expert validation before expanding scenarios or deployment scope.");
}

await fs.mkdir(`${work}/final-render`, { recursive: true });
for (const [index, slide] of deck.slides.items.entries()) {
  const stem = `slide-${String(index + 1).padStart(2, "0")}`;
  const png = await deck.export({ slide, format: "png", scale: 1 });
  await fs.writeFile(`${work}/final-render/${stem}.png`, new Uint8Array(await png.arrayBuffer()));
  const layout = await slide.export({ format: "layout" });
  await fs.writeFile(`${work}/final-render/${stem}.layout.json`, await layout.text());
}
const pptx = await PresentationFile.exportPptx(deck);
await pptx.save(output);
console.log(output);
