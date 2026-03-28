# LedgerAI (iOS 智能记账)

自用的一款 AI 记账软件，支持从截图、文字、语音中提取账单信息并保存，支持月度统计和多模型配置。

SwiftUI + SwiftData 的个人记账应用原型，支持语音/文字/截图自动识别并自动入账。

## 快速启动

1. 安装 XcodeGen（可选）并在项目根目录执行：
   `xcodegen generate`
2. 打开 `LedgerAI/LedgerAI/LedgerAI.xcodeproj` 运行 iOS App。

## 需要的 iOS 权限

- `NSSpeechRecognitionUsageDescription`
- `NSMicrophoneUsageDescription`
- `NSPhotoLibraryUsageDescription`

`project.yml` 已预置默认文案，你可以按个人习惯修改。

## GitHub 仓库与版本管理

- 远程仓库：`https://github.com/nofishdesign/AI_Expense_Tracker.git`
- 主分支：`main`
- 版本规则：`v主版本.次版本.修订版本`（例如 `v0.1.5`）

推荐发布流程：

1. 开发前同步：
   `git checkout main && git pull origin main`
2. 功能开发（可选新分支）：
   `git checkout -b feature/<name>`
3. 提交：
   `git add . && git commit -m "feat: <说明>"`
4. 合并到 main 后打版本标签：
   `git checkout main && git tag v0.1.0`
5. 推送代码和标签：
   `git push origin main --tags`
