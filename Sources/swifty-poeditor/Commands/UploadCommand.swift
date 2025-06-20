//
//  UploadCommand.swift
//  SwiftyPoeditor
//
//  Created by Oleksandr Vitruk on 10/2/19.
//

import Foundation
import ConsoleKit

enum UploadCommandError: Error, LocalizedError {
    case settingsIncorrect
    
    var errorDescription: String? {
        switch self {
        case .settingsIncorrect:
            return "Entered settings are incorrect. Aborting execution"
        }
    }
}

class UploadCommand: Command, PrettyOutput {
    
    // MARK: - Declarations
    
    /// describes allowed params with their description in current command
    struct Signature: CommandSignature {
        @Option(name: "path", short: "p", help: "Path to the Swift file (e.g I18m.swift) that contains localization enum")
        var path: String?
        @Option(name: "name", short: "n", help: "Custom localization enum name. Default value is \(Constants.Defaults.enumName)")
        var name: String?
        @Option(name: "token", short: "t", help: "POEditor API token")
        var token: String?
        @Option(name: "id", short: "i", help: "POEditor project id")
        var id: String?
        @Option(name: "language", short: "l", help: "POEditor language code as reference value. Default value is \(Constants.Defaults.language)")
        var language: String?
        @Option(name: "lowercased", short: "c", help: "Use lowercased mode generation (all keys components will be lowercased). Default value is \(Constants.Defaults.lowercasedMode.boolValue)")
        var lowercased: Bool?
        @Option(name: "delete-removals", short: "d", help: "Sync removals (this option enable or disable deleting remote terms that where removed locally). Default value is \(Constants.Defaults.deleteRemovals.boolValue)")
        var deleteRemovals: Bool?
        
        @Flag(name: "yes", short: "y", help: "Automatically say \"yes\" in every y/n question. E.g for the parsed settings validation")
        var yesForAll: Bool
        
        @Flag(name: "short-output", short: "s", help: "Disables printing unnecessary information and disables colored output")
        var shortOutput: Bool
        
        init() { }
    }
    
    /// diff result wrapper
    struct TermsDifference {
        let insertions: [String]
        let removals: [String]
    }
    
    
    // MARK: - Private properties
    
    private var poeditorClient: Poeditor? // POEditor API client
    
    // MARK: - Public properties
    
    var help: String {
        "This command will sync POEditor terms. Source terms list generates based on localization enum"
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
            // get local terms
            let localTerms = try parseLocalizationFile(with: settings, context: context)
            // get remote terms
            let remoteTerms = try downloadPoeditorTerms(with: settings, context: context)
            // find differences
            let difference = try findDifferences(localTerms: localTerms, remoteTerms: remoteTerms, context: context)
            // try to delete terms that was removed
            try deleteTermsIfNeeded(terms: difference.removals, settings: settings, context: context)
            // try to upload new terms
            try addTermsIfNeeded(terms: difference.insertions, settings: settings, context: context)
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
    private func parseInput(context: CommandContext, signature: Signature) -> UploadSettings {
        self.shortOutput = signature.shortOutput
        
        let errorStyle: ConsoleStyle = shortOutput ? .plain : .error
        
        var path: String
        // use provided path or ask it
        if let argPath = signature.path {
            path = argPath
        } else {
            path = context.console.ask("You should provide path to your localization enum swift file.\nEnter it now or use command (--help for details)?".consoleText(errorStyle))
        }
        
        var name: String
        // use provided name of use default, or ask it
        if let argName = signature.name {
            name = argName
        } else {
            if signature.yesForAll == true {
                name = Constants.Defaults.enumName
            } else {
                let question: ConsoleText = .init(stringLiteral: "Use \"\(Constants.Defaults.enumName)\" as localization enum name?")
                let decision = context.console.confirm(question)
                
                if decision == true {
                    name = Constants.Defaults.enumName
                } else {
                    name = context.console.ask("You should provide name of your localization enum.\nEnter it now or use command (--help for details)?".consoleText(errorStyle))
                }
            }
        }
        
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
        let language: String = signature.language ?? Constants.Defaults.language
        // use provided mode or use default configuration
        let lowercasedMode = signature.lowercased ?? Constants.Defaults.lowercasedMode.boolValue
        // use provided mode or use default configuration
        let deleteRemovals = signature.deleteRemovals ?? Constants.Defaults.deleteRemovals.boolValue
        // compose settings structure
        let parserSettings: ParserSettings = ParserSettings(path: path,
                                                            lowercasedMode: lowercasedMode,
                                                            enumName: name)
        let poeditorSettings: PoeditorSettings = PoeditorSettings(token: token,
                                                                  id: id,
                                                                  language: language)
        return UploadSettings(parserSettings: parserSettings, poeditorSettings: poeditorSettings, deleteRemovals: deleteRemovals)
    }
    
    /// print to user parsed settings
    /// - Parameter settings: parsed settings
    /// - Parameter context: current console context
    private func printSettings(settings: UploadSettings, context: CommandContext) {
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
                                         ConsoleTextFragment(string: "path: \(settings.parserSettings.path)\n",
                                            style: brightMagentaStyle),
                                         ConsoleTextFragment(string: "name: \(settings.parserSettings.enumName)\n",
                                            style: brightMagentaStyle),
                                         ConsoleTextFragment(string: "lowercased mode: \(settings.parserSettings.lowercasedMode)\n", style: brightMagentaStyle),
                                         ConsoleTextFragment(string: "token: \(token)\n",
                                            style: brightMagentaStyle),
                                         ConsoleTextFragment(string: "id: \(projectID)\n",
                                            style: brightMagentaStyle),
                                         ConsoleTextFragment(string: "language: \(settings.poeditorSettings.language)\n",
                                            style: brightMagentaStyle),
                                         ConsoleTextFragment(string: "delete removals: \(settings.deleteRemovals)\n",
                                            style: brightMagentaStyle)]
        
        context.console.output(settingsText)
    }
    
