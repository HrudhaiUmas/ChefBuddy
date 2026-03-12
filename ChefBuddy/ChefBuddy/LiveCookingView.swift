// LiveCookingView.swift
// The real-time cooking assistant screen. Combines a live camera feed with
// step-by-step recipe navigation and an AI chat interface.
// Users can tap a button to let the AI analyse a frame of their cooking, or ask
// typed/voice questions hands-free using SpeechManager (SFSpeechRecognizer).
// When the last step is complete, transitions directly into RecipeReviewView.

import SwiftUI
import AVFoundation
import FirebaseFirestore
import Combine
import Speech

import SwiftUI
import AVFoundation
import FirebaseFirestore
import Combine
import Speech
import UIKit


extension UIImage {
    func resizedForAI() -> UIImage? {
        let targetWidth: CGFloat = 512.0
        let scale = targetWidth / self.size.width
        let targetHeight = self.size.height * scale
        let targetSize = CGSize(width: targetWidth, height: targetHeight)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

        let resized = renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        guard let jpegData = resized.jpegData(compressionQuality: 0.6) else { return nil }
        return UIImage(data: jpegData)
    }
}


// Wraps AVCaptureSession so SwiftUI can observe camera state reactively.
// Publishes isRunning and capturedImage — the view only needs these two
// values to drive its UI, keeping camera internals fully encapsulated.
class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var capturedImage: UIImage? = nil
    @Published var isRunning = false
    @Published var authorizationStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var statusMessage: String? = nil

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private let frameQueue = DispatchQueue(label: "camera.frame.queue")
    private var latestBuffer: CMSampleBuffer?
    private var isConfigured = false
    private var startRequested = false

    override init() {
        super.init()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        self.previewLayer = layer

        checkPermissionAndSetup()
    }

    // Checks camera authorisation before adding inputs. Adding an input without
    // permission crashes the session, so permission must be confirmed first.
    private func checkPermissionAndSetup() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        DispatchQueue.main.async {
            self.authorizationStatus = status
        }

        switch status {
        case .authorized:
            configureSessionIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                let updated = AVCaptureDevice.authorizationStatus(for: .video)
                DispatchQueue.main.async {
                    self.authorizationStatus = updated
                }
                if granted && updated == .authorized {
                    self.configureSessionIfNeeded()
                } else {
                    DispatchQueue.main.async {
                        self.statusMessage = "Camera permission is required for Live Cooking Help."
                    }
                }
            }
        default:
            DispatchQueue.main.async {
                self.statusMessage = "Camera permission denied. Enable it in Settings."
            }
        }
    }

    private func configureSessionIfNeeded() {
        sessionQueue.async {
            guard !self.isConfigured else {
                if self.startRequested && !self.session.isRunning {
                    self.session.startRunning()
                    DispatchQueue.main.async { self.isRunning = true }
                }
                return
            }

            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.statusMessage = "Unable to access back camera."
                }
                return
            }
            self.session.addInput(input)

            self.output.setSampleBufferDelegate(self, queue: self.frameQueue)
            self.output.alwaysDiscardsLateVideoFrames = true
            if self.session.canAddOutput(self.output) {
                self.session.addOutput(self.output)
            }

            if let connection = self.output.connection(with: .video),
               connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }

            self.session.commitConfiguration()
            self.isConfigured = true

            DispatchQueue.main.async {
                self.statusMessage = nil
            }

            if self.startRequested && !self.session.isRunning {
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.isRunning = true
                }
            }
        }
    }

    func start() {
        startRequested = true
        checkPermissionAndSetup()

        sessionQueue.async {
            guard self.authorizationStatus == .authorized, self.isConfigured else { return }
            guard !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async {
                self.isRunning = true
            }
        }
    }

    func stop() {
        startRequested = false
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }

    func snapshotImage() -> UIImage? {
        guard let buffer = latestBuffer,
              let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // Grabs the latest sample buffer and converts it to a UIImage so it can
    // be sent to the Gemini vision model. Uses CIContext for efficient GPU conversion.
    func captureFrame() {
        guard let image = snapshotImage() else { return }
        DispatchQueue.main.async {
            self.capturedImage = image
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        latestBuffer = sampleBuffer
    }
}


// Manages microphone input and on-device speech recognition.
// Hands-free input is important in a cooking context where the user's
// hands are often messy — voice lets them ask questions without touching the screen.
class SpeechManager: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    @Published var transcript: String = ""
    @Published var finalTranscript: String = ""
    @Published var isRecording: Bool = false
    @Published var audioLevel: Double = 0
    @Published var permissionGranted: Bool = false
    @Published var errorMessage: String = ""
    @Published var speechAuthorized: Bool = false
    @Published var micAuthorized: Bool = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var manualStop = false

    override init() {
        super.init()
        recognizer?.delegate = self
        requestPermissions()
    }

    // Requests both speech recognition and microphone permissions up front.
    // Both are required — SFSpeechRecognizer needs the mic AND system authorisation.
    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.speechAuthorized = (status == .authorized)
                self?.permissionGranted = (self?.speechAuthorized == true && self?.micAuthorized == true)
                if status != .authorized {
                    self?.errorMessage = "Speech recognition permission denied"
                }
            }
        }
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.micAuthorized = granted
                self?.permissionGranted = (self?.speechAuthorized == true && self?.micAuthorized == true)
                if !granted { self?.errorMessage = "Microphone access denied" }
            }
        }
    }

    // Configures the audio session for recording, starts the recognition task,
    // and taps the input node to feed audio buffers into the request in real time.
    // .duckOthers lowers any background audio so speech recognition is cleaner.
    func startRecording() {
        guard permissionGranted, !audioEngine.isRunning else {
            if !permissionGranted {
                errorMessage = "Enable microphone and speech permissions in Settings"
            }
            return
        }

        transcript = ""
        finalTranscript = ""
        errorMessage = ""
        manualStop = false
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Audio session error"
            return
        }

        audioEngine.stop()
        audioEngine.reset()
        audioEngine = AVAudioEngine()

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            if let result = result {
                DispatchQueue.main.async {
                    self?.transcript = result.bestTranscription.formattedString
                }
            }
            if error != nil || (result?.isFinal == true) {
                self?.stopRecording()
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            self.recognitionRequest?.append(buffer)
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<frameLength {
                let sample = channelData[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frameLength))
            let normalized = min(max(Double(rms) * 10, 0), 1)
            DispatchQueue.main.async {
                self.audioLevel = normalized
            }
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            DispatchQueue.main.async { self.isRecording = true }
        } catch {
            errorMessage = "Could not start recording"
        }
    }

    func stopRecording(sendFinal: Bool = true) {
        manualStop = true
        finalizeRecording(sendFinal: sendFinal)
    }

    private func finalizeRecording(sendFinal: Bool) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        audioEngine.stop()
        if isRecording {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DispatchQueue.main.async {
            self.isRecording = false
            self.audioLevel = 0
            if sendFinal && !trimmed.isEmpty {
                self.finalTranscript = trimmed
            }
        }
    }
}


