//
//  DownloadCommand.swift
//  SwiftyPoeditor
//
//  Created by Oleksandr Vitruk on 10/4/19.
//

import Foundation
import ConsoleKit

enum DownloadCommandError: Error, LocalizedError {
    case settingsIncorrect
    
    var errorDescription: String? {
        switch self {
        case .settingsIncorrect:
            return "Entered settings are incorrect. Aborting execution"
        }
    }
}

class DownloadCommand: Command, PrettyOutput {
    
    // MARK: - Declarations
    
    /// describes allowed params with their description in current command
    struct Signature: CommandSignature {
        @Option(name: "token", short: "t", help: "POEditor API token")
        var token: String?
        @Option(name: "id", short: "i", help: "POEditor project id")
        var id: String?
        @Option(name: "language", short: "l", help: "POEditor language code for the localization that should be exported and downloaded. Default value is \(Constants.Defaults.language)")
        var language: String?
        @Option(name: "destination", short: "d", help: "Destination file path, where downloaded localization should be saved")
        var destination: String?
        @Option(name: "export-type", short: "e", help: "In which format localization should be exported from POEditor. Default value s \(Constants.Defaults.exportType.rawValue)")
        var exportType: String?
        
        @Flag(name: "yes", short: "y", help: "Automatically say \"yes\" in every y/n question. E.g for the parsed settings validation")
        var yesForAll: Bool
        
        @Flag(name: "short-output", short: "s", help: "Disables printing unnecessary information and disables colored output")
        var shortOutput: Bool
        
        init() {}
    }
    
    // MARK: - Private properties
    
    private var poeditorClient: Poeditor? // POEditor API client
    private var fileManager: LocalizationsFileManager? // FileManager
    
    // MARK: - Public properties
    
    var help: String {
        "This command will export and download specified language as *.strings from POEditor service."
    }
    
    var currentLoadingBar: ActivityIndicator<LoadingBar>? // console activity indicator
    var shortOutput: Bool = false
    
    // MARK: - Command protocol implementation
    
    /// execute command
    /// - Parameter context: console context
    /// - Parameter signature: signature that was received from console input
    func run(using context: CommandContext, signature: Signature) throws {
        // compose settings object from console input
        let settings = self.parseInput(context: context, signature: signature)
        // prints current settings in order to check them
        printSettings(settings: settings, context: context)
        
        do {
            // validate settings
            try validateSettings(settings: settings, context: context, signature: signature)
            // request localization download URL via POEditor API client
            let downloadURLPath = try requestLocalizationDownloadURL(with: settings, context: context)
            // downloads localization file data form requested URL
            let fileData = try downloadLocalization(with: settings, downloadURLPath: downloadURLPath, context: context)
            // writes downloaded data to destination file
            try writeDataToFile(with: settings, data: fileData, context: context)
        } catch {
            // show fail result in console
            currentLoadingBar?.fail()
            // redirect error to top level for further handling
            throw error
        }
    }
    
    // MARK: - Private methods
    
