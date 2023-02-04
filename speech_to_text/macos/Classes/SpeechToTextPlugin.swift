import Cocoa
import FlutterMacOS
import os.log
import Speech
import AVFoundation

public enum SwiftSpeechToTextMethods: String {
    case has_permission
    case initialize
    case listen
    case stop
    case cancel
    case locales
    case unknown // just for testing
}

public enum SwiftSpeechToTextCallbackMethods: String {
    case textRecognition
    case notifyStatus
    case notifyError
    case soundLevelChange
}

public enum SpeechToTextStatus: String {
    case listening
    case notListening
    case unavailable
    case available
    case done
    case doneNoResult
}

public enum SpeechToTextErrors: String {
    case onDeviceError
    case noRecognizerError
    case listenFailedError
    case missingOrInvalidArg
}

public enum ListenMode: Int {
    case deviceDefault = 0
    case dictation = 1
    case search = 2
    case confirmation = 3
}

struct SpeechRecognitionWords: Codable {
    let recognizedWords: String
    let confidence: Decimal
}

struct SpeechRecognitionResult: Codable {
    let alternates: [SpeechRecognitionWords]
    let finalResult: Bool
}

struct SpeechRecognitionError: Codable {
    let errorMsg: String
    let permanent: Bool
}

enum SpeechToTextError: Error {
    case runtimeError(String)
}

