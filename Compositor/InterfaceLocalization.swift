import Foundation

enum InterfaceLocalization {
    static func string(_ key: String) -> String {
        let selection = UserDefaults.standard.string(forKey: "interface.language") ?? "zh-Hans"
        let isChinese = selection == "zh-Hans"
            || (selection == "system" && Locale.current.language.languageCode?.identifier == "zh")
        guard isChinese,
              let path = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
}
