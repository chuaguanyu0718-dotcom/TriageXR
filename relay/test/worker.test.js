import assert from "node:assert/strict";
import test from "node:test";

import worker, {
  buildOpenAIRequest,
  extractOutputText,
  validateCoachReport,
  validateCoachRequest,
} from "../src/worker.js";

const eventID = "00000000-0000-0000-0000-000000000001";

function requestFixture() {
  return {
    schemaVersion: 1,
    sessionID: "00000000-0000-0000-0000-000000000099",
    scenario: "Roadside mass-casualty incident simulation",
    scenarioPace: "Demo 8x",
    score: { safety: 20, assessment: 20, triage: 18, treatment: 10, communication: 12 },
    events: [
      {
        id: eventID,
        timestamp: "00:12",
        elapsedSeconds: 12,
        category: "Safety",
        action: "Inspected the fuel hazard",
        actorRole: "Incident Commander",
        outcome: "succeeded",
        rationale: "The hazard was visible before casualty contact.",
        cues: ["Fuel visible beside vehicle"],
        consequence: "The entry route remained controlled.",
        recommendedAction: null,
      },
    ],
  };
}

function reportFixture(reference = eventID) {
  const observation = {
    headline: "Controlled scene entry",
    explanation: "You used the visible fuel cue before approaching casualties.",
    evidenceEventIDs: [reference],
  };
  return {
    schemaVersion: 1,
    summary: "A focused run with a clear scene-safety decision.",
    strongestDecision: observation,
    missedCue: { ...observation, headline: "Review communication" },
    nextDrill: { ...observation, headline: "Verbalise the cue" },
    disclaimer: "model supplied text",
  };
}

test("accepts a bounded, well-formed coaching request", () => {
  assert.equal(validateCoachRequest(requestFixture()).events[0].id, eventID);
});

test("rejects unknown evidence references in a generated report", () => {
  assert.throws(
    () => validateCoachReport(reportFixture("invented-event"), requestFixture()),
    /unknown evidence event ID/,
  );
});

test("normalizes the safety disclaimer after grounding validation", () => {
  const report = validateCoachReport(reportFixture(), requestFixture());
  assert.match(report.disclaimer, /Simulation coaching only/);
  assert.notEqual(report.disclaimer, "model supplied text");
});

test("extracts structured output text from a Responses API envelope", () => {
  const encoded = JSON.stringify(reportFixture());
  const response = {
    output: [{ type: "message", content: [{ type: "output_text", text: encoded }] }],
  };
  assert.equal(extractOutputText(response), encoded);
});

test("uses strict JSON Schema and disables response storage", () => {
  const openAIRequest = buildOpenAIRequest(requestFixture());
  assert.equal(openAIRequest.store, false);
  assert.equal(openAIRequest.text.format.type, "json_schema");
  assert.equal(openAIRequest.text.format.strict, true);
});

test("the endpoint fails closed when the server secret is absent", async () => {
  const response = await worker.fetch(
    new Request("https://relay.example/coach", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(requestFixture()),
    }),
    {},
  );
  assert.equal(response.status, 503);
  assert.equal(response.headers.get("cache-control"), "no-store");
  assert.deepEqual(await response.json(), { error: "Coach relay is not configured" });
});