// public class SwiftSpeechToTextPlugin: NSObject, FlutterPlugin {
@available(macOS 10.15, *)
public class SpeechToTextMacosPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel
    private var registrar: FlutterPluginRegistrar
    private var recognizer: SFSpeechRecognizer?
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private var currentTask: SFSpeechRecognitionTask?
    private var listeningSound: AVAudioPlayer?
    private var successSound: AVAudioPlayer?
    private var cancelSound: AVAudioPlayer?
    private var previousLocale: Locale?
    private var onPlayEnd: (() -> Void)?
    private var returnPartialResults: Bool = true
    private var failedListen: Bool = false
    private var onDeviceStatus: Bool = false
    private var listening = false
    private let audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode?
    private let jsonEncoder = JSONEncoder()
    private let busForNodeTap = 0
    private let audioRecorder = AVAudioRecorder()
    private let speechBufferSize: AVAudioFrameCount = 1024
    private static var subsystem = Bundle.main.bundleIdentifier!
    private let pluginLog = OSLog(subsystem: "com.csdcorp.speechToText", category: "plugin")

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "plugin.csdcorp.com/speech_to_text", binaryMessenger: registrar.messenger)
        let instance = SpeechToTextMacosPlugin(channel, registrar: registrar)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    init(_ channel: FlutterMethodChannel, registrar: FlutterPluginRegistrar) {
        os_log("register", log: pluginLog, type: .error)
        self.channel = channel
        self.registrar = registrar
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("handle call: \(call.method)")
        switch call.method {
        case SwiftSpeechToTextMethods.has_permission.rawValue:
            hasPermission(result)
        case SwiftSpeechToTextMethods.initialize.rawValue:
            initialize(result)
        case SwiftSpeechToTextMethods.listen.rawValue:
            guard let argsArr = call.arguments as? [String: AnyObject],
                  let partialResults = argsArr["partialResults"] as? Bool, let onDevice = argsArr["onDevice"] as? Bool, let listenModeIndex = argsArr["listenMode"] as? Int, let sampleRate = argsArr["sampleRate"] as? Int
            else {
                DispatchQueue.main.async {
                    result(FlutterError(code: SpeechToTextErrors.missingOrInvalidArg.rawValue,
                                        message: "Missing arg partialResults, onDevice, listenMode, and sampleRate are required",
                                        details: nil))
                }
                return
            }
            var localeStr: String?
            if let localeParam = argsArr["localeId"] as? String {
                localeStr = localeParam
            }
            guard let listenMode = ListenMode(rawValue: listenModeIndex) else {
                DispatchQueue.main.async {
                    result(FlutterError(code: SpeechToTextErrors.missingOrInvalidArg.rawValue,
                                        message: "invalid value for listenMode, must be 0-2, was \(listenModeIndex)",
                                        details: nil))
                }
                return
            }

            listenForSpeech(result, localeStr: localeStr, partialResults: partialResults, onDevice: onDevice, listenMode: listenMode, sampleRate: sampleRate)
        case SwiftSpeechToTextMethods.stop.rawValue:
            stopSpeech(result)
        case SwiftSpeechToTextMethods.cancel.rawValue:
            cancelSpeech(result)
        case SwiftSpeechToTextMethods.locales.rawValue:
            locales(result)
        default:
            os_log("Unrecognized method: %{PUBLIC}@", log: pluginLog, type: .error, call.method)
            DispatchQueue.main.async {
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private func hasPermission(_ result: @escaping FlutterResult) {
        let has = SFSpeechRecognizer.authorizationStatus() == SFSpeechRecognizerAuthorizationStatus.authorized
        DispatchQueue.main.async {
            result(has)
        }
    }

    private func initialize(_ result: @escaping FlutterResult) {
        var success = false
        
        
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            print("granted = \(granted)")
        }
        
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard let self = self else { return }
            
            switch status {
            case .notDetermined:
                SFSpeechRecognizer.requestAuthorization { status in
                    success = status == SFSpeechRecognizerAuthorizationStatus.authorized
                    if success {
                        self.setupSpeechRecognition(result)
                    } else {
                        self.sendBoolResult(false, result)
                    }
                }
            case .denied:
                os_log("Permission permanently denied", log: self.pluginLog, type: .info)
                self.sendBoolResult(false, result)
            case .restricted:
                os_log("Device restriction prevented initialize", log: self.pluginLog, type: .info)
                self.sendBoolResult(false, result)
            default:
                os_log("Has permissions continuing with setup", log: self.pluginLog, type: .debug)
                self.setupSpeechRecognition(result)
            }
        }
    }

    fileprivate func sendBoolResult(_ value: Bool, _ result: @escaping FlutterResult) {
        DispatchQueue.main.async {
            result(value)
        }
    }

    fileprivate func setupListeningSound() {
        listeningSound = loadSound("assets/sounds/speech_to_text_listening.m4r")
        successSound = loadSound("assets/sounds/speech_to_text_stop.m4r")
        cancelSound = loadSound("assets/sounds/speech_to_text_cancel.m4r")
    }

    fileprivate func loadSound(_ assetPath: String) -> AVAudioPlayer? {
        var player: AVAudioPlayer?

        let flutterBundleId = "io.flutter.flutter.app"
        guard let flutterBundle = Bundle(identifier: flutterBundleId) else {
            fatalError("Could not get Flutter App bundle with ID: \(flutterBundleId)")
        }
        
        if let soundUrl = flutterBundle.url(
            forResource: assetPath,
            withExtension: nil,
            subdirectory: "flutter_assets") {
            do {
                player = try AVAudioPlayer(contentsOf: soundUrl)
                player?.delegate = self
                print("player delegate = \(player?.delegate)")
            } catch {
                // no audio
            }
        }
        return player
    }

    private func setupSpeechRecognition(_ result: @escaping FlutterResult) {
        setupRecognizerForLocale(locale: Locale.current)
        guard let recognizer = recognizer else {
            sendBoolResult(false, result)
            return
        }
        onDeviceStatus = recognizer.supportsOnDeviceRecognition
        recognizer.delegate = self
        inputNode = audioEngine.inputNode
        guard inputNode != nil else {
            os_log("Error no input node", log: pluginLog, type: .error)
            sendBoolResult(false, result)
            return
        }

        setupListeningSound()

        sendBoolResult(true, result)
    }

    private func setupRecognizerForLocale(locale: Locale) {
        if previousLocale == locale {
            return
        }

        previousLocale = locale
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    private func getLocale(_ localeStr: String?) -> Locale {
        guard let aLocaleStr = localeStr else {
            return Locale.current
        }
        let locale = Locale(identifier: aLocaleStr)
        return locale
    }

    private func stopSpeech(_ result: @escaping FlutterResult) {
        if !listening {
            sendBoolResult(false, result)
            return
        }
        stopAllPlayers()
        currentTask?.finish()
        if let sound = successSound {
            onPlayEnd = { () in
                self.stopCurrentListen()
                self.sendBoolResult(true, result)
            }
            sound.play()
        } else {
            stopCurrentListen()
            sendBoolResult(true, result)
        }
    }

    private func cancelSpeech(_ result: @escaping FlutterResult) {
        if !listening {
            sendBoolResult(false, result)
            return
        }
        stopAllPlayers()
        currentTask?.cancel()
        if let sound = cancelSound {
            onPlayEnd = { () in
                self.stopCurrentListen()
                self.sendBoolResult(true, result)
            }
            sound.play()
        } else {
            stopCurrentListen()
            sendBoolResult(true, result)
        }
    }

    private func stopAllPlayers() {
        print("stopAllPlayers")
        cancelSound?.stop()
        successSound?.stop()
        listeningSound?.stop()
    }

    private func stopCurrentListen() {
        print("stopCurrentListen")
        currentRequest?.endAudio()
        stopAllPlayers()
        self.audioEngine.stop()
        self.inputNode?.removeTap(onBus: self.busForNodeTap)
        invokeFlutter(SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.done.rawValue)

        currentRequest = nil
        currentTask = nil
        onPlayEnd = nil
        listening = false
    }

    private func listenForSpeech(_ result: @escaping FlutterResult, localeStr: String?, partialResults: Bool, onDevice: Bool, listenMode: ListenMode, sampleRate: Int) {
        
        if currentTask != nil || listening {
            print("listen fail")
            sendBoolResult(false, result)
            return
        }
        do {
            //    let inErrorTest = true
            failedListen = false
            returnPartialResults = partialResults
            setupRecognizerForLocale(locale: getLocale(localeStr))
            guard let localRecognizer = recognizer else {
                print("listen fail create recognizer")

                result(FlutterError(code: SpeechToTextErrors.noRecognizerError.rawValue,
                                    message: "Failed to create speech recognizer",
                                    details: nil))
                return
            }
            if onDevice, !localRecognizer.supportsOnDeviceRecognition {
                print("listen fail on device recognition")

                result(FlutterError(code: SpeechToTextErrors.onDeviceError.rawValue,
                        message: "on device recognition is not supported on this device",
                        details: nil))
            }

            if let sound = listeningSound {
                onPlayEnd = { () in
                    print("listen onPlayEnd")
                    if !self.failedListen {
                        self.listening = true
                        self.invokeFlutter(SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.listening.rawValue)
                    }
                }
                print("play \(sound) \(sound.delegate)")

                sound.play()
            }

            audioEngine.reset()
            if inputNode?.inputFormat(forBus: 0).channelCount == 0 {
                throw SpeechToTextError.runtimeError("Not enough available inputs.")
            }
            self.currentRequest = SFSpeechAudioBufferRecognitionRequest()

            guard
                let currentRequest = currentRequest,
                let recognizer = recognizer
            else {
                sendBoolResult(false, result)
                return
            }
            currentRequest.shouldReportPartialResults = true
            currentRequest.requiresOnDeviceRecognition = true
            switch listenMode {
            case ListenMode.dictation:
                currentRequest.taskHint = SFSpeechRecognitionTaskHint.dictation
            case ListenMode.search:
                currentRequest.taskHint = SFSpeechRecognitionTaskHint.search
            case ListenMode.confirmation:
                currentRequest.taskHint = SFSpeechRecognitionTaskHint.confirmation
            default:
                break
            }

            currentTask = recognizer.recognitionTask(with: currentRequest, delegate: self)
            let recordingFormat = inputNode?.outputFormat(forBus: busForNodeTap)
            let fmt = AVAudioFormat(commonFormat: recordingFormat!.commonFormat, sampleRate: recordingFormat!.sampleRate, channels: recordingFormat!.channelCount, interleaved: recordingFormat!.isInterleaved)
            self.inputNode?.installTap(onBus: self.busForNodeTap, bufferSize: self.speechBufferSize, format: fmt) { (buffer: AVAudioPCMBuffer, _: AVAudioTime) in
                currentRequest.append(buffer)
                self.updateSoundLevel(buffer: buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            if listeningSound == nil {
                listening = true
                invokeFlutter(SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.listening.rawValue)
            }
            sendBoolResult(true, result)
        } catch {
            failedListen = true
            os_log("Error starting listen: %{PUBLIC}@", log: pluginLog, type: .error, error.localizedDescription)
            invokeFlutter(SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.notListening.rawValue)
            stopCurrentListen()
            sendBoolResult(false, result)
            // ensure the not listening signal is sent in the error case
            let speechError = SpeechRecognitionError(errorMsg: "error_listen_failed", permanent: true)
            do {
                let errorResult = try jsonEncoder.encode(speechError)
                invokeFlutter(SwiftSpeechToTextCallbackMethods.notifyError, arguments: String(data: errorResult, encoding: .utf8))
                invokeFlutter(SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.doneNoResult.rawValue)
            } catch {
                os_log("Could not encode JSON", log: pluginLog, type: .error)
            }
        }
    }

    private func updateSoundLevel(buffer: AVAudioPCMBuffer) {
        guard
            let channelData = buffer.floatChannelData
        else {
            return
        }

        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(from: 0,
                                           to: Int(buffer.frameLength),
                                           by: buffer.stride).map { channelDataValue[$0] }
        let frameLength = Float(buffer.frameLength)
        let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / frameLength)
        let avgPower = 20 * log10(rms)
        invokeFlutter(SwiftSpeechToTextCallbackMethods.soundLevelChange, arguments: avgPower)
    }

    /// Build a list of localId:name with the current locale first
    private func locales(_ result: @escaping FlutterResult) {
        var localeNames = [String]()
        let locales = SFSpeechRecognizer.supportedLocales()
        var currentLocaleId = Locale.current.identifier
        if Locale.preferredLanguages.count > 0 {
            currentLocaleId = Locale.preferredLanguages[0]
        }
        if let idName = buildIdNameForLocale(forIdentifier: currentLocaleId) {
            localeNames.append(idName)
        }
        for locale in locales {
            if locale.identifier == currentLocaleId {
                continue
            }
            if let idName = buildIdNameForLocale(forIdentifier: locale.identifier) {
                localeNames.append(idName)
            }
        }
        DispatchQueue.main.async {
            result(localeNames)
        }
    }

    private func buildIdNameForLocale(forIdentifier: String) -> String? {
        var idName: String?
        if let name = Locale.current.localizedString(forIdentifier: forIdentifier) {
            let sanitizedName = name.replacingOccurrences(of: ":", with: " ")
            idName = "\(forIdentifier):\(sanitizedName)"
        }
        return idName
    }

    private func handleResult(_ transcriptions: [SFTranscription], isFinal: Bool) {
        if !isFinal && !returnPartialResults {
            return
        }
        var speechWords: [SpeechRecognitionWords] = []
        for transcription in transcriptions {
            let words = SpeechRecognitionWords(recognizedWords: transcription.formattedString, confidence: confidenceIn(transcription))
            speechWords.append(words)
        }
        let speechInfo = SpeechRecognitionResult(alternates: speechWords, finalResult: isFinal)
        do {
            let speechMsg = try jsonEncoder.encode(speechInfo)
            if let speechStr = String(data: speechMsg, encoding: .utf8) {
                os_log("Encoded JSON result: %{PUBLIC}@", log: pluginLog, type: .debug, speechStr)
                invokeFlutter(SwiftSpeechToTextCallbackMethods.textRecognition, arguments: speechStr)
            }
        } catch {
            os_log("Could not encode JSON", log: pluginLog, type: .error)
        }
    }

    private func confidenceIn(_ transcription: SFTranscription) -> Decimal {
        guard transcription.segments.count > 0 else {
            return 0
        }
        var totalConfidence: Float = 0.0
        for segment in transcription.segments {
            totalConfidence += segment.confidence
        }
        let avgConfidence: Float = totalConfidence / Float(transcription.segments.count)
        let confidence: Float = (avgConfidence * 1000).rounded() / 1000
        return Decimal(string: String(describing: confidence))!
    }

    private func invokeFlutter(_ method: SwiftSpeechToTextCallbackMethods, arguments: Any?) {
        os_log("invokeFlutter %{PUBLIC}@", log: pluginLog, type: .debug, method.rawValue)
        DispatchQueue.main.async {
            self.channel.invokeMethod(method.rawValue, arguments: arguments)
        }
    }
}

@available(macOS 10.15, *)
extension SpeechToTextMacosPlugin: SFSpeechRecognizerDelegate {
    public func speechRecognizer(_: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        let availability = available ? SpeechToTextStatus.available.rawValue : SpeechToTextStatus.unavailable.rawValue
        os_log("Availability changed: %{PUBLIC}@", log: pluginLog, type: .debug, availability)
        invokeFlutter(SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: availability)
    }
}

@available(macOS 10.15, *)
extension SpeechToTextMacosPlugin: SFSpeechRecognitionTaskDelegate {
    public func speechRecognitionDidDetectSpeech(_: SFSpeechRecognitionTask) {
        // Do nothing for now
    }

    public func speechRecognitionTaskFinishedReadingAudio(_ task: SFSpeechRecognitionTask) {
        reportError(source: "FinishedReadingAudio", error: task.error)
        os_log("Finished reading audio", log: pluginLog, type: .debug)
        invokeFlutter(SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.notListening.rawValue)
    }

    public func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask) {
        reportError(source: "TaskWasCancelled", error: task.error)
        os_log("Canceled reading audio", log: pluginLog, type: .debug)
        invokeFlutter(SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.notListening.rawValue)
    }

    public func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
        reportError(source: "FinishSuccessfully", error: task.error)
        os_log("FinishSuccessfully", log: pluginLog, type: .debug)
        if !successfully {
            invokeFlutter(SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.doneNoResult.rawValue)
            if let err = task.error as NSError? {
                var errorMsg: String
                switch err.code {
                case 201:
                    errorMsg = "error_speech_recognizer_disabled"
                case 203:
                    errorMsg = "error_retry"
                case 1110:
                    errorMsg = "error_no_match"
                default:
                    errorMsg = "error_unknown (\(err.code))"
                }
                let speechError = SpeechRecognitionError(errorMsg: errorMsg, permanent: true)
                do {
                    let errorResult = try jsonEncoder.encode(speechError)
                    invokeFlutter(SwiftSpeechToTextCallbackMethods.notifyError, arguments: String(data: errorResult, encoding: .utf8))
                } catch {
                    os_log("Could not encode JSON", log: pluginLog, type: .error)
                }
            }
        }
        stopCurrentListen()
    }

    public func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didHypothesizeTranscription transcription: SFTranscription) {
        os_log("HypothesizeTranscription", log: pluginLog, type: .debug)
        reportError(source: "HypothesizeTranscription", error: task.error)
        handleResult([transcription], isFinal: false)
    }

    public func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition recognitionResult: SFSpeechRecognitionResult) {
        reportError(source: "FinishRecognition", error: task.error)
        os_log("FinishRecognition %{PUBLIC}@", log: pluginLog, type: .debug, recognitionResult.isFinal.description)
        let isFinal = recognitionResult.isFinal
        handleResult(recognitionResult.transcriptions, isFinal: isFinal)
    }

    private func reportError(source: String, error: Error?) {
        if error != nil {
            os_log("%{PUBLIC}@ with error: %{PUBLIC}@", log: pluginLog, type: .debug, source, error.debugDescription)
        }
    }
}

@available(macOS 10.15, *)
extension SpeechToTextMacosPlugin: AVAudioPlayerDelegate {
    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        print("player error: \(error)")
    }
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        print("audioPlayerDidFinishPlaying")
        onPlayEnd?()
    }
}
