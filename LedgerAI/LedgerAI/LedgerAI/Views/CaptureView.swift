import PhotosUI
import SwiftData
import SwiftUI

struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Category.order) private var categories: [Category]
    @StateObject private var viewModel = CaptureViewModel()
    @StateObject private var speechService = SpeechRecognizerService()
    @State private var photoItem: PhotosPickerItem?
    @State private var permissionChecked = false
    @State private var showReviewSheet = false

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

                    if viewModel.source != .screenshot {
                        TextEditor(text: $viewModel.textInput)
                            .frame(minHeight: 120)
                            .font(.body)
                            .onChange(of: viewModel.textInput) { _, _ in
                                viewModel.resetRecognitionResult()
                            }
                    }
                }

                Section {
                    Button {
                        Task { await viewModel.recognize(modelContext: modelContext) }
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.isProcessing {
                                ProgressView()
                            } else {
                                Text("识别支付信息")
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
            .onChange(of: viewModel.source) { _, _ in
                viewModel.resetRecognitionResult()
            }
            .onChange(of: viewModel.hasPendingForm) { _, hasForm in
                showReviewSheet = hasForm
            }
            .sheet(isPresented: $showReviewSheet) {
                NavigationStack {
                    Form {
                        Section("识别结果（可修改）") {
                            TextField("商户", text: $viewModel.formMerchant)
                            TextField("金额", value: $viewModel.formAmount, format: .number.precision(.fractionLength(2)))
                                .keyboardType(.decimalPad)
                            DatePicker("支付时间", selection: $viewModel.formOccurredAt, displayedComponents: [.date, .hourAndMinute])
                            Picker("支付方式", selection: $viewModel.formChannel) {
                                ForEach(PaymentChannel.allCases, id: \.self) { channel in
                                    Text(channel.title).tag(channel)
                                }
                            }
                            Picker("分类", selection: $viewModel.formCategoryID) {
                                Text("未分类").tag(Optional<UUID>.none)
                                ForEach(categories) { category in
                                    Text(category.name).tag(Optional(category.id))
                                }
                            }
                            TextField("备注（可选）", text: $viewModel.formNote)
                            Text("置信度：\(Int(viewModel.formConfidence * 100))%")
                                .foregroundStyle(.secondary)
                                .font(.footnote)
                            if !viewModel.formEngineTitle.isEmpty {
                                Text("识别来源：\(viewModel.formEngineTitle)\(viewModel.formEngineDetail.isEmpty ? "" : "（\(viewModel.formEngineDetail)）")")
                                    .foregroundStyle(.secondary)
                                    .font(.footnote)
                            }
                        }
                    }
                    .navigationTitle("确认识别结果")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") {
                                viewModel.resetRecognitionResult()
                                showReviewSheet = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                let success = viewModel.saveCurrentForm(modelContext: modelContext)
                                if success {
                                    showReviewSheet = false
                                }
                            }
                        }
                    }
                }
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
                    viewModel.resetRecognitionResult()
                    if viewModel.source == .screenshot {
                        await viewModel.recognize(modelContext: modelContext)
                    }
                }
            }

            if viewModel.selectedImage != nil {
                Text("已选择截图，系统会自动识别并弹出表单。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
