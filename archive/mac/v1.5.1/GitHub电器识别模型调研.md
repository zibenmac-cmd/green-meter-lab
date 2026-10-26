# 电器识别模型与本项目接入方向

核对日期：2026-10-25。结论：已找到可以复用的识别算法和训练代码；本轮没有确认可直接用于这台插座、无需适配和验证的现成权重。尚未把第三方模型装进 Mac 采集器。

## 功率测量和识别任务

当前一台插座连接一台电器，瓦数由同步电压、电流计算：`P = mean(v × i)`。幅值换算、零点、极性及通道同步需要核对；识别模型不能代替这些核对。开关活动可先用功率阈值和保持时间验证。识别“哪种电器”才需要分类器及有标签的样本。

## 核对的 GitHub 项目

| 项目 | 能做什么及输入 | 本项目适配判断 | 权重和许可核对 |
| --- | --- | --- | --- |
| [TI Tiny ML ModelZoo 的 PLAID 示例](https://github.com/TexasInstruments/tinyml-modelzoo/tree/main/examples/PLAID_nilm_classification) | 电压/电流波形的电器分类示例；其说明采用 30 kHz PLAID 子集，列出 11 类电器 | 与单插座双通道输入最接近，适合作为后续训练流程参考；仍需按本机实际采样率和电器数据训练、测试 | 当前主分支未发现常见格式的模型权重。README 声称 BSD 3-Clause，本轮未在文件树找到 LICENSE 文件，集成前需进一步确认。默认编译目标是 TI MCU，不是 Mac 应用。[示例说明](https://github.com/TexasInstruments/tinyml-modelzoo/blob/main/examples/PLAID_nilm_classification/readme.md)、[训练配置](https://github.com/TexasInstruments/tinyml-modelzoo/blob/main/examples/PLAID_nilm_classification/config.yaml) |
| [NILMTK-Contrib](https://github.com/nilmtk/nilmtk-contrib) | 提供 Seq2Point、BERT、SGN 等电力分解/状态相关模型；主要处理功率时间序列 | 适合后续从总表中估计已知电器的负荷，当前单电器分类可以先做更小的模型 | Apache-2.0；当前仓库没有发现现成权重。需要训练数据和模型训练，不是任意电器识别服务。[README](https://github.com/nilmtk/nilmtk-contrib/blob/master/README.md) |
| [goruck/nilm](https://github.com/goruck/nilm) | CNN、Transformer、TFLite 实时推理流程；围绕水壶、微波炉、冰箱、洗碗机、洗衣机五类电器 | 适合参考边缘部署和功率分解；它处理持续的有功功率序列，不能把 6400 点/秒 ADC 直接塞进去 | MIT；检查了仓库文件树，`ml/models` 主要是训练日志、曲线和评估结果，未发现常见权重文件。其工程按 8 秒功率更新、599 点窗口工作，且作者展示了本地微调前后差异。[README](https://github.com/goruck/nilm/blob/main/README.md)、[models 目录](https://github.com/goruck/nilm/tree/main/ml/models) |
| [HC_LST_NILM](https://github.com/linfengYang/HC_LST_NILM) | PLAID/WHITED 的 V-I 轨迹分类研究代码 | 可参考波形特征处理；本轮不选作直接集成方案 | 当前主分支未发现权重或明确许可证，README 还说明存在最佳模型保存问题，需要谨慎复现实验。[作者说明](https://github.com/linfengYang/HC_LST_NILM#english) |

“未发现权重”仅指本轮核对的默认分支文件树，包括 `.pth/.pt/.h5/.tflite/.onnx/.pb/.ckpt/.keras` 等常见文件；不排除作者另有外链或后续发布。未执行这些仓库的代码，也未验证它们在你的电器上的识别准确率。

## 建议落地顺序

1. 用 Mac 1.4 看参考瓦数，并用参考仪表对照零点、极性和不同负载；单点调整后继续换负载复核。
2. 每台电器分别采集关闭、待机、运行以及启动阶段；记录实际电器名称和工作状态。按采集会话和电器划分训练/测试，避免同一段波形切出的相似片段同时落入两边。
3. 先针对实际要演示的少数电器训练轻量分类器，保留“未知电器/置信度不足”。这是根据本项目单插座场景作出的工程建议，不是已测得的模型效果。
4. 若之后改成一个总表同时监测多台电器，再评估 NILMTK 的负荷分解模型。

TI 示例的 30 kHz 与本机配置的 6400 Hz 不同；后者尚未被实物确认。插值不能恢复未采到的高频特征，应匹配实际采样条件并重新验证。电器分类、实时状态判断和峰谷预测应分别评估，不以一个数字代替三项准确率。

## 仓库快照

- `TexasInstruments/tinyml-modelzoo`: `008641087c100163c757737686df260946393b20`
- `nilmtk/nilmtk-contrib`: `14efd545e09d836e02159b23444350af92c6ee70`
- `goruck/nilm`: `d482f78505f35668d9214ed9cd2d2ce4af470f2d`
- `linfengYang/HC_LST_NILM`: `acf9b3fe5ddc8adbe7dbdd1d1d6b9dfb814502ed`

以上为本轮 GitHub API 返回的文件树 SHA，用于定位核对时的内容；项目之后可能变化。
