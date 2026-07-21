# 南大统一认证登录 / 验证码识别 —— 调研与工具

## 现状（本轮结论）

- **密码不需要靠模拟打字**：南大统一认证登录页对密码字段做了客户端 AES-128-CBC
  加密（key 是页面隐藏字段 `pwdEncryptSalt`），已经在
  [`lib/Utils/NjuAuthCrypto.dart`](../lib/Utils/NjuAuthCrypto.dart) 里用 Dart
  复刻了这个算法（参考 `nju_cli_unified_auth.rs`），不用再靠 WebView 里模拟键盘事件
  去触发页面自己的加密逻辑。
- **验证码类型**：`authserver.nju.edu.cn/authserver/getCaptcha.htl` 这个公开接口默认
  给的是普通文字验证码（不是滑动拼图）；滑动拼图很可能是我们早期用 WebView 做
  自动化时触发了风控升级，换成走干净的 HTTP 请求 + `dllt=mobileLogin` 参数大概率
  不会再遇到。`nju_captcha.onnx` 是现成的文字验证码识别模型，尚未接入 Flutter 侧的
  实际推理代码（下一步工作）。

这个目录留着一整套"验证码识别"相关的备用流程，**平时不需要跑**，
只有在下面这些情况发生时才需要捡起来用：

- 学校又改了验证码样式（上次是 2026 年 2 月），现成模型识别率明显下降；
- 想要更高的识别准确率，自己针对南大当前样式重新训练。

## 完整流程

1. **采集**（`collect_captcha.py`）：命中 `authserver.nju.edu.cn/authserver/getCaptcha.htl`
   这个公开接口反复拉图，不需要登录。建议采几百到一千张。
   ```
   pip install requests
   python collect_captcha.py --count 800 --out captcha_samples
   ```

2. **标注**：给 `captcha_samples/` 里每张图标出图上的 4 个字符，改文件名成
   `<四位标签>_<原文件名>.jpg`（比如 `a3x9_00001.jpg` → 标签是 `a3x9`）。
   可以人工标，也可以找 LLM 辅助（把图片喂给它，让它猜字符，再人工抽查纠错）。

3. **训练**（`train_captcha_model.py`）：
   ```
   pip install torch pillow
   python train_captcha_model.py --data captcha_samples --epochs 30 --out nju_captcha_new.onnx
   ```
   训练日志会打印每轮的单字符准确率和整体 4 字符全对准确率，全对准确率到 70%+
   基本就可用了（参考项目自己的成功率也就在这个量级）。

4. **替换**：训出来的 `nju_captcha_new.onnx` 跟现在用的模型输入输出规格完全一致
   （80×30 输入、4 位×35 类输出），直接替换 Flutter 项目里 assets 下的模型文件，
   不需要改任何 Dart 代码。

## 已知会花资源的地方

训练这一步需要装 PyTorch，且要跑几十轮训练——内存/硬盘吃紧的机器上建议先别跑，
等换了机器再说；采集和标注这两步不吃资源，随时可以先做。

## 参考文件来源

- `nju_captcha.onnx` / `nju_captcha.user.js`：下载自
  [yama-lei/nju-captcha-extension](https://github.com/yama-lei/nju-captcha-extension)
  （MIT License），分发/使用需保留原项目版权声明。
- `nju_cli_unified_auth.rs`：下载自
  [nju-cli/nju-cli](https://github.com/nju-cli/nju-cli)（MIT License）的统一认证
  登录参考实现，仅作技术参考，未直接编译进本项目。