final class VoiceResponseManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published var isSpeaking = false
    @Published var isPreparingAudio = false
    @Published var usingNeuralVoice = false
    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()
        isPreparingAudio = true
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            guard let self else { return }

            let hasGoogleKey = ((Bundle.main.object(forInfoDictionaryKey: "GOOGLE_TTS_API_KEY") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false)

            let playedGoogle = await self.playGoogleCloudSpeech(text: trimmed)

            if playedGoogle {
                return
            }

            if hasGoogleKey {
                await MainActor.run {
                    self.isPreparingAudio = false
                    self.isSpeaking = false
                    self.usingNeuralVoice = false
                }
                return
            }

            await MainActor.run {
                self.isPreparingAudio = false
                self.playSystemVoice(trimmed)
            }
        }
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if let player = audioPlayer, player.isPlaying {
            player.stop()
        }
        audioPlayer = nil
        isSpeaking = false
        isPreparingAudio = false
        usingNeuralVoice = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func playSystemVoice(_ text: String) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch { }

        let utterance = AVSpeechUtterance(string: text)
        let bestVoice = mostNaturalVoice()
        utterance.voice = bestVoice

        if bestVoice?.quality == .premium || bestVoice?.quality == .enhanced {
            self.usingNeuralVoice = true
        } else {
            self.usingNeuralVoice = false
        }

        utterance.rate = 0.50
        utterance.pitchMultiplier = 1.05
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.02
        utterance.postUtteranceDelay = 0.04

        synthesizer.speak(utterance)
    }

    private func playGoogleCloudSpeech(text: String) async -> Bool {
        guard let apiKey = Bundle.main.object(forInfoDictionaryKey: "GOOGLE_TTS_API_KEY") as? String,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let configuredVoice = (Bundle.main.object(forInfoDictionaryKey: "GOOGLE_TTS_VOICE") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceName = (configuredVoice?.isEmpty == false) ? configuredVoice! : "en-US-Journey-D"
        let parts = voiceName.split(separator: "-")
        let languageCode = parts.count >= 2 ? "\(parts[0])-\(parts[1])" : "en-US"

        guard let url = URL(string: "https://texttospeech.googleapis.com/v1/text:synthesize?key=\(apiKey)") else {
            return false
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let payload: [String: Any] = [
                "input": ["text": text],
                "voice": [
                    "languageCode": languageCode,
                    "name": voiceName
                ],
                "audioConfig": [
                    "audioEncoding": "MP3",
                    "speakingRate": 1.10,
                    "pitch": 0.0
                ]
            ]

            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return false
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let audioBase64 = json["audioContent"] as? String,
                  let audioData = Data(base64Encoded: audioBase64) else {
                return false
            }

            return await MainActor.run {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .duckOthers, .allowBluetooth])
                    try session.setActive(true, options: .notifyOthersOnDeactivation)

                    let player = try AVAudioPlayer(data: audioData)
                    player.delegate = self
                    player.prepareToPlay()
                    self.audioPlayer = player

                    self.usingNeuralVoice = true
                    self.isSpeaking = true
                    self.isPreparingAudio = false
                    player.play()
                    return true
                } catch {
                    self.audioPlayer = nil
                    self.usingNeuralVoice = false
                    self.isSpeaking = false
                    self.isPreparingAudio = false
                    return false
                }
            }
        } catch {
            return false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isPreparingAudio = false
            self.isSpeaking = true
        }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.isPreparingAudio = false
            self.usingNeuralVoice = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            self.isPreparingAudio = false
            self.usingNeuralVoice = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.audioPlayer = nil
            self.isSpeaking = false
            self.isPreparingAudio = false
            self.usingNeuralVoice = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async {
            self.audioPlayer = nil
            self.isSpeaking = false
            self.isPreparingAudio = false
            self.usingNeuralVoice = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func mostNaturalVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let englishVoices = voices.filter { $0.language.hasPrefix("en") }

        if let premium = englishVoices.first(where: { $0.quality == .premium && $0.language == "en-US" }) { return premium }
        if let premiumAnyEn = englishVoices.first(where: { $0.quality == .premium }) { return premiumAnyEn }
        if let enhanced = englishVoices.first(where: { $0.quality == .enhanced && $0.language == "en-US" }) { return enhanced }
        let goodNames = ["zoe", "oliver", "siri", "alex"]
        if let namedVoice = englishVoices.first(where: { voice in
            goodNames.contains(where: { voice.name.lowercased().contains($0) })
        }) { return namedVoice }
        return AVSpeechSynthesisVoice(language: "en-US")
    }
}


