# 绿电实验室 · 比赛用智能电表

中文单电器用电监测网页，带数据库与数据采集接口。默认私有访问。

网站：https://green-meter-lab-ahaoxiao.ziben-mac.chatgpt.site

## 功能

实时电表、日用电统计、节电前后对比、异常记录、CSV 导入导出、设备配置和采集密钥管理。演示数据在浏览器内生成，不写入数据库；真实模式初始为空。

## 开发与验证

Node ≥22.13，pnpm 11.25。安装：`pnpm install`。启动：`pnpm run dev`。预览开发环境的登录入口为 `/signin-with-chatgpt?return_to=/`。

配置 `.openai/hosting.json` 的 `d1` 为 `DB`。数据库结构在 `db/schema.ts`；迁移在 `drizzle/`。本地初始化顺序：`pnpm run build` 后执行 README 中下方的本地迁移命令，再启动开发服务。

```
node --import ./scripts/sites-env.mjs ./node_modules/wrangler/bin/wrangler.js d1 execute DB --local --config dist/server/wrangler.json --persist-to .wrangler/state --file drizzle/0000_orange_supreme_intelligence.sql
```

`node --test tests/meter.test.mjs` 检查数据计算与 CSV 校验。`pnpm exec tsc --noEmit` 检查类型。`pnpm run build` 构建。接口集成测试只允许 loopback，运行前需设置 `METER_ALLOW_TEST_DB=1`；它会生成测试记录并轮换本地采集密钥，应仅对空的、可丢弃的本地数据库运行。

## 数据接口

- `GET /api/config`：设备与计算参数。
- `PUT /api/config`：保存参数（登录用户，同源请求）。
- `GET /api/readings?from=YYYY-MM-DD&to=YYYY-MM-DD`：UTC+8 日期范围内的记录、区间前一条读数、全局最后记录和最后自动记录。最多 31 天、300,000 条；超量返回错误，需缩小范围。
- `POST /api/import`：登录用户提交 `{"readings":[...]}`，来源记为 `import`。
- `POST /api/ingest`：采集程序携带有效密钥提交单条或 `{"readings":[...]}`，来源记为 `auto`。
- `GET /api/key`：只返回是否设置采集密钥。
- `POST /api/key`：登录用户生成或轮换密钥，仅一次返回明文；数据库仅保存 SHA-256 摘要。

单条数据：`device_id`、带时区的 ISO `timestamp`、非负数 `power_w`（W）、`energy_kwh`（累计 kWh）。设备编号固定为 `meter-01`。不接受未来超过 60 秒的记录。同一设备、同一时间只保存一次，已有记录优先。单次最多 20,000 条或 4 MB；建议按小批次发送。所有记录在写入前校验，数据库写入分 100 条一批；发生网络/数据库失败时可重复提交，重复键可避免重复累计。并发不同值同时间记录不覆盖已有值。

## 计算口径

- 累计电量差统计耗电，跨日差值按间隔时长线性分摊，是估算而非逐日电表结算值。
- 累计读数降低时，该段差值不计入电量，标记重置；重置后继续累计后续正差值。
- 间隔超过 60 秒标记数据缺口，曲线按 15 分钟桶显示采样均值。日平均功率为采样算术平均，非时间加权平均。
- 连续间隔不超过 60 秒的采样时长累计达到 20 小时且无重置（日期必须已结束），记为有效日。它仍可能有最多 4 小时缺口，应配合覆盖时长解读。
- 前后时段不得重叠；各至少一个有效日。使用有效日用电量平均，正的节电值表示减少，负值表示增加；基准为零时百分比不计算。
- 碳排系数 0.785 来自用户提供的项目图片，仅为可修改的计划默认值；电价默认 0.6 元/kWh。碳排和费用均为估算。
- 在线状态只由自动记录的采集时间判断，超过 60 秒显示中断。CSV 导入不会使设备显示在线。

参见同目录 `接入说明.md`；适配程序在 `adapters/send_readings.py`。未实现自动邮件、远程断电、积分兑换或多宿舍管理。真实电表尚待采购，网页接口验证不等同于硬件连接验证。