    /// parse input to settings struct
    /// if some required params not provided, ask them in console
    /// - Parameter context: current console context
    /// - Parameter signature: received signature
    private func parseInput(context: CommandContext, signature: Signature) -> DownloadSettings {
        self.shortOutput = signature.shortOutput
        
        let errorStyle: ConsoleStyle = shortOutput ? .plain : .error
        
        var token: String
        // use provided token or ask it
        if let argToken = signature.token {
            token = argToken
        } else {
            token = context.console.ask("You should provide your API token for the POEditor.\nEnter it now or use command (--help for details)?".consoleText(errorStyle))
        }
        
        var id: String
        // use provided project id or ask it
        if let argID = signature.id {
            id = argID
        } else {
            id = context.console.ask("You should provide your POEditor project ID.\nEnter it now or use command (--help for details)?".consoleText(errorStyle))
        }
        
        // use provided language or use default (optional param)
        var language: String
        if let argLanguage: String = signature.language {
            language = argLanguage
        } else {
            if signature.yesForAll == true {
                language = Constants.Defaults.language
            } else {
                let question: ConsoleText = .init(stringLiteral: "Use \(Constants.Defaults.language) as requested localization language?")
                let decision = context.console.confirm(question)
                
                if decision == true {
                    language = Constants.Defaults.language
                } else {
                    language = context.console.ask("You should provide language code of localization that should be downloaded.\nEnter it now or use command (--help for details)?".consoleText(errorStyle))
                }
            }
        }
        
        var destination: String
        // use provided path or ask it
        if let argDestination = signature.destination {
            destination = argDestination
        } else {
            destination = context.console.ask("You should provide destination file path where downloaded localization should be saved.\nEnter it now or use command (--help for details)?".consoleText(errorStyle))
        }
        
        var exportType: PoeditorExportType
        // use provided export type or ask it
        if let argExportType = signature.exportType {
            exportType = PoeditorExportType(rawValue: argExportType) ?? Constants.Defaults.exportType
        } else {
            if signature.yesForAll == true {
                exportType = Constants.Defaults.exportType
            } else {
                let title: ConsoleText = .init(stringLiteral: "Please select export format:")
                let cases = PoeditorExportType.allCases.map { $0.rawValue }
                let decision = context.console.choose(title, from: cases)
                
                if let type = PoeditorExportType(rawValue: decision) {
                    exportType = type
                } else {
                    printToConsole(context: context, string: "Unable to parse selected export type. \( Constants.Defaults.exportType.rawValue) will be used.", style: .warning)
                    exportType = Constants.Defaults.exportType
                }
            }
        }
        
        let poeditorSettings: PoeditorSettings = PoeditorSettings(token: token,
                                                                  id: id,
                                                                  language: language)
        let fileManagerSettings: FileManagerSettings = FileManagerSettings(destinationPath: destination)
        
        return DownloadSettings(poeditorSettings: poeditorSettings,
                                fileManagerSettings: fileManagerSettings,
                                type: exportType)
    }
    
    /// print to user parsed settings
    /// - Parameter settings: parsed settings
    /// - Parameter context: current console context
    private func printSettings(settings: DownloadSettings, context: CommandContext) {
        let redStyle: ConsoleStyle = shortOutput ? .plain : .init(color: .red)
        let brightMagentaStyle: ConsoleStyle = shortOutput ? .plain : .init(color: .red)
        
        let rawToken = settings.poeditorSettings.token
        let tokenRange = rawToken.startIndex..<rawToken.index(rawToken.endIndex, offsetBy: -3)
        let tokenStar = rawToken[tokenRange].map { _ in "*" }.joined(separator: "")
        let token: String = rawToken.replacingCharacters(in: tokenRange, with: tokenStar)
        
        let rawProjectID = settings.poeditorSettings.id
        let projectIDRange = rawProjectID.startIndex..<rawProjectID.index(rawProjectID.endIndex, offsetBy: -3)
        let projectStar = rawProjectID[projectIDRange].map { _ in "*" }.joined(separator: "")
        let projectID: String = rawProjectID.replacingCharacters(in: projectIDRange, with: projectStar)
        
        let settingsText: ConsoleText = [ConsoleTextFragment(string: "\n", style: redStyle),
                                         ConsoleTextFragment(string: "Current settings that will be used:\n",
                                                             style: brightMagentaStyle),
                                         ConsoleTextFragment(string: "token: \(token)\n",
                                            style: brightMagentaStyle),
                                         ConsoleTextFragment(string: "id: \(projectID)\n",
                                            style: brightMagentaStyle),
                                         ConsoleTextFragment(string: "language: \(settings.poeditorSettings.language)\n",
                                            style: brightMagentaStyle),
                                         ConsoleTextFragment(string: "destination: \(settings.fileManagerSettings.destinationPath)\n",
                                            style: brightMagentaStyle),
                                         ConsoleTextFragment(string: "export type: \(settings.type.rawValue)\n",
                                            style: brightMagentaStyle)]
        
        context.console.output(settingsText)
    }
    
