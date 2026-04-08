import PhotosUI
import SwiftData
import SwiftUI

struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = CaptureViewModel()
    @StateObject private var speechService = SpeechRecognizerService()
    @State private var photoItem: PhotosPickerItem?
    @State private var permissionChecked = false

    var body: some View {
        NavigationStack {
            Form {
                Section("录入方式") {
                    Picker("来源", selection: $viewModel.source) {
                        ForEach(InputSourceType.allCases) { source in
                            Text(source.title).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("输入内容") {
                    if viewModel.source == .voice {
                        voiceInputSection
                    } else if viewModel.source == .screenshot {
                        screenshotSection
                    }

                    TextEditor(text: $viewModel.textInput)
                        .frame(minHeight: 120)
                        .font(.body)
                }

                Section {
                    Button {
                        Task { await viewModel.ingest(modelContext: modelContext) }
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.isProcessing {
                                ProgressView()
                            } else {
                                Text("识别并入账")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(viewModel.isProcessing)
                }

                if !viewModel.resultMessage.isEmpty {
                    Section("结果") {
                        Text(viewModel.resultMessage)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("录入")
            .task {
                guard !permissionChecked else { return }
                permissionChecked = true
                _ = await speechService.requestPermission()
            }
        }
    }

    private var voiceInputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(speechService.isRecording ? "停止录音" : "开始录音") {
                if speechService.isRecording {
                    speechService.stopRecording()
                } else {
                    try? speechService.startRecording()
                }
            }
            .buttonStyle(.borderedProminent)

            if !speechService.transcript.isEmpty {
                Text("转写：\(speechService.transcript)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .onChange(of: speechService.transcript) { _, newValue in
                        viewModel.textInput = newValue
                    }
            }
        }
    }

    private var screenshotSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("选择截图", systemImage: "photo")
            }
            .onChange(of: photoItem) { _, newItem in
                Task {
                    guard let data = try? await newItem?.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else { return }
                    viewModel.selectedImage = image
                }
            }

            if viewModel.selectedImage != nil {
                Text("已选择截图，点击“识别并入账”自动 OCR。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
