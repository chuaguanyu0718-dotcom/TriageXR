# TriageXR

TriageXR is a visionOS mass-casualty incident training prototype for Apple Vision Pro. It develops scene awareness, prioritisation, reassessment, and communication; it does not teach physical medical procedures or replace live exercises.

## Run

1. Open `TriageXR.xcodeproj` in Xcode.
2. Select the `TriageXR` scheme.
3. Choose Apple Vision Pro Simulator or a signed Vision Pro device.
4. Press Run.

## Scenario flow

The experience follows the product storyboard:

1. **Briefing:** Read the scenario, role, dispatch information, and objectives in a Window.
2. **Entry:** Choose Enter Incident. The briefing Window closes and the mixed Immersive Space opens.
3. **Scene survey:** Three casualties, two vehicles, and one fuel hazard appear around the trainee. Complete the 360° survey from the compact incident panel.
4. **Casualty selection:** Look at a casualty and pinch.
5. **Assessment:** A compact information card moves beside the selected casualty. Perform response, breathing, perfusion, and injury checks to reveal findings.
6. **Tagging:** Choose P1, P2, P3, or Expectant. A matching coloured tag attaches to the casualty.
7. **Condition change:** After 75 seconds, Jordan receives a visible red alert and a spoken condition-change announcement. Reassess and retag Jordan.
8. **Debrief:** Choose Finish & Debrief. The Immersive Space closes and the Window reopens with metrics, an event timeline, and personalised coach feedback.

The yellow fuel spill is interactive. After identifying it, use the incident panel to report it and request resources.

## Roadside environment

The immersive incident uses a performance-conscious hybrid environment:

- An original 360° photographic panorama supplies the distant sky, terrain, trees, utility poles, and roadside context.
- RealityKit geometry supplies the nearby asphalt road, gravel shoulders, grass verges, edge lines, centre markings, guardrail, traffic cones, crash vehicles, hazard, and casualties.
- The panorama is unlit to maintain clear, consistent visibility. Nearby geometry uses simple materials and repeated low-poly meshes to keep the scene responsive on Vision Pro.

The initial coach runs locally from the structured event log. This keeps feedback deterministic and testable; a hosted language model can later rewrite the verified findings without becoming the source of truth.

## 3D assets

The immersive scene includes optimized USDZ derivatives of openly licensed casualty and vehicle models.
See [ASSET_ATTRIBUTION.md](ASSET_ATTRIBUTION.md) for source and license details.
