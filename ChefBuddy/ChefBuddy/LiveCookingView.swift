//
//  LiveCookingView.swift
//  ChefBuddy
//

import SwiftUI
import AVFoundation
import FirebaseFirestore
import Combine
import Speech

// MARK: - Camera Manager

class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var capturedImage: UIImage? = nil
    @Published var isRunning = false

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var latestBuffer: CMSampleBuffer?

    override init() {
        super.init()
        
        // Create the layer immediately so the UI doesn't default to the gray box
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        self.previewLayer = layer
        
        // Check and request permissions before adding inputs
        checkPermissionAndSetup()
    }

    private func checkPermissionAndSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupSessionInputs()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.setupSessionInputs()
                }
            }
        default:
            print("Camera permission denied")
        }
    }

    private func setupSessionInputs() {
        session.sessionPreset = .high
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        if session.canAddInput(input) { session.addInput(input) }

        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "cameraQueue"))
        output.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(output) { session.addOutput(output) }
    }

    func start() {
        guard !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        DispatchQueue.main.async { self.isRunning = true }
    }

    func stop() {
        session.stopRunning()
        DispatchQueue.main.async { self.isRunning = false }
    }

    func captureFrame() {
        guard let buffer = latestBuffer,
              let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        DispatchQueue.main.async {
            self.capturedImage = UIImage(cgImage: cgImage)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        latestBuffer = sampleBuffer
    }
}


// MARK: - Speech Manager

class SpeechManager: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    @Published var transcript: String = ""
    @Published var isRecording: Bool = false
    @Published var permissionGranted: Bool = false
    @Published var errorMessage: String = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    override init() {
        super.init()
        recognizer?.delegate = self
        requestPermissions()
    }

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                self?.permissionGranted = (status == .authorized)
            }
        }
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                if !granted { self?.errorMessage = "Microphone access denied" }
            }
        }
    }

    func startRecording() {
        guard permissionGranted, !audioEngine.isRunning else { return }

        transcript = ""
        errorMessage = ""

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = "Audio session error"
            return
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = recognitionRequest else { return }
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        let inputNode = audioEngine.inputNode
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

        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            DispatchQueue.main.async { self.isRecording = true }
        } catch {
            errorMessage = "Could not start recording"
        }
    }

    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        DispatchQueue.main.async { self.isRecording = false }
    }
}

// MARK: - Camera Preview

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

    func updateUIView(_ uiView: UIView, context: Context) {
        // Handled automatically by layoutSubviews so i think we dont need to do anything here
    }
}

// MARK: - Live Cooking ViewModel

class LiveCookingViewModel: ObservableObject {
    @Published var currentStepIndex: Int = 0
    @Published var aiResponse: String = ""
    @Published var isThinking: Bool = false
    @Published var conversationHistory: [ChatMessage] = []
    @Published var stepConfidence: String = ""

    struct ChatMessage: Identifiable {
        let id = UUID()
        let role: String   // "user" or "assistant"
        let text: String
        let timestamp: Date
    }

