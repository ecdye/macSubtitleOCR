import Foundation

enum TestFilePaths: CaseIterable {
    case sup
    case sub
    case mkv

    var path: String {
        switch self {
        case .sup:
            return Bundle.module.url(forResource: "sintel.sup", withExtension: nil)!.path
        case .sub:
            return Bundle.module.url(forResource: "sintel.sub", withExtension: nil)!.path
        case .mkv:
            return Bundle.module.url(forResource: "sintel.mkv", withExtension: nil)!.path
        }
    }
}
