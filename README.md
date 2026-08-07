# TriageXR

<<<<<<< HEAD
This is Apple Projectdsss dd
=======
TriageXR is a spatial mass-casualty triage training application for Apple Vision Pro. It places trainees inside an interactive emergency scenario where they assess casualties, assign triage priorities and respond to changing patient conditions.

The project is being developed for **Spatial Hack AI 2026**, addressing the brief:

> How might we train first responders for a mass-casualty incident using spatial computing and AI?

## The Problem

Mass-casualty triage requires responders to make fast, structured decisions under pressure. Conventional classroom instruction, slides and tabletop exercises can explain the process, but they cannot fully reproduce the spatial awareness, time pressure and competing priorities of an incident scene.

TriageXR explores whether spatial computing can provide accessible, repeatable and measurable scenario-based training without requiring a full physical exercise.

## Proposed Experience

A trainee enters a mixed-reality incident scene containing several simulated casualties.

The trainee will:

1. Survey the scene.
2. Select casualties using gaze and pinch.
3. Inspect observable signs and vital information.
4. Assign a triage priority.
5. Respond when a casualty’s condition changes.
6. Complete the scenario and receive a structured debrief.

AI is planned for adaptive casualty dialogue and personalised debrief explanations. Core triage decisions and scoring will remain deterministic and auditable.


## Planned Features

* Gaze-and-pinch casualty selection
* Spatial hover feedback
* Casualty assessment panels
* Observable breathing, circulation and responsiveness information
* P-status assignment
* Timed decision tracking
* Dynamic casualty deterioration
* Deterministic scoring
* Post-scenario performance debrief
* AI-assisted explanations and adaptive dialogue
* Improved human models, animations and environmental assets
* Spatialised audio cues


## Technology

* Swift
* SwiftUI
* RealityKit
* visionOS
* Apple Vision Pro Simulator
* Xcode 27 beta


## Getting Started

### Requirements

* A compatible Mac
* Xcode 27 beta 4
* visionOS 27 beta 4
* Apple Vision Pro simulator
* Git

All contributors should use matching Xcode and visionOS beta versions to reduce project and API compatibility issues.

### Installation

Clone the repository:

```bash
git clone https://github.com/chuaguanyu0718-dotcom/TriageXR.git
cd TriageXR
```

Open the Xcode project:

```bash
open TriageXR.xcodeproj
```

In Xcode:

1. Select the `TriageXR` scheme.
2. Select an Apple Vision Pro simulator.
3. Build and run the application.
4. Select **Begin Scenario** to open the immersive scene.
5. Select **End Scenario** to close it.

## Collaboration Workflow

The `main` branch should always contain a working version of the application.

Contributors should:

1. Pull the latest `main` branch.
2. Create a dedicated feature branch.
3. Make focused changes.
4. Build and test before committing.
5. Push the branch.
6. Open a pull request.
7. Merge only after review.


## Medical and Operational Disclaimer

TriageXR is an educational prototype and is not a certified medical device, operational decision-support system or replacement for accredited training.

The current casualty data, priority labels and scenario logic must be reviewed against authoritative medical and operational protocols before the application is used for formal training or real-world instruction.

## Project Status

TriageXR is under active development. The current release demonstrates the foundational spatial experience rather than a complete training system.
>>>>>>> f9f04fe9c4a87229ca5c0d5d34f3a8350c1716e7
