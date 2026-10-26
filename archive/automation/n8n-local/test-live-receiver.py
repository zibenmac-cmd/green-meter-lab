"""Exercise only the local n8n receiver with explicitly marked synthetic records."""
import datetime
import json
from pathlib import Path
import urllib.error
import urllib.request

root = Path(__file__).resolve().parent
receiver = (root / 'runtime-data/receiver-path.txt').read_text().strip()
target = 'http://127.0.0.1:5678/webhook/' + receiver
stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
base = dict(timestamp=stamp, session_id='n8n-receiver-test-20261021', source='loopback_test_NOT_hardware', device_id='test-only', calibrated=False, voltage_adc_rms=119.4, current_adc_rms=17.9, received_points=6400, power_w=None, energy_kwh=None)
cases = [
    ('raw_adc', base, 200),
    ('reject_uncalibrated_watts', dict(base, power_w=100), 422),
    ('calibrated_synthetic_only', dict(base, calibrated=True, power_w=80, energy_kwh=0.002, load_state='运行中'), 200),
    ('reject_missing_timestamp', dict(base, timestamp='bad'), 422),
]
results = []
for name, body, expected in cases:
    request = urllib.request.Request(target, data=json.dumps(body).encode(), headers={'Content-Type': 'application/json'}, method='POST')
    try:
        response = urllib.request.urlopen(request, timeout=20)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        status = response.code
        result = json.loads(response.read())
    assert status == expected, (name, status, result)
    assert result.get('ok') == (expected == 200), (name, result)
    if expected == 200:
        assert result['test_data'] is True and result['load_state'] == '测试数据 / 非实物结论'
    if name == 'raw_adc':
        assert result['power_w'] is None and result['energy_kwh'] is None
    results.append(dict(name=name, http_status=status, result=result, passed=True))
report = dict(verified_at=stamp, source='local_n8n_synthetic_test_NOT_hardware', cases=results)
(root / 'n8n接收验证.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print('PASS: 4 local n8n HTTP tests; uncalibrated watts rejected; synthetic data explicitly marked.')