    /// validate entered settings
    /// - Parameter settings: parsed settings
    /// - Parameter context: current console context
    /// - Parameter signature: received signature
    private func validateSettings(settings: UploadSettings, context: CommandContext, signature: Signature) throws {
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
    
    /// parse localization enum swift file
    /// - Parameter settings: parsed settings
    /// - Parameter context: current console context
    private func parseLocalizationFile(with settings: UploadSettings, context: CommandContext) throws -> [String] {
        createLoadingBar(context: context, title: "Parsing enum file...")
        currentLoadingBar?.start()
        
        let parser = FileParser(with: settings.parserSettings)
        let result = try parser.parse()
        
        currentLoadingBar?.succeed()
        printToConsole(context: context, string: "Enum parsed terms count: \(result.count)", style: .info)
        
        return result
    }
    
    /// download all remote terms via POEditor API client
    /// - Parameter settings: parsed settings
    /// - Parameter context: current console context
    private func downloadPoeditorTerms(with settings: UploadSettings, context: CommandContext) throws -> [String] {
        createLoadingBar(context: context, title: "Downloading POEditor terms...")
        currentLoadingBar?.start()
        
        let client = getOrCreatePOEditorClient(settings: settings.poeditorSettings)
        let result = try client.getAllTerms().wait()
        
        currentLoadingBar?.succeed()
        printToConsole(context: context, string: "Downloaded terms count: \(result.terms.count)", style: .info)
        
        return result.allKeys
    }
    
    /// find differences between local terms and remote terms
    /// - Parameter localTerms: array of parsed local terms
    /// - Parameter remoteTerms: array of downloaded remote terms
    /// - Parameter context: current console context
    private func findDifferences(localTerms: [String], remoteTerms: [String], context: CommandContext) throws -> TermsDifference {
        if #available(OSX 10.15, *) {
            let difference = localTerms.sorted().difference(from: remoteTerms.sorted())
            // get insertions
            let insertions = difference.insertions.compactMap { element -> String? in
                switch element {
                case .insert(_, let element, _):
                    return element
                default:
                    return nil
                }
            }
            // get removals
            let removals = difference.removals.compactMap { element -> String? in
                switch element {
                case .remove(_, let element, _):
                    return element
                default:
                    return nil
                }
            }
            
            return TermsDifference(insertions: insertions, removals: removals)
        } else {
            printToConsole(context: context, string: "findDifferences: Fallback on earlier versions of macOS", style: .warning)
            
            let diff = Set(remoteTerms).symmetricDifference(localTerms)
            // find diff via set and then decompose result into insertions and removals
            let insertions = diff.filter { remoteTerms.contains($0) == false }
            let removals = diff.filter { localTerms.contains($0) == false }
            
            return TermsDifference(insertions: Array(insertions), removals: Array(removals))
        }
    }
    