    /// validate entered settings
    /// - Parameter settings: parsed settings
    /// - Parameter context: current console context
    /// - Parameter signature: received signature
    private func validateSettings(settings: DownloadSettings, context: CommandContext, signature: Signature) throws {
        guard signature.yesForAll == false else {
            return
        }
        
        let redStyle: ConsoleStyle = shortOutput ? .plain : .init(color: .red)
        let text = ConsoleText(arrayLiteral: ConsoleTextFragment(string: "Please check all settings carefully. Everything is correct?",
                                                                 style: redStyle))
        let result = context.console.confirm(text)
        
        guard result == true else {
            throw UploadCommandError.settingsIncorrect
        }
    }
    
    /// request on POEditor API download URL for specified language
    /// - Parameter settings: parsed settings
    /// - Parameter context: current console context
    private func requestLocalizationDownloadURL(with settings: DownloadSettings, context: CommandContext) throws -> String {
        createLoadingBar(context: context, title: "Requesting \(settings.poeditorSettings.language) localization download url...")
        currentLoadingBar?.start()
        
        let client = getOrCreatePOEditorClient(settings: settings.poeditorSettings)
        let result = try client.requestExportLocalization(exportType: settings.type).wait()
        
        currentLoadingBar?.succeed()
        
        printToConsole(context: context, string: "Download url is \(result.urlPath)", style: .info)
        
        return result.urlPath
    }
    
    /// try to download localization with provided settings and url
    /// - Parameter settings: parsed settings
    /// - Parameter context: current console settings
    private func downloadLocalization(with settings: DownloadSettings, downloadURLPath: String, context: CommandContext) throws -> Data {
        createLoadingBar(context: context, title: "Downloading \(settings.poeditorSettings.language) localization...")
        currentLoadingBar?.start()
        
        let client = getOrCreatePOEditorClient(settings: settings.poeditorSettings)
        let result = try client.downloadLocalization(downloadPath: downloadURLPath).wait()
        
        currentLoadingBar?.succeed()
        
        printToConsole(context: context,
                       string: "Download \(settings.poeditorSettings.language) localization success",
            style: .info)
        
        return result
    }
    
    /// write data to destination file
    /// - Parameter settings: parsed settings
    /// - Parameter data: downloaded data
    /// - Parameter context: current console settings
    private func writeDataToFile(with settings: DownloadSettings, data: Data, context: CommandContext) throws {
        createLoadingBar(context: context, title: "Writing data to file at path \(settings.fileManagerSettings.destinationPath)...")
        currentLoadingBar?.start()
        
        let manager = getOrCreateFileManager(settings: settings.fileManagerSettings)
        let result = try manager.writeData(data: data)
        
        currentLoadingBar?.succeed()
        
        printToConsole(context: context,
                       string: "File successfully written at path \(result.path)",
            style: .info)
    }
    
    /// get or create new POEditor API client
    /// - Parameter settings: parsed settings
    private func getOrCreatePOEditorClient(settings: PoeditorSettings) -> Poeditor {
        if let client = self.poeditorClient {
            // returns existing client
            return client
        }
        // create and save new client
        let client = Poeditor(settings: settings)
        self.poeditorClient = client
        
        return client
    }
    
    /// get or create new  file manager
    /// - Parameter settings: parsed settings
    private func getOrCreateFileManager(settings: FileManagerSettings) -> LocalizationsFileManager {
        if let manager = self.fileManager {
            // returns existing client
            return manager
        }
        // create and save new client
        let manager = LocalizationsFileManager(settings: settings)
        self.fileManager = manager
        
        return manager
    }
}
