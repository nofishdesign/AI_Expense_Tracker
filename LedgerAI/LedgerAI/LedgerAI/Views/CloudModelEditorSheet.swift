import SwiftData
import SwiftUI

struct CloudModelEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let config: CloudModelConfig?

    @State private var displayName = ""
    @State private var vendor: CloudVendor = .openai
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var customHeadersJSON = "{}"

    var body: some View {
        NavigationStack {
            Form {
                Section("基础") {
                    TextField("名称", text: $displayName)
                    Picker("厂商", selection: $vendor) {
                        ForEach(CloudVendor.allCases) { vendor in
                            Text(vendor.title).tag(vendor)
                        }
                    }
                    .onChange(of: vendor) { _, newValue in
                        if baseURL.isEmpty { baseURL = newValue.defaultBaseURL }
                    }
                }

                Section("API 配置") {
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("说明") {
                    Text("仅需填写 Base URL + API Key。应用会自动按 OpenAI 兼容格式调用。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("高级") {
                    TextField("自定义请求头(JSON，可选)", text: $customHeadersJSON, axis: .vertical)
                        .lineLimit(2...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(config == nil ? "新增云端模型" : "编辑云端模型")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        save()
                        dismiss()
                    }
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let config {
                    displayName = config.displayName
                    vendor = config.vendor
                    if !config.baseURL.isEmpty {
                        baseURL = config.baseURL
                    } else {
                        let parsed = splitEndpoint(config.endpoint)
                        baseURL = parsed.baseURL
                    }
                    apiKey = config.apiKey
                    customHeadersJSON = config.customHeadersJSON
                } else {
                    baseURL = vendor.defaultBaseURL
                }
            }
        }
    }

    private func save() {
        let cleanedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergedEndpoint = cleanedBase
        let effectiveModel = vendor.defaultModel

        if let config {
            config.displayName = displayName
            config.vendor = vendor
            config.baseURL = cleanedBase
            config.apiPath = ""
            config.endpoint = mergedEndpoint
            config.modelName = effectiveModel
            config.apiKey = apiKey
            config.customHeadersJSON = customHeadersJSON
            config.updatedAt = .now
        } else {
            modelContext.insert(CloudModelConfig(
                displayName: displayName,
                vendor: vendor,
                endpoint: mergedEndpoint,
                baseURL: cleanedBase,
                apiPath: "",
                modelName: effectiveModel,
                apiKey: apiKey,
                customHeadersJSON: customHeadersJSON
            ))
        }
        try? modelContext.save()
    }

    private func splitEndpoint(_ endpoint: String) -> (baseURL: String, apiPath: String) {
        guard let url = URL(string: endpoint),
              let scheme = url.scheme,
              let host = url.host else {
            return (endpoint, "")
        }
        let portPart: String
        if let port = url.port {
            portPart = ":\(port)"
        } else {
            portPart = ""
        }
        let base = "\(scheme)://\(host)\(portPart)"
        let path = url.path.isEmpty ? "" : url.path
        return (base, path)
    }
}
