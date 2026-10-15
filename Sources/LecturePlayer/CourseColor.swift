import SwiftUI
import Core

/// Muted course colours. Courses get one automatically by name order until the user picks one.
enum CourseColor: String, CaseIterable, Identifiable {
    case blue, orange, green, purple, teal, pink, indigo, yellow, red, graphite
    var id: Self { self }
    var title: String {
        switch self {
        case .blue: "蓝色"; case .orange: "橙色"; case .green: "绿色"; case .purple: "紫色"; case .teal: "青色"
        case .pink: "粉色"; case .indigo: "靛蓝"; case .yellow: "黄色"; case .red: "红色"; case .graphite: "石墨"
        }
    }
    /// About 58 % of the system colours' saturation, so thumbnails and dots stay quiet.
    var color: Color {
        let rgb: (Double, Double, Double) = switch self {
        case .blue: (0x3D, 0x84, 0xCC); case .orange: (0xCC, 0x94, 0x3D); case .green: (0x52, 0xAF, 0x69)
        case .purple: (0xB3, 0x78, 0xD1); case .teal: (0x62, 0xB0, 0xBE); case .pink: (0xD5, 0x61, 0x78)
        case .indigo: (0x79, 0x78, 0xC9); case .yellow: (0xCC, 0xB4, 0x3D); case .red: (0xD6, 0x6A, 0x63)
        case .graphite: (0x8E, 0x8E, 0x93)
        }
        return Color(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255)
    }
    static func resolve(_ course: Course?, among courses: [Course]) -> CourseColor {
        guard let course else { return .graphite }
        if course.colorPicked == true, let picked = CourseColor(rawValue: course.color) { return picked }
        let ordered = courses.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let index = ordered.firstIndex { $0.id == course.id } ?? 0
        let automatic: [CourseColor] = [.blue, .orange, .green, .purple, .teal, .pink, .indigo, .yellow, .red]
        return automatic[index % automatic.count]
    }
}

extension AppStore {
    func courseColor(_ id: UUID?) -> CourseColor {
        CourseColor.resolve(library.courses.first { $0.id == id }, among: navigation.index.courses)
    }
    /// Nil returns the course to its automatic colour.
    func setCourseColor(_ id: UUID, _ color: CourseColor?) {
        guard let index = library.courses.firstIndex(where: { $0.id == id }) else { return }
        library.courses[index].color = color?.rawValue ?? "blue"
        library.courses[index].colorPicked = color == nil ? nil : true
        persist()
    }
}

/// Context-menu submenu for choosing a course colour.
struct CourseColorMenu: View {
    let store: AppStore
    let courseID: UUID
    var body: some View {
        Menu("课程颜色") {
            ForEach(CourseColor.allCases) { option in
                Button { store.setCourseColor(courseID, option) } label: {
                    Label(option.title, systemImage: store.courseColor(courseID) == option ? "checkmark.circle.fill" : "circle.fill")
                }.tint(option.color)
            }
            Divider()
            Button("恢复自动配色") { store.setCourseColor(courseID, nil) }
        }
    }
}

/// Round 32-point glass button used for the player's top-bar menus, so their icons share one size and centre.
struct GlassIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName).font(.system(size: 14, weight: .medium))
            .frame(width: 32, height: 32).contentShape(Circle())
    }
}
extension View {
    func glassMenuStyle() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .glassSurface(Circle(), interactive: true)
    }
}

/// Liquid Glass on macOS 26 and later; the closest standard material on macOS 14 and 15.
extension View {
    @ViewBuilder func glassSurface<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}
