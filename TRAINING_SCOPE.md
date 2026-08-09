# Training scope and validation

TriageXR is a supervised, fictional coordination exercise. It is designed to make scene-awareness and team decisions observable in spatial computing; it is not a clinical protocol, medical device, skills certificate, or replacement for live practical training.

## Intended learning outcomes

At the end of a facilitated run, a learner should be able to:

- complete a deliberate 360° scene scan before patient contact;
- identify and communicate a visible environmental hazard;
- gather scenario findings in a consistent order;
- assign and revise a scenario-specific priority from the evidence presented;
- coordinate continuous simulated treatment coverage across roles; and
- explain decisions using the cues captured in the event replay.

## What the app actually measures

| Outcome | Evidence captured |
| --- | --- |
| Scene scan | Stable, level Vision Pro forward orientation held for 0.8 seconds before adding a view cone to a 12-segment relative heading map |
| Spatial assessment | Tracked hand proximity, required pose, and sustained duration at the current marker |
| Prioritisation | Scenario tag selected after the primary evidence sequence |
| Team coordination | Authorised role, command, shared-state result, communication, and simulated coverage duration |
| Reflection | Deterministic event citations, consequences, and replay state |

The survey evidence demonstrates deliberate head-direction coverage. It does not measure eye gaze, attention, recognition, or comprehension of objects within a segment. Untracked poses, rapid turns, and steep vertical views do not add coverage.

The 100-point score is deterministic and specific to this fictional exercise. AI coaching may summarise verified events, but it cannot change the score or introduce evidence that was not recorded. The exported instructor report identifies the scenario ID and content version used for the run.

## Explicitly out of scope

TriageXR does not assess diagnosis, respiratory rate, pulse accuracy, treatment technique, compression rate, depth, recoil, ventilation, medication, transport destination, or real patient outcomes. It does not claim conformance with START, SALT, or another triage system. Simulator target pinches test workflow only and are labelled simulated evidence.

## Instructor validation before deployment

Before using a build with learners, the responsible educator should:

1. confirm that scenario wording and priorities match the organisation's approved learning objectives;
2. review every casualty finding, deterioration cue, timer, and expected decision;
3. test permissions and handoffs for each SharePlay role;
4. verify survey and hand tracking on the target Vision Pro hardware;
5. confirm the briefing readiness panel reports the expected device, assets, coach, and incident mode;
6. brief learners on the simulation boundary and local safety process; and
7. facilitate a debrief that distinguishes scenario mechanics from real clinical practice and retain the exported report only under the organisation's approved data policy.

Any future claim that TriageXR teaches a named protocol requires a separate content review, protocol-version record, educator sign-off, and validation study. Until then, the app should continue to describe itself as coordination training.
