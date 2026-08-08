# TriageXR

TriageXR is a visionOS mass-casualty incident training prototype for Apple Vision Pro.
It develops scene awareness, prioritisation, reassessment, and communication; it does not teach physical medical procedures or replace live exercises.

## Run

1. Open `TriageXR.xcodeproj` in Xcode.
2. Select the `TriageXR` scheme.
3. Choose Apple Vision Pro Simulator or a signed Vision Pro device.
4. Press Run.

## Scenario flow

The experience follows the product storyboard:

1. **Briefing:** Read the scenario, role, dispatch information, and objectives in a Window.
2. **Entry:** Choose Enter Incident.
   The briefing Window closes and the mixed Immersive Space opens.
3. **Scene survey:** Three casualties, two vehicles, and one fuel hazard appear around the trainee.
   Complete the 360° survey from the compact incident panel.
4. **Casualty selection:** Look at a casualty and pinch.
5. **Assessment:** A compact information card moves beside the selected casualty.
   Reach to the highlighted 3D assessment target and hold the required hand pose so ARKit can verify the response, breathing, perfusion, and injury checks.
6. **Tagging:** Choose P1, P2, P3, or Expectant.
   A matching coloured tag attaches to the casualty.
7. **Condition change:** Jordan's untreated cardiac arrest progresses on a clinically meaningful clock, while sustained CPR pauses deterioration.
   Reassess and retag Jordan as the evidence changes.
8. **Debrief:** Choose Finish & Debrief.
   The Immersive Space closes and the Window reopens with metrics, personalised coaching, and an evidence replay explaining why each decision succeeded or failed.

The yellow fuel spill is interactive.
After identifying it, use the incident panel to report it and request resources.

## Extraordinary demo features

- **Evidence-based replay:** Every material action captures the acting role, visible cues, causal outcome, consequence, and a spatial incident snapshot.
  Failed and urgent events also include a concrete next best action.
  The after-action review provides a total score (max 100 points) broken down by Safety, Assessment, Triage, Treatment, and Communication, plus personalised coaching priorities, outcome counts, precise step controls, an interactive timeline, and animated top-down reconstruction instead of a plain event log.
- **Verified spatial assessment:** On Vision Pro, ARKit hand tracking verifies that the trainee reaches and sustains the correct pose at a casualty's highlighted 3D target.
  The breathing check verifies an open hand from four tracked fingertips, and the perfusion check verifies fingertip pinch distance.
  The Simulator exposes the same assessment sequence through target pinches for repeatable demos.
- **Collaborative incident command:** SharePlay synchronises one host-authoritative incident across participants.
  Incident commander, triage officer, airway responder, and instructor roles have explicit permissions, visible responsibilities, and shared immersive-space placement.
  Each responder navigates casualties independently, while every assessment, tag, and treatment command carries an explicit casualty target to the host.
  Out-of-role attempts are rejected without changing state and become attributed evidence in the debrief.
- **Stage-ready timing:** Demo 8x is the default exercise pace, bringing the six-minute neurological-risk threshold into 45 real seconds and the ten-minute scenario threshold into 75 real seconds.
  CPR quality credit always uses real hold duration, and Realtime remains available from the briefing.

The project includes a small Swift package for deterministic tests of spatial verification, staged scenario timing, role permissions, transport policy, and collaboration message encoding.

Run `swift test` from the repository root to execute those tests.

## Demo runbook

1. On the host Vision Pro, keep the Incident Commander role and choose Start SharePlay before entering the incident.
   Keep the default Demo 8x pace for a short presentation, or select Realtime for an unaccelerated exercise.
2. Have participants join the activity and select Triage Officer, Airway Responder, or Instructor.
   The host owns the incident clock and authoritative state while every role receives the same scene updates.
3. Let the Incident Commander complete the scene survey, identify the fuel spill, report the hazard, and request resources.
4. Let the Triage Officer select a casualty, then reach to each highlighted marker.
   Response and injury checks use fingertip placement, breathing requires a sustained open hand over the chest, and perfusion requires a sustained fingertip pinch at the wrist.
5. Let the Airway Responder maintain the red CPR target for Jordan while the Triage Officer assigns priorities from the verified findings.
6. End the scenario and use the replay control to step through successful, failed, corrected, and system-generated events.
   Each stop shows the responsible role, evidence available at that moment, causal explanation, consequence, next best action when relevant, and reconstructed incident state.

On the visionOS Simulator, pinch each highlighted assessment marker to produce deterministic simulated spatial evidence.
Real hand-pose verification runs only on Vision Pro hardware.

## Roadside environment

The immersive incident uses a performance-conscious hybrid environment:

- An original 360° photographic panorama supplies the distant sky, terrain, trees, utility poles, and roadside context.
- RealityKit geometry supplies the nearby asphalt road, gravel shoulders, grass verges, edge lines, centre markings, guardrail, traffic cones, crash vehicles, hazard, and casualties.
- The panorama is unlit to maintain clear, consistent visibility.
  Nearby geometry uses simple materials and repeated low-poly meshes to keep the scene responsive on Vision Pro.

The initial coach runs locally from the structured event log.
This keeps feedback deterministic and testable; a hosted language model can later rewrite the verified findings without becoming the source of truth.

## 3D assets

The immersive scene includes optimized USDZ derivatives of openly licensed casualty and vehicle models.
See [ASSET_ATTRIBUTION.md](ASSET_ATTRIBUTION.md) for source and license details.
