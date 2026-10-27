# 版本索引

补档日期：2026-10-26。下表为实际保留下来的交付版本，不能补造不存在的旧版本。

| 内容 | 源码与说明 | 原始交付包 |
| --- | --- | --- |
| Web 2.1：Cloudflare、用电统计、使用率与优化建议 | [目录](archive/web/v2.1.0/) | [ZIP](releases/绿电实验室Web版-2.1.0-源码.zip) |
| Web 2.0：Cloudflare、用电统计、使用率与优化建议 | [目录](archive/web/v2.0.0/) | [ZIP](releases/绿电实验室Web版-2.0.0-源码.zip) |
| Mac 1.0：原生采集与离线波形 | [目录](archive/mac/v1.0.0/) | [ZIP](releases/绿电实验室Mac版.zip) |
| Mac 1.1：实物 128 对采样协议 | [目录](archive/mac/v1.1.0/) | [ZIP](releases/绿电实验室Mac版-1.1.0.zip) |
| Mac 1.2：自动保存、重连与 Drive 同步 | [目录](archive/mac/v1.2.0/) | [ZIP](releases/绿电实验室Mac版-1.2.0.zip) |
| Mac 1.3：供电及数据指令按钮 | [目录](archive/mac/v1.3.0/) | [ZIP](releases/绿电实验室Mac版-1.3.0.zip) |
| Mac 1.4：参考瓦数、导出与模型调研 | [目录](archive/mac/v1.4.0/) | [ZIP](releases/绿电实验室Mac版-1.4.0.zip) |
| Mac 1.5：电器学习、分段采样与未知拒识 | [目录](archive/mac/v1.5.0/) | [ZIP](releases/绿电实验室Mac版-1.5.0.zip) |
| Mac 1.5.1：采集入口和连接提示修复 | [目录](archive/mac/v1.5.1/) | [ZIP](releases/绿电实验室Mac版-1.5.1.zip) |
| 独立插座 IP 读取测试器 1.0.1 | [目录](archive/tools/socket-ip-probe/v1.0.1/) | [ZIP](releases/插座IP读取测试器-1.0.1.zip) |
| 插座 Wi-Fi 离线连接工具 | [目录](archive/tools/wifi-offline/) | [ZIP](releases/插座WiFi离线连接工具.zip) |
| 早期 YS8000 接入包 | [目录](archive/integration/ys8000-legacy/) | [ZIP](releases/绿电实验室-YS8000接入包.zip) |
| 网页版交付源码包 | [目录](archive/web/delivered-source/) | [ZIP](releases/智能电表网页源码.zip) |

## 网页原始提交

| 提交 | 原始记录 |
| --- | --- |
| `ca7f752635b8f12306e919db3265a14411eb714c` | 2026-10-05T20:52:51+08:00 Update Site source |
| `85233aca6cb85a4fbc15067212d3bbd03253e301` | 2026-10-05T23:35:26+08:00 Update Site source |
| `06ab3e94c208848fcfa2af03380bf9f850a7643e` | 2026-10-15T23:40:16+08:00 Update Site source |

另存：本地 n8n 模板与脚本、交付后补充的测试样本、项目预览和排查说明。Mac 1.0 的重复目录与原 ZIP 源码一致，没有人为当作另一个版本。

所有原 ZIP 的 SHA-256、大小及解包源码的逐文件 SHA-256 见 ARCHIVE_MANIFEST.json。

## 1.5 更新

新增电器目录、20 秒实时采样、分状态学习、按段留出验证、连续匹配与未知拒识、样本停用/恢复和自动保存。135 项检查及本机 TCP 端到端验证通过；真实电器尚未接入采样，不宣称已学会用户电器。

## 1.5.1 更新

采集按钮可点击检查条件，新增就近连接入口及逐项原因提示；原生端保留实时采样限制。本机 TCP 20 秒采集和前端状态回归通过，实际插座当前连接超时，未新增实物样本。

## Web 2.0 更新（2026-10-27）

自有 Cloudflare 部署与 D1 私有数据；新增历史用电、运行占观测比和高功率排名、优化建议、参考峰谷外推、Mac 学习样本兼容、实时 ADC、离线采集桥。16 个单元测试和本机 D1 集成测试通过，正式站点验证登录 200 / 未授权真实 API 401，真实记录、设备和样本均为空。未连接现场设备或完成计量标定。管理员和采集凭据不归档。

## Web 2.1 更新（2026-10-27）

自有 Cloudflare 部署与 D1 私有数据；新增历史用电、运行占观测比和高功率排名、优化建议、参考峰谷外推、Mac 学习样本兼容、实时 ADC、离线采集桥。23 个单元测试和楼层 D1 集成测试通过，正式站点验证登录 200 / 未授权真实 API 401，真实记录、设备和样本均为空。未连接现场设备或完成计量标定。管理员和采集凭据不归档。