    func analyzeFrame(image: UIImage, recipe: Recipe, assistant: CookingAssistant) {
        isThinking = true
        let steps = recipe.steps
        let currentStep = steps.indices.contains(currentStepIndex) ? steps[currentStepIndex] : "Unknown step"
        let allSteps = steps.enumerated().map { "Step \($0.offset + 1): \($0.element)" }.joined(separator: "\n")

        Task {
            do {
                let prompt = """
                I am cooking: \(recipe.title)

                All steps:
                \(allSteps)

                I believe I am currently on Step \(currentStepIndex + 1): \(currentStep)

                Look at this image of what I'm cooking right now and:
                1. Confirm which step I appear to be on based on what you see (or correct me if I'm on a different step)
                2. Give me specific, actionable guidance for what to do RIGHT NOW
                3. Warn me of anything that looks wrong or needs attention
                4. Tell me what to watch for to know when this step is complete

                Be concise and encouraging. Use simple language for a home cook.
                """

                let response = try await assistant.getLiveHelp(image: image, question: prompt)

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

    func askQuestion(question: String, recipe: Recipe, assistant: CookingAssistant) {
        guard !question.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isThinking = true
        conversationHistory.append(ChatMessage(role: "user", text: question, timestamp: Date()))

        let currentStep = recipe.steps.indices.contains(currentStepIndex) ? recipe.steps[currentStepIndex] : ""

        Task {
            do {
                let prompt = """
                I am cooking \(recipe.title), currently on step \(currentStepIndex + 1): \(currentStep)

                My question: \(question)

                Answer specifically in context of this recipe step. Be brief and practical.
                """
                let response = try await assistant.getHelp(question: prompt)
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

// MARK: - Recipe Picker Sheet

struct RecipePickerSheet: View {
    let recipes: [Recipe]
    let onSelect: (Recipe) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
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
                                onSelect(recipe)
                                dismiss()
                            }) {
                                HStack(spacing: 16) {
                                    Text(recipe.emoji)
                                        .font(.system(size: 36))
                                        .frame(width: 60, height: 60)
                                        .background(
                                            LinearGradient(colors: [.orange.opacity(0.12), .green.opacity(0.08)],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing)
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
                                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.05), lineWidth: 1))
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

// MARK: - Main Live Cooking View

struct LiveCookingView: View {
    let recipe: Recipe
    @ObservedObject var assistant: CookingAssistant
    let userId: String
    @Environment(\.dismiss) var dismiss

    @StateObject private var camera = CameraManager()
    @StateObject private var vm = LiveCookingViewModel()
    @StateObject private var speech = SpeechManager()

    @State private var questionText = ""
    @State private var showStepList = false
    @State private var showReview = false
    @FocusState private var questionFocused: Bool
    @State private var flashCapture = false

    var progress: Double {
        guard recipe.steps.count > 0 else { return 0 }
        return Double(vm.currentStepIndex + 1) / Double(recipe.steps.count)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Top bar ──────────────────────────────────────────────
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        Text(recipe.title)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("Step \(vm.currentStepIndex + 1) of \(recipe.steps.count)")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    HStack(spacing: 12) {
                        Button(action: { showStepList = true }) {
                            Image(systemName: "list.number")
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.8))
                        }

                        if vm.currentStepIndex == recipe.steps.count - 1 {
                            Button(action: {
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                showReview = true
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 14, weight: .bold))
                                    Text("Done!")
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    LinearGradient(colors: [.orange, .green.opacity(0.85)], startPoint: .leading, endPoint: .trailing)
                                )
                                .clipShape(Capsule())
                            }
                            .transition(.scale.combined(with: .opacity))
                            .animation(.spring(response: 0.4), value: vm.currentStepIndex)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                // ── Progress bar ──────────────────────────────────────────
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15)).frame(height: 3)
                        Capsule()
                            .fill(LinearGradient(colors: [.orange, .green], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * progress, height: 3)
                            .animation(.spring(response: 0.5), value: progress)
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                // ── Camera feed ───────────────────────────────────────────
                ZStack {
                    if let layer = camera.previewLayer {
                        CameraPreview(layer: layer)
                            .clipShape(RoundedRectangle(cornerRadius: 20))
                    } else {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.gray.opacity(0.3))
                            .overlay(
                                VStack(spacing: 8) {
                                    Image(systemName: "camera.fill").font(.title).foregroundStyle(.white.opacity(0.5))
                                    Text("Camera unavailable").foregroundStyle(.white.opacity(0.5))
                                }
                            )
                    }

                    // Flash overlay on capture
                    if flashCapture {
                        RoundedRectangle(cornerRadius: 20).fill(.white.opacity(0.6))
                            .transition(.opacity).animation(.easeOut(duration: 0.15), value: flashCapture)
                    }

                    // Scan button overlay
                    VStack {
                        Spacer()
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
                                    ProgressView().tint(.white).scaleEffect(0.8)
                                    Text("Analyzing...").font(.system(size: 14, weight: .bold, design: .rounded))
                                } else {
                                    Image(systemName: "viewfinder.circle.fill").font(.system(size: 18))
                                    Text("Analyze My Cooking").font(.system(size: 14, weight: .bold, design: .rounded))
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20).padding(.vertical, 12)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                        }
                        .disabled(vm.isThinking)
                        .padding(.bottom, 16)
                    }
                }
                .frame(height: 260)
                .padding(.horizontal, 16)

                // ── Current Step Card ─────────────────────────────────────
                if recipe.steps.indices.contains(vm.currentStepIndex) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("CURRENT STEP")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(.orange)
                            Spacer()
                            HStack(spacing: 16) {
                                Button(action: { vm.prevStep(recipe: recipe) }) {
                                    Image(systemName: "arrow.left.circle.fill")
                                        .font(.system(size: 26))
                                        .foregroundStyle(vm.currentStepIndex > 0 ? Color.orange : Color.gray.opacity(0.4))
                                }
                                .disabled(vm.currentStepIndex == 0)

                                Button(action: { vm.nextStep(recipe: recipe) }) {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .font(.system(size: 26))
                                        .foregroundStyle(vm.currentStepIndex < recipe.steps.count - 1 ? Color.green : Color.gray.opacity(0.4))
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
                    .background(.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }

                // ── AI Response ───────────────────────────────────────────
                if !vm.aiResponse.isEmpty {
                    ScrollView(showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            Text("🤖").font(.system(size: 20))
                            Text(vm.aiResponse)
                                .font(.system(size: 14, design: .rounded))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineSpacing(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                        .background(
                            LinearGradient(colors: [.orange.opacity(0.2), .green.opacity(0.15)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange.opacity(0.3), lineWidth: 1))
                    }
                    .frame(maxHeight: 120)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.4), value: vm.aiResponse)
                }

                Spacer()

                // ── Question Input ────────────────────────────────────────
                HStack(spacing: 10) {
                    TextField(speech.isRecording ? "Listening..." : "Ask ChefBuddy anything...", text: $questionText)
                        .font(.system(size: 15, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .background(speech.isRecording ? Color.red.opacity(0.18) : Color.white.opacity(0.10))
                        .clipShape(Capsule())
                        .focused($questionFocused)
                        .onChange(of: speech.transcript) { text in
                            questionText = text
                        }

                    // Mic button — tap to start, tap again to stop + send
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        if speech.isRecording {
                            speech.stopRecording()
                            // Auto-send after a short pause so transcript settles
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                let q = questionText.trimmingCharacters(in: .whitespaces)
                                guard !q.isEmpty else { return }
                                questionText = ""
                                questionFocused = false
                                vm.askQuestion(question: q, recipe: recipe, assistant: assistant)
                            }
                        } else {
                            questionFocused = false
                            speech.startRecording()
                        }
                    }) {
                        ZStack {
                            Circle()
                                .fill(speech.isRecording ? Color.red.opacity(0.85) : Color.white.opacity(0.12))
                                .frame(width: 44, height: 44)
                            if speech.isRecording {
                                // Pulse ring when recording
                                Circle()
                                    .stroke(Color.red.opacity(0.5), lineWidth: 2)
                                    .frame(width: 54, height: 54)
                                    .scaleEffect(speech.isRecording ? 1.0 : 0.8)
                                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: speech.isRecording)
                            }
                            Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(speech.isRecording ? .white : .white.opacity(0.7))
                        }
                    }
                    .disabled(!speech.permissionGranted && !speech.isRecording)

                    // Send button
                    Button(action: {
                        let q = questionText
                        questionText = ""
                        questionFocused = false
                        speech.stopRecording()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        vm.askQuestion(question: q, recipe: recipe, assistant: assistant)
                    }) {
                        Image(systemName: vm.isThinking ? "ellipsis.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(questionText.isEmpty ? Color.gray.opacity(0.4) : Color.orange)
                    }
                    .disabled(questionText.isEmpty || vm.isThinking)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
        .onAppear { camera.start() }
        .onDisappear {
            camera.stop()
            speech.stopRecording()
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
                    // Dismiss review then live cooking
                    showReview = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        dismiss()
                    }
                    // Build a single cooked snapshot and write once to Firestore
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

// MARK: - Step List Sheet

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
