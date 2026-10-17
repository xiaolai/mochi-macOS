import Foundation

/// Files the app ships in its own Resources folder, where scripts/build-app.sh copies everything in
/// Sources/MochiApp/Resources. They are not a SwiftPM resource bundle: on some toolchains the lookup SwiftPM generates
/// for one falls back to the absolute build folder it was compiled in, so an app works where it was built and fails
/// everywhere else.
enum AppResources {
    static func url(_ name: String, _ ext: String) -> URL? { Bundle.main.url(forResource: name, withExtension: ext) }
}