    /// validate params and try to delete remote terms
    /// - Parameter terms: values that should be removed
    /// - Parameter settings: parsed settings
    /// - Parameter context: current console context
    private func deleteTermsIfNeeded(terms: [String], settings: UploadSettings, context: CommandContext) throws {
        // check for deletion mode
        guard settings.deleteRemovals == true else {
            printToConsole(context: context, string: "Delete terms option disabled by settings. Please check --help for details.", style: .info)
            return
        }
        // check for terms existence
        guard terms.isEmpty == false else {
            printToConsole(context: context, string: "No terms for removal found.", style: .info)
            return
        }
        // print terms that should be deleted
        let redStyle: ConsoleStyle = shortOutput ? .plain : .init(color: .red)
        var deletionTermsText: ConsoleText = [ConsoleTextFragment(string: "\n", style: .init(color: .red)),
                                              ConsoleTextFragment(string: "Following terms will be deleted:\n", style: redStyle)]
        
        let brightYellowStyle: ConsoleStyle = shortOutput ? .plain : .init(color: .brightYellow)
        for (index, term) in terms.enumerated() {
            deletionTermsText.fragments.append(ConsoleTextFragment(string: "\(index + 1). \(term)\n", style: brightYellowStyle))
        }
        
        context.console.output(deletionTermsText)
        // show progress
        createLoadingBar(context: context, title: "Deleting POEditor terms...")
        currentLoadingBar?.start()
        // make request
        let values = terms.map { TermValue(term: $0) }
        let client = getOrCreatePOEditorClient(settings: settings.poeditorSettings)
        let result = try client.deleteTerms(terms: values).wait()
        // validate request result
        if result.deleted == 0 {
            currentLoadingBar?.fail()
            printToConsole(context: context, string: "Parsed count \(result.parsed), deleted count \(result.deleted), expected count \(values.count)", style: .error)
        } else if result.deleted != values.count {
            currentLoadingBar?.fail()
            printToConsole(context: context, string: "Parsed count \(result.parsed), deleted count \(result.deleted), expected count \(values.count)", style: .error)
        } else {
            currentLoadingBar?.succeed()
            printToConsole(context: context, string: "Deleted \(result.deleted) terms", style: .success)
        }
    }
    
    /// validate params and try to upload local terms
    /// - Parameter terms: values that should be uploaded
    /// - Parameter settings: parsed settings
    /// - Parameter context: current console context
    private func addTermsIfNeeded(terms: [String], settings: UploadSettings, context: CommandContext) throws {
        // check for terms existence
        guard terms.isEmpty == false else {
            printToConsole(context: context, string: "No terms for insertion found.", style: .info)
            return
        }
        // print terms that should be deleted
        let redStyle: ConsoleStyle = shortOutput ? .plain : .init(color: .red)
        var insertedTermsText: ConsoleText = [ConsoleTextFragment(string: "\n", style: .init(color: .red)),
                                              ConsoleTextFragment(string: "Following terms will be inserted:\n", style: redStyle)]
        
        let brightYellowStyle: ConsoleStyle = shortOutput ? .plain : .init(color: .brightYellow)
        for (index, term) in terms.enumerated() {
            insertedTermsText.fragments.append(ConsoleTextFragment(string: "\(index + 1). \(term)\n", style: brightYellowStyle))
        }
        
        context.console.output(insertedTermsText)
        // show progress
        createLoadingBar(context: context, title: "Inserting POEditor terms...")
        currentLoadingBar?.start()
        // make request
        let values = terms.map { TermValue(term: $0) }
        let client = getOrCreatePOEditorClient(settings: settings.poeditorSettings)
        let result = try client.addTerms(terms: values).wait()
        // validate request result
        if result.added == 0 {
            currentLoadingBar?.fail()
            printToConsole(context: context, string: "Parsed count \(result.parsed), inserted count \(result.added), expected count \(values.count)", style: .error)
        } else if result.added != values.count {
            currentLoadingBar?.fail()
            printToConsole(context: context, string: "Parsed count \(result.parsed), inserted count \(result.added), expected count \(values.count)", style: .error)
        } else {
            currentLoadingBar?.succeed()
            printToConsole(context: context, string: "Uploaded \(result.added) terms", style: .success)
        }
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
}