struct CameraPreview: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    class VideoView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
    }

    func makeUIView(context: Context) -> UIView {
        let view = VideoView()
        view.previewLayer = layer
        view.layer.addSublayer(layer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { }
}


// Drives the step navigation and AI response state for the cooking screen.
// Kept separate from the view so logic can be tested independently and so
// the camera and speech managers stay decoupled from AI calls.
class LiveCookingViewModel: ObservableObject {
    @Published var currentStepIndex: Int = 0
    @Published var aiResponse: String = ""
    @Published var isThinking: Bool = false
    @Published var conversationHistory: [ChatMessage] = []
    @Published var stepConfidence: String = ""

    struct ChatMessage: Identifiable {
        let id = UUID()
        let role: String
        let text: String
        let timestamp: Date
    }

    // Sends a camera frame + contextual prompt to Gemini and updates aiResponse.
    // The prompt tells the model which step we think we're on so it can confirm
    // or correct, making the guidance actionable rather than generic.
    func analyzeFrame(image: UIImage, recipe: Recipe, assistant: CookingAssistant) {
        isThinking = true
        let steps = recipe.steps
        let currentStep = steps.indices.contains(currentStepIndex) ? steps[currentStepIndex] : "Unknown step"
        let allSteps = steps.enumerated().map { "Step \($0.offset + 1): \($0.element)" }.joined(separator: "\n")

        Task {
            do {
                let prompt = """
                I am cooking: \(recipe.title)
                All steps: \(allSteps)
                I believe I am currently on Step \(currentStepIndex + 1): \(currentStep)

                Look at this image of what I'm cooking right now and:
                1. Confirm which step I appear to be on based on what you see
                2. Give me specific, actionable guidance for what to do RIGHT NOW
                3. Warn me of anything that looks wrong or needs attention

                CRITICAL: You are a live voice coach. Keep your response to a maximum of 1 or 2 short sentences. Do not use lists or bullet points. Speak conversationally.
                """

                let resizedImage = image.resizedForAI() ?? image
                let response = try await assistant.getLiveHelp(image: resizedImage, question: prompt)

                await MainActor.run {
                    self.aiResponse = response
                    self.isThinking = false
                    self.conversationHistory.append(ChatMessage(role: "assistant", text: response, timestamp: Date()))
                }
            } catch {
                await MainActor.run {
                    self.aiResponse = "Couldn't analyze the image. Make sure you have good lighting and try again."
                    self.isThinking = false
                }
            }
        }
    }

    func askQuestion(question: String, recipe: Recipe, assistant: CookingAssistant, frameImage: UIImage? = nil) {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isThinking = true
        conversationHistory.append(ChatMessage(role: "user", text: question, timestamp: Date()))

        let currentStep = recipe.steps.indices.contains(currentStepIndex) ? recipe.steps[currentStepIndex] : ""

        Task {
            do {
                let prompt = """
                I am cooking \(recipe.title), currently on step \(currentStepIndex + 1): \(currentStep)
                My question: \(question)

                If an image is provided, use it to verify progress and detect mistakes.
                Answer specifically in context of this recipe step.

                CRITICAL: You are a live voice coach. Keep your response to a maximum of 1 or 2 short sentences. Do not use lists or bullet points. Speak conversationally.
                """
                let response: String
                if let frameImage {
                    let frameImageToSend = frameImage.resizedForAI()
                    response = try await assistant.getLiveHelp(image: frameImageToSend ?? frameImage, question: prompt)
                } else {
                    response = try await assistant.getHelp(question: prompt)
                }
                await MainActor.run {
                    self.aiResponse = response
                    self.isThinking = false
                    self.conversationHistory.append(ChatMessage(role: "assistant", text: response, timestamp: Date()))
                }
            } catch {
                await MainActor.run {
                    self.isThinking = false
                    self.aiResponse = "Couldn't get a response. Try again."
                }
            }
        }
    }

    func moveToStep(_ index: Int, recipe: Recipe) {
        currentStepIndex = index
        aiResponse = ""
    }

    func nextStep(recipe: Recipe) {
        if currentStepIndex < recipe.steps.count - 1 {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                currentStepIndex += 1
                aiResponse = ""
            }
        }
    }

    func prevStep(recipe: Recipe) {
        if currentStepIndex > 0 {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                currentStepIndex -= 1
                aiResponse = ""
            }
        }
    }
}


