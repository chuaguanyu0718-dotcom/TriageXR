import SwiftUI
import RealityKit
import UIKit

@main
struct TriageXRApp: App {
    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
        }

        ImmersiveSpace(id: "TriageScene") {
            ImmersiveTriageView()
        }
    }
}

struct ContentView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    @State private var immersiveSpaceIsOpen = false
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Label("TriageXR", systemImage: "cross.case.fill")
                .font(.largeTitle.bold())
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 8) {
                Text("Mass-Casualty Triage Training")
                    .font(.title.bold())

                Text(
                    immersiveSpaceIsOpen
                    ? "The spatial training scene is active."
                    : "Assess casualties, assign priorities and respond when a patient's condition changes."
                )
                .font(.title3)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                PriorityCard(
                    title: "P1",
                    subtitle: "Immediate",
                    colour: .red
                )

                PriorityCard(
                    title: "P2",
                    subtitle: "Urgent",
                    colour: .orange
                )

                PriorityCard(
                    title: "P3",
                    subtitle: "Delayed",
                    colour: .green
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("3 simulated casualties", systemImage: "person.3.fill")
                Label("1 dynamic deterioration event", systemImage: "waveform.path.ecg")
                Label("Decisions recorded for debrief", systemImage: "checklist")
            }
            .font(.headline)

            if let statusMessage {
                Text(statusMessage)
                    .foregroundStyle(.orange)
            }

            Spacer()

            HStack {
                Text("Training prototype — follow official operational protocols.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()

                if immersiveSpaceIsOpen {
                    Button {
                        Task {
                            await dismissImmersiveSpace()
                            immersiveSpaceIsOpen = false
                        }
                    } label: {
                        Label("End Scenario", systemImage: "xmark")
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button {
                        Task {
                            statusMessage = nil

                            let result = await openImmersiveSpace(
                                id: "TriageScene"
                            )

                            switch result {
                            case .opened:
                                immersiveSpaceIsOpen = true

                            case .userCancelled:
                                statusMessage = "Scenario opening was cancelled."

                            case .error:
                                statusMessage = "The immersive scene could not be opened."

                            @unknown default:
                                statusMessage = "An unexpected error occurred."
                            }
                        }
                    } label: {
                        Label("Begin Scenario", systemImage: "play.fill")
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .padding(40)
        .frame(minWidth: 700, minHeight: 520)
    }
}

struct PriorityCard: View {
    let title: String
    let subtitle: String
    let colour: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title.bold())

            Text(subtitle)
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            colour.opacity(0.18),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(colour.opacity(0.55), lineWidth: 2)
        }
    }
}

struct ImmersiveTriageView: View {
    var body: some View {
        RealityView { content in
            let sceneRoot = Entity()

            let floorMaterial = SimpleMaterial(
                color: UIColor(white: 0.25, alpha: 0.55),
                isMetallic: false
            )

            let floor = ModelEntity(
                mesh: .generatePlane(width: 6, depth: 6),
                materials: [floorMaterial]
            )

            floor.position = [0, -1.35, -2.5]
            sceneRoot.addChild(floor)

            let casualtyA = makeCasualty(
                locatorColour: .systemBlue,
                position: [-1.25, -1.1, -2.2]
            )

            let casualtyB = makeCasualty(
                locatorColour: .systemPurple,
                position: [0, -1.1, -2.8]
            )

            let casualtyC = makeCasualty(
                locatorColour: .systemTeal,
                position: [1.25, -1.1, -2.2]
            )

            sceneRoot.addChild(casualtyA)
            sceneRoot.addChild(casualtyB)
            sceneRoot.addChild(casualtyC)

            content.add(sceneRoot)
        }
    }

    private func makeCasualty(
        locatorColour: UIColor,
        position: SIMD3<Float>
    ) -> Entity {
        let casualty = Entity()
        casualty.position = position

        let uniformMaterial = SimpleMaterial(
            color: .systemIndigo,
            isMetallic: false
        )

        let skinMaterial = SimpleMaterial(
            color: UIColor(
                red: 0.72,
                green: 0.50,
                blue: 0.38,
                alpha: 1
            ),
            isMetallic: false
        )

        let locatorMaterial = SimpleMaterial(
            color: locatorColour,
            isMetallic: false
        )

        let torso = ModelEntity(
            mesh: .generateCylinder(height: 0.9, radius: 0.22),
            materials: [uniformMaterial]
        )
        torso.orientation = simd_quatf(
            angle: .pi / 2,
            axis: [0, 0, 1]
        )

        let head = ModelEntity(
            mesh: .generateSphere(radius: 0.23),
            materials: [skinMaterial]
        )
        head.position = [-0.68, 0, 0]

        let leftLeg = ModelEntity(
            mesh: .generateCylinder(height: 0.65, radius: 0.09),
            materials: [uniformMaterial]
        )
        leftLeg.orientation = torso.orientation
        leftLeg.position = [0.68, 0, -0.11]

        let rightLeg = ModelEntity(
            mesh: .generateCylinder(height: 0.65, radius: 0.09),
            materials: [uniformMaterial]
        )
        rightLeg.orientation = torso.orientation
        rightLeg.position = [0.68, 0, 0.11]

        let locatorPole = ModelEntity(
            mesh: .generateBox(
                width: 0.025,
                height: 0.55,
                depth: 0.025
            ),
            materials: [locatorMaterial]
        )
        locatorPole.position = [0, 0.42, 0]

        let locator = ModelEntity(
            mesh: .generateSphere(radius: 0.12),
            materials: [locatorMaterial]
        )
        locator.position = [0, 0.72, 0]

        casualty.addChild(torso)
        casualty.addChild(head)
        casualty.addChild(leftLeg)
        casualty.addChild(rightLeg)
        casualty.addChild(locatorPole)
        casualty.addChild(locator)

        return casualty
    }
}

#Preview {
    ContentView()
}
