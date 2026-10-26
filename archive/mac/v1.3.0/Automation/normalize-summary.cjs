'use strict';

// Native capture owns threshold hysteresis. This receiver validates and preserves it.
function normalizeSummary(body, now = Date.now()) {
  const fail = message => ({ ok: false, error: message, load_state: '未知', power_w: null, energy_kwh: null });
  if (!body || typeof body !== 'object' || Array.isArray(body)) return fail('需要 JSON 对象');
  const text = key => typeof body[key] === 'string' && body[key].length <= 160 ? body[key] : '';
  const timestamp = text('timestamp'), session = text('session_id'), source = text('source');
  const time = Date.parse(timestamp);
  if (!timestamp || !Number.isFinite(time) || !session || !source) return fail('缺少有效的 timestamp、session_id 或 source');
  if (typeof body.calibrated !== 'boolean') return fail('必须明确 calibrated');
  const test = /test|loopback|demo|simulation/i.test(source);
  const stale = Math.abs(now - time) > 15000;
  const result = { ok: true, timestamp, session_id: session, device_id: text('device_id') || 'meter-01',
    source, test_data: test, stale, calibrated: body.calibrated,
    received_at: new Date(now).toISOString(), power_w: null, energy_kwh: null,
    load_state: '待标定', interpretation: '仅接收到原始数据，不能据此确认电器开关' };
  if (!body.calibrated) {
    if (body.power_w != null || body.energy_kwh != null) return fail('未标定记录不可带入物理功率或电量');
    for (const key of ['voltage_adc_rms', 'current_adc_rms']) {
      if (typeof body[key] !== 'number' || !Number.isFinite(body[key]) || body[key] < 0) return fail('ADC RMS 无效');
      result[key] = body[key];
    }
    if (typeof body.received_points === 'number' && Number.isSafeInteger(body.received_points) && body.received_points > 0) result.received_points = body.received_points;
  } else {
    if (typeof body.power_w !== 'number' || !Number.isFinite(body.power_w) || body.power_w < 0) return fail('已标定功率无效');
    if (body.energy_kwh != null && (typeof body.energy_kwh !== 'number' || !Number.isFinite(body.energy_kwh) || body.energy_kwh < 0)) return fail('积分电量无效');
    result.power_w = body.power_w; result.energy_kwh = body.energy_kwh ?? null;
    const allowed = ['运行中', '待机 / 未运行', '待判定', '功率异常，暂停判断'];
    result.load_state = allowed.includes(body.load_state) ? body.load_state : '待判定';
    result.interpretation = '沿用采集端的阈值与保持时间结果，不能独立确认完整工作周期';
  }
  if (stale) { result.load_state = '未知 / 历史或时间未对齐'; result.interpretation = '记录时间距接收时间超过 15 秒，不当作当前状态'; }
  if (test) { result.load_state = '测试数据 / 非实物结论'; result.interpretation = '仅用于接收流程测试'; }
  return result;
}
module.exports = normalizeSummary;