// Sheet that lists the user's saved recipes so they can pick one before
// starting live cooking. Shown from both HomeView and the dropdown menu.
struct RecipePickerSheet: View {
    let recipes: [Recipe]
    let onSelect: (Recipe) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What are we cooking?")
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                Text("Pick a recipe to get live AI help")
                    .font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 20)

            if recipes.isEmpty {
                VStack(spacing: 16) {
                    Spacer()
                    Text("🍳").font(.system(size: 60))
                    Text("No saved recipes yet.\nGenerate some first!")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(recipes) { recipe in
                            Button(action: {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                                    onSelect(recipe)
                                }
                            }) {
                                HStack(spacing: 16) {
                                    Text(recipe.emoji)
                                        .font(.system(size: 36))
                                        .frame(width: 60, height: 60)
                                        .background(
                                            LinearGradient(
                                                colors: [.orange.opacity(0.12), .green.opacity(0.08)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing
                                            )
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 14))

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(recipe.title)
                                            .font(.system(size: 16, weight: .bold, design: .rounded))
                                            .foregroundStyle(.primary)
                                        HStack(spacing: 12) {
                                            Label(recipe.cookTime, systemImage: "clock")
                                            Label("\(recipe.steps.count) steps", systemImage: "list.number")
                                        }
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(16)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 18)
                                        .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}


// The full-screen cooking experience. Combines camera, step navigation,
// AI frame analysis, and voice/typed question input in a single dark-mode view.
// Designed to stay on-screen the entire time the user cooks so they can
// glance at instructions and get help without leaving the screen.
struct LiveCookingView: View {
    let recipe: Recipe
    @ObservedObject var assistant: CookingAssistant
    let userId: String
    @Environment(\.dismiss) var dismiss

    @StateObject private var camera = CameraManager()
    @StateObject private var vm = LiveCookingViewModel()
    @StateObject private var speech = SpeechManager()
    @StateObject private var voice = VoiceResponseManager()

    @State private var questionText = ""
    @State private var showStepList = false
    @State private var showReview = false
    @FocusState private var questionFocused: Bool
    @State private var flashCapture = false
    @State private var renderedResponse = ""
    @State private var pendingResponse: String?
    @State private var isAwaitingSpokenResponse = false

    var progress: Double {
        guard recipe.steps.count > 0 else { return 0 }
        return Double(vm.currentStepIndex + 1) / Double(recipe.steps.count)
    }

    private var cameraReady: Bool {
        camera.authorizationStatus == .authorized && camera.isRunning
    }

    private var cameraPermissionDenied: Bool {
        camera.authorizationStatus == .denied || camera.authorizationStatus == .restricted
    }

    private var isVoiceActive: Bool {
        speech.isRecording || voice.isSpeaking || voice.isPreparingAudio || vm.isThinking
    }


    private var liveStatusText: String {
        if speech.isRecording { return "Listening to the chef..." }
        if voice.isPreparingAudio || vm.isThinking { return "Cooking up a response..." }
        if voice.isSpeaking { return "Tap orb to interrupt." }
        return "Tap the orb to ask..."
    }

    private var liveStatusColor: Color {
        if speech.isRecording { return .orange }
        if voice.isPreparingAudio || vm.isThinking { return .yellow }
        if voice.isSpeaking { return .green }
        return .white.opacity(0.6)
    }

    private func currentFrameForContext() -> UIImage? {
        camera.snapshotImage() ?? camera.capturedImage
    }

    private func startVoiceCapture() {
        guard speech.permissionGranted else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        questionFocused = false
        if voice.isSpeaking {
            voice.stop()
        }
        if !speech.isRecording {
            speech.startRecording()
        }
    }

    private func stopVoiceCapture(sendFinal: Bool) {
        if speech.isRecording {
            speech.stopRecording(sendFinal: sendFinal)
        }
    }

    private func toggleVoiceOrb() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if speech.isRecording {
            stopVoiceCapture(sendFinal: true)
        } else {
            startVoiceCapture()
        }
    }

    private func sendQuestionWithLiveContext(_ rawQuestion: String) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        if voice.isSpeaking {
            voice.stop()
        }
        stopVoiceCapture(sendFinal: false)

        questionText = ""
        questionFocused = false

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let frame = currentFrameForContext()
        vm.askQuestion(question: question, recipe: recipe, assistant: assistant, frameImage: frame)
    }

    private func handleAIResponseForVoice(_ response: String) {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        pendingResponse = trimmed
        isAwaitingSpokenResponse = true
        voice.speak(trimmed)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard self.pendingResponse == trimmed else { return }
            if !self.voice.isPreparingAudio && !self.voice.isSpeaking {
                self.renderedResponse = trimmed
                self.pendingResponse = nil
                self.isAwaitingSpokenResponse = false
            }
        }
    }


    private var floatingTopPill: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.8))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Step \(vm.currentStepIndex + 1) of \(recipe.steps.count)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                }

                Spacer()

                if voice.isSpeaking {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                        voice.stop()
                    }) {
                        Text("Stop")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.8))
                            .clipShape(Capsule())
                    }
                    .transition(.scale.combined(with: .opacity))
                }

                Button(action: { showStepList = true }) {
                    Image(systemName: "list.bullet.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white.opacity(0.8))
                }

                if vm.currentStepIndex == recipe.steps.count - 1 {
                    Button(action: {
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        showReview = true
                    }) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.green)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.1))
                    Rectangle()
                        .fill(LinearGradient(colors: [.orange, .green], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * progress)
                        .animation(.spring(response: 0.45), value: progress)
                }
            }
            .frame(height: 3)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
    }

    private var floatingContent: some View {
        VStack(spacing: 12) {
            if recipe.steps.indices.contains(vm.currentStepIndex) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("CURRENT STEP")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                        Spacer()
                        HStack(spacing: 12) {
                            Button(action: { vm.prevStep(recipe: recipe) }) {
                                Image(systemName: "chevron.left.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(vm.currentStepIndex > 0 ? Color.white : Color.white.opacity(0.3))
                            }
                            .disabled(vm.currentStepIndex == 0)

                            Button(action: { vm.nextStep(recipe: recipe) }) {
                                Image(systemName: "chevron.right.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(vm.currentStepIndex < recipe.steps.count - 1 ? Color.white : Color.white.opacity(0.3))
                            }
                            .disabled(vm.currentStepIndex == recipe.steps.count - 1)
                        }
                    }
                    Text(recipe.steps[vm.currentStepIndex])
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .lineSpacing(4)
                }
                .padding(16)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.15), lineWidth: 1))
            }

            if isAwaitingSpokenResponse && !voice.isSpeaking {
                HStack(spacing: 8) {
                    Text("🍳")
                        .font(.system(size: 16))
                    Text("Plating your answer")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    LiveDots()
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if !renderedResponse.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("🤖 ChefBuddy")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .foregroundStyle(.green)
                        Spacer()
                        Button(action: {
                            withAnimation(.spring()) {
                                vm.aiResponse = ""
                                renderedResponse = ""
                                pendingResponse = nil
                                isAwaitingSpokenResponse = false
                            }
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }

                    Text(renderedResponse)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                        .lineSpacing(5)
                }
                .padding(16)
                .background(Color.black.opacity(0.4).background(.ultraThinMaterial))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.green.opacity(0.3), lineWidth: 1))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: renderedResponse)
            }
        }
    }

    private var analyzeButton: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            flashCapture = true
            camera.captureFrame()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { flashCapture = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let img = camera.capturedImage {
                    vm.analyzeFrame(image: img, recipe: recipe, assistant: assistant)
                }
            }
        }) {
            HStack(spacing: 8) {
                if vm.isThinking {
                    Text("🍳")
                    Text("Tasting your dish")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    LiveDots()
                } else {
                    Image(systemName: "viewfinder.circle.fill")
                        .font(.system(size: 18))
                    Text("Analyze My Cooking")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.orange.opacity(0.85).background(.ultraThinMaterial))
            .clipShape(Capsule())
            .shadow(color: .orange.opacity(0.4), radius: 8, y: 4)
        }
        .disabled(vm.isThinking || !cameraReady)
        .padding(.bottom, 8)
    }

    private var modernBottomDock: some View {
        HStack(spacing: 12) {


            Button(action: toggleVoiceOrb) {
                ZStack {

                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    (speech.isRecording ? Color.red : (voice.isSpeaking ? Color.green : Color.orange)).opacity(0.6),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 10,
                                endRadius: 35
                            )
                        )
                        .frame(width: 60, height: 60)
                        .scaleEffect(speech.isRecording ? (1.2 + CGFloat(speech.audioLevel * 0.3)) : (voice.isSpeaking ? 1.1 : 1.0))
                        .animation(.spring(response: 0.3), value: speech.audioLevel)
                        .animation(.easeInOut(duration: 1.0).repeatForever(), value: voice.isSpeaking)


                    Circle()
                        .fill(
                            LinearGradient(
                                colors: speech.isRecording ? [Color.red, Color.orange] : (voice.isSpeaking ? [Color.green, Color.mint] : [Color.orange, Color.pink]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                        .shadow(color: (speech.isRecording ? Color.red : (voice.isSpeaking ? Color.green : Color.orange)).opacity(0.5), radius: 8)


                    if voice.isPreparingAudio || vm.isThinking {
                        LiveDots()
                    } else {
                        Image(systemName: speech.isRecording ? "waveform" : (voice.isSpeaking ? "speaker.wave.2.fill" : "sparkles"))
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)


            TextField(
                liveStatusText,
                text: $questionText
            )
            .font(.system(size: 15, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.black.opacity(0.3))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
            .focused($questionFocused)
            .submitLabel(.send)
            .onSubmit {
                sendQuestionWithLiveContext(questionText)
            }
            .onChange(of: speech.transcript) { text in
                if speech.isRecording {
                    questionText = text
                }
            }


            if !questionText.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: {
                    sendQuestionWithLiveContext(questionText)
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.orange)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 30))
        .shadow(color: .black.opacity(0.3), radius: 15, y: 8)
    }

    var body: some View {
        ZStack {

            Color.black.ignoresSafeArea()

            if cameraReady, let layer = camera.previewLayer {
                CameraPreview(layer: layer)
                    .ignoresSafeArea()
            } else if cameraPermissionDenied {
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Camera Access Needed")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .padding()
                    .background(Color.orange)
                    .clipShape(Capsule())
                    .foregroundStyle(.white)
                }
            }


            VStack {
                LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 140)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 350)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if flashCapture {
                Color.white.opacity(0.6).ignoresSafeArea()
            }


            VStack(spacing: 0) {
                floatingTopPill
                    .padding(.top, 8)

                Spacer()

                analyzeButton

                floatingContent
                    .padding(.bottom, 12)

                modernBottomDock
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .safeAreaPadding(.top)
        }
        .onAppear {
            camera.start()
            speech.requestPermissions()
        }
        .onDisappear {
            camera.stop()
            stopVoiceCapture(sendFinal: false)
            voice.stop()
        }
        .onChange(of: speech.finalTranscript) { text in
            let finalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalized.isEmpty else { return }
            speech.finalTranscript = ""
            sendQuestionWithLiveContext(finalized)
        }
        .onChange(of: vm.isThinking) { thinking in
            if thinking && speech.isRecording {
                stopVoiceCapture(sendFinal: false)
            }
        }
        .onChange(of: vm.aiResponse) { response in
            handleAIResponseForVoice(response)
        }
        .onChange(of: voice.isSpeaking) { speaking in
            if speaking {
                if let pendingResponse {
                    renderedResponse = pendingResponse
                    self.pendingResponse = nil
                    isAwaitingSpokenResponse = false
                }
            } else if isAwaitingSpokenResponse,
                      !voice.isPreparingAudio,
                      let pendingResponse {
                renderedResponse = pendingResponse
                self.pendingResponse = nil
                isAwaitingSpokenResponse = false
            }
        }
        .sheet(isPresented: $showStepList) {
            StepListSheet(steps: recipe.steps, currentIndex: vm.currentStepIndex) { index in
                vm.moveToStep(index, recipe: recipe)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showReview) {
            RecipeReviewView(
                recipe: recipe,
                assistant: assistant,
                userId: userId,
                onComplete: { updatedRecipe, liked, likedNote, improvement in
                    showReview = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        dismiss()
                    }
                    var cooked = updatedRecipe
                    cooked.cookedCount = max(updatedRecipe.cookedCount, recipe.cookedCount + 1)
                    cooked.lastCookedAt = Date()
                    let db = Firestore.firestore()
                    if let id = cooked.id,
                       let encoded = try? Firestore.Encoder().encode(cooked) {
                        db.collection("users").document(userId).collection("recipes").document(id)
                            .setData(encoded)
                        let reviewData: [String: Any] = [
                            "likedTags": Array(liked),
                            "likedNote": likedNote,
                            "improvement": improvement,
                            "createdAt": Date()
                        ]
                        db.collection("users").document(userId).collection("recipes").document(id)
                            .collection("reviews").addDocument(data: reviewData)
                    }
                }
            )
        }
    }
}

private struct LiveDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate * 4) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index <= step ? Color.white : Color.white.opacity(0.35))
                        .frame(width: 5, height: 5)
                        .offset(y: index == step ? -1.5 : 0)
                }
            }
        }
    }
}


private struct StepListSheet: View {
    let steps: [String]
    let currentIndex: Int
    let onSelect: (Int) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("All Steps")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        Button(action: {
                            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                            onSelect(index)
                            dismiss()
                        }) {
                            HStack(alignment: .top, spacing: 14) {
                                Text("\(index + 1)")
                                    .font(.system(size: 13, weight: .black, design: .rounded))
                                    .foregroundStyle(index == currentIndex ? .white : .primary)
                                    .frame(width: 28, height: 28)
                                    .background(
                                        index == currentIndex
                                        ? AnyView(LinearGradient(colors: [.orange, .green.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        : AnyView(Color(.systemGray5))
                                    )
                                    .clipShape(Circle())

                                Text(step)
                                    .font(.system(size: 14, design: .rounded))
                                    .foregroundStyle(index == currentIndex ? .primary : .secondary)
                                    .lineSpacing(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if index < currentIndex {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.system(size: 18))
                                }
                            }
                            .padding(14)
                            .background(index == currentIndex ? Color.orange.opacity(0.08) : Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
    }
}
